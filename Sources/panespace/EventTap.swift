import AppKit
import MacKit
import PanespaceCore

/// Global hotkeys + mouse tracking via a CGEventTap on its own thread, so a slow AX call on the
/// main thread never delays typing. Needs only the Accessibility permission.
final class EventTap {
    /// A bound key's command, and when the key was pressed (`CACurrentMediaTime`), for `panespace stats`.
    var onCommand: (String, Double) -> Void = { _, _ in }
    var onMouseUp: () -> Void = {}
    /// A left click the app receives (not a floating_modifier drag), at its screen point.
    var onMouseDown: (CGPoint) -> Void = { _ in }
    var onMouseMoved: (CGPoint) -> Void = { _ in }
    /// A plain left drag (say, a window by its title bar), coalesced: for the drop preview.
    var onDrag: (CGPoint) -> Void = { _ in }
    /// floating_modifier + click: begin(resize: right button), move (coalesced), end.
    var onModDrag: (ModDragPhase, CGPoint) -> Void = { _, _ in }

    enum ModDragPhase { case begin(resize: Bool), move, end }

    private let lock = NSLock()
    private var bindings: [KeyCombo: String] = [:]
    private var oneShot = false
    private var _lastAppSwitch = Date.distantPast
    /// When the user last pressed Cmd-Tab (or Cmd-`): an app activation right after it is the user's doing.
    var lastAppSwitch: Date { lock.withLock { _lastAppSwitch } }
    private var _mouseDown = false
    private var _trackMoves = false
    private var floatingModifier: Modifiers?
    /// Held with the scroll wheel, goes to the next/previous workspace (`workspace_scroll`); nil = off.
    private var scrollModifier: Modifiers?
    /// Trackpad/Magic Mouse scrolling, summed until it is far enough for one workspace.
    private var scrollTravel = 0.0
    private var lastScrollSwitch = 0.0
    /// When fn went down, and whether anything else happened before it came up (a tap of fn alone is a key).
    private var fnDownAt = 0.0
    private var fnUsed = true
    private var capsLock = false
    private var interceptFullscreen = true
    private var dragButton: CGMouseButton?
    private var dragPoint = CGPoint.zero
    private var dragDispatchPending = false
    private var plainDragPoint = CGPoint.zero
    private var plainDragPending = false
    private var tap: CFMachPort?

    var isMouseDown: Bool { lock.withLock { _mouseDown } }

    /// Marks the zero-distance mouse move Panespace posts to refresh the cursor (`WindowManager.refreshCursor`).
    static let cursorRefreshTag: Int64 = 0x7061_6e65  // "pane"

    /// The latest left click: how many in a row, and whether the mouse really moved while it was down.
    struct Click {
        var seq = 0
        var count = 0
        var dragged = false
        var down = CGPoint.zero
        var upAt = Date.distantPast
    }
    private var _click = Click()
    var click: Click { lock.withLock { _click } }

    func setBindings(_ b: [KeyCombo: String], trackMouseMoves: Bool, floatingModifier: Modifiers?, capsLock: Bool,
                     interceptFullscreen: Bool, oneShot: Bool = false, scrollWorkspaces: Bool = false) {
        lock.withLock {
            scrollModifier = scrollWorkspaces ? floatingModifier : nil
            self.oneShot = oneShot
            self.interceptFullscreen = interceptFullscreen
            bindings = b
            _trackMoves = trackMouseMoves
            self.floatingModifier = floatingModifier
            self.capsLock = capsLock
        }
    }

    /// Event flags plus Caps Lock (when it is the panespace key and held).
    private func modifiers(_ event: CGEvent) -> (Modifiers, capsHeld: Bool) {
        var mods = EventTap.modifiers(event.flags)
        // Caps (the companion app) swallows the Caps Lock key itself and tags what it passes on instead.
        let tagged = event.getIntegerValueField(.eventSourceUserData) == CapsLock.heldTag
        // Ask the keyboard itself, not our own record: a missed key-up must never leave Caps "stuck"
        // (that would swallow everything you type). The HID state sees the key even though we swallow it.
        let held = lock.withLock { capsLock } && (tagged || CapsLock.isPhysicallyDown)
        if held { mods.insert(.caps) }
        return (mods, held)
    }

    private static func modifiers(_ f: CGEventFlags) -> Modifiers {
        var mods: Modifiers = []
        if f.contains(.maskShift) { mods.insert(.shift) }
        if f.contains(.maskControl) { mods.insert(.control) }
        if f.contains(.maskAlternate) { mods.insert(.option) }
        if f.contains(.maskCommand) { mods.insert(.command) }
        return mods
    }

