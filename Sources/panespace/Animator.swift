import AppKit
import PanespaceCore

/// Where an animated window starts.
enum Start {
    /// A known frame: its last target, or an off-screen spot it slides in from.
    case at(CGRect)
    /// Mid-flight: wherever the interrupted animation left it, else the fallback, else its real frame.
    case live(CGRect?)
    /// Its real frame (new windows, and ones the app or macOS moved itself).
    case current
}

/// One window's part in a layout animation.
struct Move {
    let id: WindowID
    let el: AXUIElement
    let pid: pid_t
    var start: Start
    /// Where it ends up; nil = its start moved by `by` (slide-outs, whose start is only known on `axQueue`).
    var to: CGRect?
    var by = CGVector.zero
    /// Put it at its start before animating: a slide-in parked at another size. (At the same size the first
    /// frame moves it straight from where it's parked.)
    var jump = false
    /// Afterwards, park it on this monitor (its workspace is hidden now).
    var park: MonitorID?
    var parkWidth: CGFloat?
    /// Floating: report the frame it started from, to remember for when it's shown again.
    var readFrame = false
}

/// Where a window is and how fast it's moving (x, y, width, height, per second).
struct Kinetic {
    var frame: CGRect
    var velocity = SIMD4<Double>(repeating: 0)
}

/// The last frame Panespace wrote to each window and its velocity then, so an interrupted animation is
/// picked up mid-flight without a jolt.
final class FrameStore {
    private let lock = NSLock()
    private var states: [WindowID: Kinetic] = [:]
    subscript(id: WindowID) -> Kinetic? {
        get { lock.withLock { states[id] } }
        set { lock.withLock { states[id] = newValue } }
    }
    /// Forgets windows that are gone.
    func keep(_ ids: Set<WindowID>) { lock.withLock { states = states.filter { ids.contains($0.key) } } }
}

/// Moves windows to their new frames on a spring. Runs on `axQueue`.
///
/// - The spring is critically damped: it starts from rest (no jump), eases in quickly, lands softly and never
///   overshoots, so tiles never cross into each other.
/// - A newer layout bumps `generation`: the running animation stops where it is, and the next one carries on
///   from there at the same velocity, so retargeting mid-flight is seamless.
/// - Frames are written once per display refresh, to all windows together, with the window server's screen
///   updates held meanwhile, so every window moves in the same refresh: neighbours never show a gap or an
///   overlap halfway through a frame.
/// - Each app has its own writer that always takes the newest frame. An app that's busy (say, handling the
///   focus change) skips frames on its own; it never holds up the other windows or the screen past `budget`.
/// - Progress comes from the clock: a slow app costs frames, never time.
enum Animator {
    struct Result {
        var floating: [(WindowID, CGRect)] = []
        var oversized: [(id: WindowID, actual: CGSize, wanted: CGSize)] = []
        /// Frames written, and the slowest one (seconds), for the debug log.
        var frames = 0
        var slowest = 0.0
        /// How long finding the start frames took, before the first frame.
        var setup = 0.0
        /// When the first frame was on screen (`CACurrentMediaTime`), and how long the glide lasted.
        var firstFrameAt: Double?
        var seconds = 0.0
    }

    private final class Track {
        let move: Move
        var from = CGRect.zero
        /// Its size before this layout (`from` already has the new one), to spot apps with a minimum size.
        var startSize = CGSize.zero
        var to = CGRect.zero
        var last = CGRect.zero
        var next = CGRect.zero
        var x0 = SIMD4<Double>(repeating: 0), x1 = SIMD4<Double>(repeating: 0)
        var v0 = SIMD4<Double>(repeating: 0), velocity = SIMD4<Double>(repeating: 0)
        var done = false
        init(_ m: Move) { move = m }
    }

    /// How long a frame waits for the apps (and holds the screen) before moving on without the slow ones.
    private static let budget = DispatchTimeInterval.microseconds(7_000)

