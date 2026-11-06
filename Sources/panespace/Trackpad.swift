import AppKit
import PanespaceCore

/// Raw touches from every trackpad, through MultitouchSupport: private, but it's how BetterTouchTool and
/// Jitouch read gestures, and it needs no permission. Loaded via dlopen: without it, gestures are just off.
/// Touch frames arrive on the framework's own thread, and so do `onEvent` calls.
final class Trackpad {
    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFMutableArray>?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
    private typealias Run = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias Halt = @convention(c) (UnsafeMutableRawPointer) -> Void

    private static let framework = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY)
    private static func sym<T>(_ name: String, _: T.Type) -> T? {
        guard let framework, let p = dlsym(framework, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    private static let createList = sym("MTDeviceCreateList", CreateList.self)
    private static let register = sym("MTRegisterContactFrameCallback", Register.self)
    private static let unregister = sym("MTUnregisterContactFrameCallback", Register.self)
    private static let run = sym("MTDeviceStart", Run.self)
    private static let halt = sym("MTDeviceStop", Halt.self)

    /// The one listening instance, for the C callback (which can't carry context).
    private static let currentLock = NSLock()
    private static var current: Trackpad?

    /// One touch record (MTTouch): 96 bytes; state at 20, normalized position (x, y; 0…1, y up) at 32 and 36.
    private static let stride = 96
    private static let callback: Callback = { device, touches, count, timestamp, _ in
        currentLock.withLock { current }?.frame(device, touches, Int(count), timestamp)
        return 0
    }

    let fingers: Int
    private let onEvent: (SwipeRecognizer.Event) -> Void
    private let lock = NSLock()
    private var recognizers: [UInt: SwipeRecognizer] = [:]
    private var devices: CFArray?

    init(fingers: Int, onEvent: @escaping (SwipeRecognizer.Event) -> Void) {
        self.fingers = fingers
        self.onEvent = onEvent
    }

    /// Listens on every trackpad there is. False when there's none, or MultitouchSupport isn't available.
    func start() -> Bool {
        guard let createList = Self.createList, let register = Self.register, let run = Self.run,
              let list = createList()?.takeRetainedValue(), CFArrayGetCount(list) > 0 else { return false }
        Self.currentLock.withLock { Self.current = self }
        for i in 0..<CFArrayGetCount(list) {
            guard let device = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(list, i)) else { continue }
            register(device, Self.callback)
            run(device, 0)
        }
        devices = list  // keeps the devices alive
        return true
    }

    func stop() {
        guard let list = devices else { return }
        for i in 0..<CFArrayGetCount(list) {
            guard let device = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(list, i)) else { continue }
            Self.unregister?(device, Self.callback)
            Self.halt?(device)
        }
        devices = nil
        Self.currentLock.withLock { if Self.current === self { Self.current = nil } }
    }

    private func frame(_ device: UnsafeMutableRawPointer?, _ touches: UnsafeMutableRawPointer?, _ n: Int, _ t: Double) {
        var count = 0, x = 0.0, y = 0.0
        if let touches {
            for i in 0..<n {
                let f = touches + i * Self.stride
                let state = f.load(fromByteOffset: 20, as: Int32.self)
                guard state == 3 || state == 4 else { continue }  // making contact, or touching
                let px = Double(f.load(fromByteOffset: 32, as: Float.self)), py = Double(f.load(fromByteOffset: 36, as: Float.self))
                guard (-0.1...1.1).contains(px), (-0.1...1.1).contains(py) else { continue }  // not a touch we understand
                count += 1
                x += px
                y += py
            }
        }
        if count > 0 { x /= Double(count); y /= Double(count) }
        let key = UInt(bitPattern: device)
        let events = lock.withLock { () -> [SwipeRecognizer.Event] in
            var r = recognizers[key] ?? SwipeRecognizer(fingers: fingers)
            let e = r.frame(count: count, x: x, y: y, t: t)
            recognizers[key] = r
            return e
        }
        events.forEach(onEvent)
    }
}

/// The live sideways offset of a workspace swipe, shared by the touch thread (writes), the follow loop and the
/// main thread (read). `map` turns trackpad travel into points, rubber band included.
final class SwipeTrack {
    private let lock = NSLock()
    private var travel = 0.0
    private var finished = true
    private var map: (Double) -> Double = { _ in 0 }

    /// A swipe began on the touch thread: start from zero.
    func reset() { lock.withLock { travel = 0; finished = false } }
    /// The main thread worked out how travel maps to points for this swipe.
    func setMap(_ m: @escaping (Double) -> Double) { lock.withLock { map = m } }
    func move(_ t: Double) { lock.withLock { travel = t } }
    func finish() { lock.withLock { finished = true } }
    /// Offset in points, and whether the swipe is over.
    var state: (offset: Double, finished: Bool) { lock.withLock { (map(travel), finished) } }
}
