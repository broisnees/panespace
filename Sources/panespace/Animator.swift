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

/// The last frame Panespace wrote to each window, so an interrupted animation is picked up mid-flight.
final class FrameStore {
    private let lock = NSLock()
    private var frames: [WindowID: CGRect] = [:]
    subscript(id: WindowID) -> CGRect? {
        get { lock.withLock { frames[id] } }
        set { lock.withLock { frames[id] = newValue } }
    }
}

/// Glides windows to their new frames. Runs on `axQueue`.
///
/// Every frame is written to all windows together (one thread per app), and progress comes from the clock,
/// so a slow app costs frames, never time: the animation always lands on schedule. A newer layout bumps
/// `generation`; the running animation then stops where it is and the next one carries on from there.
enum Animator {
    struct Result {
        var floating: [(WindowID, CGRect)] = []
        var oversized: [(id: WindowID, actual: CGSize, wanted: CGSize)] = []
        /// Frames written, and the slowest one (seconds), for the debug log.
        var frames = 0
        var slowest = 0.0
        /// How long finding the start frames took, before the first frame.
        var setup = 0.0
    }

    private final class Track {
        let move: Move
        var from = CGRect.zero
        var to = CGRect.zero
        var last = CGRect.zero
        init(_ m: Move) { move = m }
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

        // Where everything starts. Recorded right away, so even an animation superseded before its first
        // frame hands a correct starting point to the next one.
        DispatchQueue.concurrentPerform(iterations: groups.count) { g in
            let app = AXUIElement.app(groups[g].0)
            // Some apps animate frame changes while this is on (set by e.g. VoiceOver/Magnet).
            let on = app.bool("AXEnhancedUserInterface") == true
            if on { app.set("AXEnhancedUserInterface", false) }
            for t in groups[g].1 {
                let m = t.move
                let start: CGRect
                switch m.start {
                case .at(let r): start = r
                case .live(let fallback): start = store[m.id] ?? fallback ?? m.el.frame ?? m.to ?? .zero
                case .current: start = m.el.frame ?? m.to ?? .zero
                }
                t.from = start
                t.to = m.to ?? start.offsetBy(dx: m.by.dx, dy: m.by.dy)
                t.last = start
                if m.jump { m.el.setFrame(start) }
                store[m.id] = start
                if m.readFrame { lock.withLock { result.floating.append((m.id, start)) } }
            }
            lock.withLock { enhanced[g] = on }
        }

        result.setup = CACurrentMediaTime() - began
        var cancelled = false
        if duration > 0 {
            let t0 = CACurrentMediaTime()
            let frame = 1.0 / 120
            while true {
                let now = CACurrentMediaTime()
                let t = (now - t0) / duration
                if t >= 1 { break }
                if generation.value != gen { cancelled = true; break }
                let p = Motion.ease(t)
                DispatchQueue.concurrentPerform(iterations: groups.count) { g in
                    for t in groups[g].1 { step(t, to: Motion.lerp(t.from, t.to, p), store: store) }
                }
                let spent = CACurrentMediaTime() - now
                result.frames += 1
                result.slowest = max(result.slowest, spent)
                if spent < frame { usleep(useconds_t((frame - spent) * 1_000_000)) }
            }
        }

        DispatchQueue.concurrentPerform(iterations: groups.count) { g in
            for t in groups[g].1 {
                let m = t.move
                if cancelled {
                    // Leave moving windows where they are for the next animation, but never leave a hidden
                    // workspace's window stranded half on screen.
                    if let mid = m.park { park(t, mid, monitors: monitors, store: store) }
                    continue
                }
                if t.last != t.to {
                    if !sameMonitor(t.last, t.to, monitors) { m.el.setFrame(t.to) } else { step(t, to: t.to, store: store) }
                }
                store[m.id] = t.to
                if let mid = m.park {
                    park(t, mid, monitors: monitors, store: store)
                } else if t.to.width < t.from.width - 0.5 || t.to.height < t.from.height - 0.5,
                          let s = m.el.size, s.width > t.to.width + 2 || s.height > t.to.height + 2 {
                    // Asked to get smaller and stopped short: the app has a minimum size.
                    lock.withLock { result.oversized.append((m.id, s, t.to.size)) }
                }
            }
            if lock.withLock({ enhanced[g] }) { AXUIElement.app(groups[g].0).set("AXEnhancedUserInterface", true) }
        }
        return result
    }

    /// Writes one frame. Growing moves first and then grows, shrinking shrinks first and then moves, so the
    /// window never pokes past its final edges; an unchanged size is a single position write.
    private static func step(_ t: Track, to r: CGRect, store: FrameStore) {
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
        store[t.move.id] = r
    }

    private static func park(_ t: Track, _ mid: MonitorID, monitors: [Monitor], store: FrameStore) {
        let p = hidePoint(mid, monitors: monitors) { CGSize(width: t.move.parkWidth ?? t.to.width, height: t.to.height) }
        t.move.el.setPosition(p)
        store[t.move.id] = CGRect(origin: p, size: t.to.size)
    }
}

/// Both frames' centers are on the same monitor.
func sameMonitor(_ a: CGRect, _ b: CGRect, _ monitors: [Monitor]) -> Bool {
    let m = { (r: CGRect) in monitors.first { $0.frame.contains(CGPoint(x: r.midX, y: r.midY)) }?.id }
    return m(a) != nil && m(a) == m(b)
}