    /// Writes one app's windows on its own queue; while it's still busy with an older frame, newer ones skip it.
    private final class Writer {
        let queue: DispatchQueue
        private let lock = NSLock()
        private var busy = false
        init(_ pid: pid_t) { queue = DispatchQueue(label: "panespace.anim.\(pid)", qos: .userInteractive) }
        func claim() -> Bool {
            lock.withLock {
                if busy { return false }
                busy = true
                return true
            }
        }
        func release() { lock.withLock { busy = false } }
    }

    static func run(_ moves: [Move], duration: Double, gen: Int, generation: Counter, store: FrameStore,
                    monitors: [Monitor]) -> Result {
        guard !moves.isEmpty else { return Result() }
        let began = CACurrentMediaTime()
        let tracks = moves.map(Track.init)
        let groups = Dictionary(grouping: tracks, by: { $0.move.pid }).map { ($0.key, $0.value) }
        let lock = NSLock()
        var result = Result()
        var enhanced = [Bool](repeating: false, count: groups.count)

        // Where everything starts, and how fast it's already moving. Recorded right away, so even an animation
        // superseded before its first frame hands a correct starting point to the next one.
        DispatchQueue.concurrentPerform(iterations: groups.count) { g in
            let app = AXUIElement.app(groups[g].0)
            AXUIElementSetMessagingTimeout(app, 0.1)  // before the first read: a hung app costs 0.1 s, not 6
            // Some apps animate frame changes while this is on (set by e.g. VoiceOver/Magnet).
            let on = app.bool("AXEnhancedUserInterface") == true
            if on { app.set("AXEnhancedUserInterface", false) }
            for t in groups[g].1 {
                let m = t.move
                // A hung app must not hold every frame (and the screen) for the default 6 s.
                AXUIElementSetMessagingTimeout(m.el, 0.1)
                var known: CGRect?
                switch m.start {
                case .at(let r): known = r
                case .live(let fallback):
                    if let k = store[m.id] {
                        known = k.frame
                        t.v0 = k.velocity
                    } else {
                        known = fallback ?? m.el.frame ?? m.to
                    }
                case .current: known = m.el.frame ?? m.to
                }
                // Unreadable (a busy app) and no target: a slide-out. Nothing to glide; it's parked at the end
                // rather than flashing in from the screen's corner.
                guard let start = known else {
                    t.done = true
                    continue
                }
                t.to = m.to ?? start.offsetBy(dx: m.by.dx, dy: m.by.dy)
                t.startSize = start.size
                if m.readFrame { lock.withLock { result.floating.append((m.id, start)) } }
                // Size changes once, here, and only the position glides: an app redraws its content on every
                // resize, so resizing each frame is what makes heavy apps stutter. Moving is cheap.
                let sized = CGRect(origin: start.origin, size: t.to.size)
                if m.jump {
                    m.el.setFrame(sized)
                } else if start.size != t.to.size {
                    m.el.setSize(t.to.size)
                }
                t.from = sized
                t.last = sized
                t.next = sized
                t.v0 = SIMD4(t.v0.x, t.v0.y, 0, 0)
                t.x0 = Motion.vector(sized)
                t.x1 = Motion.vector(t.to)
                store[m.id] = Kinetic(frame: sized, velocity: t.v0)
            }
            lock.withLock { enhanced[g] = on }
        }

        result.setup = CACurrentMediaTime() - began
        var cancelled = false
        let writers = groups.map { Writer($0.0) }
        var slowApp = false  // some app missed a frame's budget: don't hold the screen for it again
        if duration > 0 {
            let spring = Motion.Spring(duration: duration)
            let frame = 1.0 / 120
            let cap = duration * 3 + 0.2  // a spring never quite stops; land by then regardless
            // Each app runs on its own clock, advancing at most `maxStep` per frame it actually takes: an app
            // that stalls picks up where its window was, never jumps ahead to catch up.
            let maxStep = frame * 1.25
            var clock = [Double](repeating: 0, count: groups.count)
            var seen = [Double](repeating: 0, count: groups.count)
            var first = true
            Vsync.shared.begin()
            defer { Vsync.shared.end() }
            while true {
                if !first { Vsync.shared.wait() }
                if generation.value != gen { cancelled = true; break }
                let now = CACurrentMediaTime()
                var moving = false
                var batch: [(Int, [(Track, CGRect)])] = []
                for g in groups.indices where groups[g].1.contains(where: { !$0.done }) {
                    moving = true
                    guard writers[g].claim() else { continue }  // still writing an older frame: skip this one
                    clock[g] = first ? frame : clock[g] + min(now - seen[g], maxStep)
                    seen[g] = now
                    for t in groups[g].1 where !t.done {
                        let (x, v) = spring.state(from: t.x0, velocity: t.v0, to: t.x1, at: clock[g])
                        // Within a few points and slowing: snap home rather than creep the last pixels.
                        if clock[g] > cap || (Motion.peak(x - t.x1) < 4 && Motion.peak(v) < 400) {
                            (t.next, t.velocity, t.done) = (t.to, .zero, true)
                        } else {
                            (t.next, t.velocity) = (Motion.rect(x), v)
                        }
                    }
                    batch.append((g, groups[g].1.map { ($0, $0.next) }))
                }
                if !moving { break }
                func write() {
                    let wrote = DispatchGroup()
                    for (g, next) in batch {
                        let w = writers[g]
                        wrote.enter()
                        w.queue.async {
                            for (t, r) in next { step(t, to: r) }
                            w.release()
                            wrote.leave()
                        }
                    }
                    // The first step waits for a busy app (say, one becoming active) so every window starts
                    // together. After that, nobody waits past `budget`.
                    if wrote.wait(timeout: .now() + (first ? .milliseconds(100) : budget)) == .timedOut { slowApp = true }
                }
                if first {
                    write()  // a tiny step, not worth holding the screen for while waiting on a busy app
                    let started = CACurrentMediaTime()
                    result.firstFrameAt = started
                    for g in groups.indices { seen[g] = started }
                    first = false
                } else {
                    ScreenUpdates.hold(write)
                }
                for (_, next) in batch { for (t, _) in next { store[t.move.id] = Kinetic(frame: t.next, velocity: t.velocity) } }
                result.frames += 1
                result.slowest = max(result.slowest, CACurrentMediaTime() - now)
            }
        }

        for w in writers { w.queue.sync {} }  // let any write still in flight land first
        // Cancelled: every window stays where it is, mid-flight. The newer layout carries on from there, and parks
        // whatever was still sliding out (parking here would yank a window it's bringing back to a corner first).
        func finish() {
            guard !cancelled else { return }
            DispatchQueue.concurrentPerform(iterations: groups.count) { g in
                for t in groups[g].1 {
                    let m = t.move
                    if t.last != t.to, t.to != .zero {
                        if !sameMonitor(t.last, t.to, monitors) { m.el.setFrame(t.to); t.last = t.to } else { step(t, to: t.to) }
                    }
                    store[m.id] = Kinetic(frame: t.to)
                    if let mid = m.park { park(t, mid, monitors: monitors, store: store) }
                }
            }
        }
        if slowApp { finish() } else { ScreenUpdates.hold(finish) }
        // With the screen live again: reads that can wait on a slow app.
        DispatchQueue.concurrentPerform(iterations: groups.count) { g in
            for t in groups[g].1 {
                let m = t.move
                defer { AXUIElementSetMessagingTimeout(m.el, 0) }  // back to the system default
                // Asked to get smaller and stopped short: the app has a minimum size.
                guard !cancelled, m.park == nil, t.to != .zero,
                      t.to.width < t.startSize.width - 0.5 || t.to.height < t.startSize.height - 0.5,
                      let s = m.el.size, s.width > t.to.width + 2 || s.height > t.to.height + 2 else { continue }
                lock.withLock { result.oversized.append((m.id, s, t.to.size)) }
            }
            let app = AXUIElement.app(groups[g].0)
            if lock.withLock({ enhanced[g] }) { app.set("AXEnhancedUserInterface", true) }
            AXUIElementSetMessagingTimeout(app, 0)
        }
        result.firstFrameAt = result.firstFrameAt ?? CACurrentMediaTime()  // nothing to glide: written in place
        result.seconds = CACurrentMediaTime() - (result.firstFrameAt ?? began)
        return result
    }