    func start() -> Bool {
        var mask: CGEventMask = 0
        for t in [CGEventType.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown,
                  .rightMouseUp, .rightMouseDragged, .mouseMoved, .scrollWheel, .flagsChanged] { mask |= 1 << t.rawValue }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<EventTap>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handle(type, event)
        }
        // Tail: the Caps app (head) sees keys first, handles its per-app bindings and passes the rest here.
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passRetained(self).toOpaque()) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "panespace.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    /// True for the commands where holding the key is useful: focus, move (a direction) and resize.
    private static func repeats(_ cmd: String) -> Bool {
        let w = cmd.split(separator: " ").map(String.init)
        if w.first == "focus" || w.first == "move" { return w.count == 2 }
        return w.first == "resize"
    }

    /// Scroll down (or toward you on a trackpad) is the next workspace. A wheel notch is one workspace; continuous
    /// scrolling must travel a way first, then waits out its momentum, so one flick never skips several.
    private func scrollCommand(_ event: CGEvent) -> String? {
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
        let dy = continuous ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
                            : Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        let now = CACurrentMediaTime()
        return lock.withLock { () -> String? in
            var step = 0.0
            if continuous {
                if momentum || now - lastScrollSwitch < 0.35 { scrollTravel = 0; return nil }
                scrollTravel += dy
                guard abs(scrollTravel) >= 40 else { return nil }
                step = scrollTravel
                scrollTravel = 0
            } else {
                guard dy != 0, now - lastScrollSwitch > 0.05 else { return nil }
                step = dy
            }
            lastScrollSwitch = now
            return step < 0 ? "workspace next_on_output" : "workspace prev_on_output"
        }
    }

    /// The key pressed in a one-shot mode: leave the mode, then run its command (none: just leave).
    private func oneShotKey(_ cmd: String?) {
        lock.withLock { oneShot = false }  // a fast second key goes to the default bindings
        let run = cmd.map { "mode default; " + $0 } ?? "mode default"
        let t = CACurrentMediaTime()
        DispatchQueue.main.async { self.onCommand(run, t) }
    }

    private let debug = ProcessInfo.processInfo.environment["PANESPACE_DEBUG"] != nil

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if debug && type != .mouseMoved {
            log("tap: type=\(type.rawValue) code=\(event.getIntegerValueField(.keyboardEventKeycode)) flags=\(String(event.flags.rawValue, radix: 16))")
        }
        if event.getIntegerValueField(.eventSourceUserData) == CapsLock.syntheticTag {
            return Unmanaged.passUnretained(event)  // a key the Caps app produced (e.g. Caps+J → ↓): not ours
        }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // A button released while the tap was off was never seen: believe the hardware, or a stuck "down"
            // would hold back every window scan (and a stuck mod-drag would swallow every drag) until next click.
            let left = CGEventSource.buttonState(.combinedSessionState, button: .left)
            let right = CGEventSource.buttonState(.combinedSessionState, button: .right)
            let ended = lock.withLock { () -> Bool in
                if !left { _mouseDown = false }
                guard let b = dragButton, !(b == .left ? left : right) else { return false }
                dragButton = nil
                return true
            }
            if ended {
                let p = CGEvent(source: nil)?.location ?? .zero
                DispatchQueue.main.async { self.onModDrag(.end, p) }
            }
        case .keyDown, .keyUp:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let capsLock = lock.withLock { self.capsLock }
            if capsLock && code == CapsLock.f18KeyCode {
                return nil  // the Caps key itself never reaches apps
            }
            guard type == .keyDown else { break }
            let repeats = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            var (mods, capsHeld) = modifiers(event)
            lock.withLock { fnUsed = true }  // fn+key: not a tap of fn alone
            // fn is a modifier only on keys that don't report it by themselves (the arrows always do).
            if event.flags.contains(.maskSecondaryFn), !Keys.fnByNature.contains(code) { mods.insert(.fn) }
            if mods.contains(.command), code == 0x30 || code == 0x32 { lock.withLock { _lastAppSwitch = Date() } }
            var cmd = lock.withLock { bindings[KeyCombo(keyCode: code, modifiers: mods)] }
            // macOS's own full-screen keys (⌃⌘F, Globe+F) would move the app to a separate Space.
            if cmd == nil, code == 0x03, lock.withLock({ interceptFullscreen }),
               mods == [.control, .command] || mods == [.fn] {
                cmd = "fullscreen toggle"
            }
            // A one-shot mode (leader key): leave it first, then run the key's command (which may enter
            // another mode, e.g. resize). A key it doesn't bind just leaves it, and never reaches the app.
            if lock.withLock({ oneShot }) {
                if repeats { return nil }  // holding the leader key must not pick a command by itself
                oneShotKey(cmd)
                return nil
            }
            if let cmd {
                // Holding a key may repeat focus, move and resize; toggles and modes would flip on each repeat.
                if repeats && !Self.repeats(cmd) { return nil }
                let t = CACurrentMediaTime()
                DispatchQueue.main.async { self.onCommand(cmd, t) }
                return nil  // swallow
            }
            if capsHeld { return nil }  // Caps held + unbound key: do nothing rather than type the letter
        case .leftMouseDown, .rightMouseDown:
            let button: CGMouseButton = type == .rightMouseDown ? .right : .left
            let (mods, _) = modifiers(event)
            let count = Int(event.getIntegerValueField(.mouseEventClickState))
            let p0 = event.location
            let startDrag = lock.withLock { () -> Bool in
                fnUsed = true
                if button == .left {
                    _mouseDown = true
                    _click = Click(seq: _click.seq + 1, count: count, dragged: false, down: p0)
                }
                guard dragButton == nil, let fm = floatingModifier, mods.isSuperset(of: fm) else { return false }
                dragButton = button
                return true
            }
            if startDrag {
                let p = event.location
                DispatchQueue.main.async { self.onModDrag(.begin(resize: button == .right), p) }
                return nil  // the app never sees the click
            }
            if button == .left { DispatchQueue.main.async { self.onMouseDown(p0) } }
        case .leftMouseDragged, .rightMouseDragged:
            // Coalesce: at most one move in flight on the main thread, always with the latest point.
            let p1 = event.location
            let (active, dispatch, plain) = lock.withLock { () -> (Bool, Bool, Bool) in
                // A few points of jitter in a double-click isn't a drag.
                if !_click.dragged, hypot(p1.x - _click.down.x, p1.y - _click.down.y) > 4 { _click.dragged = true }
                guard dragButton != nil else {
                    guard type == .leftMouseDragged, _click.dragged else { return (false, false, false) }
                    plainDragPoint = p1
                    defer { plainDragPending = true }
                    return (false, false, !plainDragPending)
                }
                dragPoint = event.location
                defer { dragDispatchPending = true }
                return (true, !dragDispatchPending, false)
            }
            if plain {
                DispatchQueue.main.async {
                    let p = self.lock.withLock { () -> CGPoint in
                        self.plainDragPending = false
                        return self.plainDragPoint
                    }
                    self.onDrag(p)
                }
            }
            if dispatch {
                DispatchQueue.main.async {
                    let p = self.lock.withLock { () -> CGPoint in
                        self.dragDispatchPending = false
                        return self.dragPoint
                    }
                    self.onModDrag(.move, p)
                }
            }
            if active { return nil }
        case .leftMouseUp, .rightMouseUp:
            let button: CGMouseButton = type == .rightMouseUp ? .right : .left
            let endDrag = lock.withLock { () -> Bool in
                if button == .left { _mouseDown = false; _click.upAt = Date() }
                guard dragButton == button else { return false }
                dragButton = nil
                return true
            }
            let p = event.location
            if endDrag {
                DispatchQueue.main.async { self.onModDrag(.end, p) }
                return nil
            }
            if button == .left { DispatchQueue.main.async { self.onMouseUp() } }
        case .flagsChanged:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard code == Keys.fnCode else {
                lock.withLock { fnUsed = true }  // another modifier joined: fn+shift… isn't a tap
                break
            }
            let now = CACurrentMediaTime()
            let down = event.flags.contains(.maskSecondaryFn)
            let others = !event.flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]).isEmpty
            // A tap of fn alone, quick and with nothing else pressed: `bindsym fn …`.
            let (tapped, cmd, inOneShot) = lock.withLock { () -> (Bool, String?, Bool) in
                if down {
                    fnDownAt = now
                    fnUsed = others
                    return (false, nil, false)
                }
                guard !fnUsed, !others, now - fnDownAt < 0.4 else { return (false, nil, false) }
                fnUsed = true
                return (true, bindings[KeyCombo(keyCode: Keys.fnCode, modifiers: [])], oneShot)
            }
            guard tapped else { break }
            if inOneShot { oneShotKey(cmd) } else if let cmd {
                let t = CACurrentMediaTime()
                DispatchQueue.main.async { self.onCommand(cmd, t) }
            }
        case .scrollWheel:
            guard let sm = lock.withLock({ scrollModifier }), modifiers(event).0.isSuperset(of: sm) else { break }
            if let cmd = scrollCommand(event) {
                let t = CACurrentMediaTime()
                DispatchQueue.main.async { self.onCommand(cmd, t) }
            }
            return nil  // the app under the mouse doesn't scroll while the modifier is held
        case .mouseMoved:
            // Panespace's own cursor refresh after a layout change: not the user pointing at something.
            if event.getIntegerValueField(.eventSourceUserData) == EventTap.cursorRefreshTag { break }
            if lock.withLock({ _trackMoves }) {
                let p = event.location
                DispatchQueue.main.async { self.onMouseMoved(p) }
            }
        default: break
        }
        return Unmanaged.passUnretained(event)
    }
}