    /// Writes one frame. Growing moves first and then grows, shrinking shrinks first and then moves, so the
    /// window never pokes past its final edges; an unchanged size is a single position write.
    private static func step(_ t: Track, to r: CGRect) {
        guard r != t.last else { return }
        let el = t.move.el
        if r.size == t.last.size {
            el.setPosition(r.origin)
        } else if r.width > t.last.width || r.height > t.last.height {
            el.setPosition(r.origin)
            el.setSize(r.size)
        } else {
            el.setSize(r.size)
            el.setPosition(r.origin)
        }
        t.last = r
    }

    private static func park(_ t: Track, _ mid: MonitorID, monitors: [Monitor], store: FrameStore) {
        let p = hidePoint(mid, monitors: monitors) { CGSize(width: t.move.parkWidth ?? t.to.width, height: t.to.height) }
        t.move.el.setPosition(p)
        store[t.move.id] = Kinetic(frame: CGRect(origin: p, size: t.to.size))
    }
}

/// Holds the window server's screen updates while a frame is written, so every window's move shows in the
/// same refresh. SkyLight, loaded via dlsym like `Focus`: without it, frames still work, just not atomically.
enum ScreenUpdates {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Toggle = @convention(c) (Int32) -> Int32
    private static let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func sym<T>(_ name: String, _: T.Type) -> T? {
        guard let skylight, let p = dlsym(skylight, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    private static let connection = sym("SLSMainConnectionID", Connection.self).map { $0() }
    private static let disable = sym("SLSDisableUpdate", Toggle.self)
    private static let enable = sym("SLSReenableUpdate", Toggle.self)

    static func hold(_ body: () -> Void) {
        guard let connection, let disable, let enable else { return body() }
        _ = disable(connection)
        defer { _ = enable(connection) }
        body()
    }
}

/// Wakes the animation thread once per display refresh, so each frame lands in step with the screen (120 Hz
/// on ProMotion). macOS 14+: a CADisplayLink on the main run loop, paused while nothing animates; before
/// that, or until the link is running, a steady 120 Hz sleep.
final class Vsync: NSObject {
    static let shared = Vsync()
    private let tick = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var users = 0
    private var running = false
    private var link: AnyObject?

    func begin() {
        lock.withLock { users += 1 }
        DispatchQueue.main.async { self.update() }
    }

    func end() {
        lock.withLock { users -= 1 }
        DispatchQueue.main.async { self.update() }
    }

    /// Displays changed: the link may belong to one that's gone. Main thread.
    func displaysChanged() {
        if #available(macOS 14.0, *) { (link as? CADisplayLink)?.invalidate() }
        link = nil
        lock.withLock { running = false }
        update()
    }

    /// Blocks until the next refresh (never more than 20 ms).
    func wait() {
        guard lock.withLock({ running }) else {
            usleep(8_333)
            return
        }
        // A refresh already went by while the last frame was written: go now, or a slow frame costs two.
        var late = false
        while tick.wait(timeout: .now()) == .success { late = true }
        if late { return }
        _ = tick.wait(timeout: .now() + .milliseconds(20))
    }

    private func update() {  // main thread
        let active = lock.withLock { users > 0 }
        guard #available(macOS 14.0, *) else { return }
        if link == nil, active, let screen = NSScreen.main {
            let l = screen.displayLink(target: self, selector: #selector(fire(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        guard let l = link as? CADisplayLink else { return }
        l.isPaused = !active
        lock.withLock { running = active }
    }

    @objc private func fire(_ link: AnyObject) { tick.signal() }
}

/// The monitor under a frame's center, if any (none for a window parked or sliding off screen).
private func monitorID(of r: CGRect, _ monitors: [Monitor]) -> MonitorID? {
    monitors.first { $0.frame.contains(CGPoint(x: r.midX, y: r.midY)) }?.id
}

/// Both frames' centers are on the same monitor.
func sameMonitor(_ a: CGRect, _ b: CGRect, _ monitors: [Monitor]) -> Bool {
    let m = monitorID(of: a, monitors)
    return m != nil && m == monitorID(of: b, monitors)
}
