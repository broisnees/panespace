import AppKit
import ApplicationServices
import PanespaceCore

/// Focusing another app's window from a background agent. Since macOS 14 `activate` is only a
/// request, so like yabai/alt-tab we use SkyLight when present (loaded via dlsym: fails soft),
/// then raise via AX and activate as a fallback.
enum Focus {
    private typealias SetFront = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias PSNForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private static let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func sym<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, _: T.Type) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    private static let setFront = sym(skylight, "_SLPSSetFrontProcessWithOptions", SetFront.self)
    private static let postRecord = sym(skylight, "SLPSPostEventRecordTo", PostRecord.self)
    private static let psnForPID = sym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID", PSNForPID.self)

    static let debug = ProcessInfo.processInfo.environment["PANESPACE_DEBUG"] != nil
    static func lap(_ t: inout UInt64, _ s: String) {
        guard debug else { return }
        let n = DispatchTime.now().uptimeNanoseconds
        log(String(format: "    focus.%@ %.2f ms", s, Double(n - t) / 1e6))
        t = n
    }

    /// `current`: still wanted. Checked before the steps that can wait on a busy app, so a focus that was
    /// overtaken by a newer one never lands after it.
    static func focus(pid: pid_t, windowID: CGWindowID, element: AXUIElement, current: () -> Bool = { true }) {
        var t = DispatchTime.now().uptimeNanoseconds
        var psn = ProcessSerialNumber()
        var madeKey = false
        if let psnForPID, let setFront, let postRecord, psnForPID(pid, &psn) == noErr {
            _ = setFront(&psn, windowID, 0x200)  // kCPSUserGenerated
            lap(&t, "setFront")
            // Synthetic "make key window" record. 0x100 bytes: 14.7.4+ reads past 0xf8.
            var bytes = [UInt8](repeating: 0, count: 0x100)
            bytes[0x04] = 0xF8
            bytes[0x3A] = 0x10
            var wid = windowID
            withUnsafeBytes(of: &wid) { src in for i in 0..<4 { bytes[0x3C + i] = src[i] } }
            // Far-away click point so no app treats it as a real click.
            var pt = CGPoint(x: 300_000, y: 300_000)
            withUnsafeBytes(of: &pt) { src in for i in 0..<16 { bytes[0x20 + i] = src[i] } }
            bytes[0x08] = 0x01
            madeKey = bytes.withUnsafeMutableBufferPointer { postRecord(&psn, $0.baseAddress!) } == .success
            lap(&t, "postRecord")
        }
        if !madeKey {  // SkyLight unavailable: fall back to the public AX route (can stall on busy apps)
            element.set(kAXMainAttribute, true)
            lap(&t, "axMain")
        }
        guard current() else { return }
        element.perform(kAXRaiseAction)
        lap(&t, "axRaise")
        guard current() else { return }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        lap(&t, "activate")
    }
}

/// An invisible 1-px key window Panespace shows on a display whose workspace is empty, so macOS moves the menu
/// bar (and Spotlight, and new windows) to that display. Activating Panespace alone leaves them where the last
/// key window was, since a menu bar follows its app's key window (AeroSpace #576).
final class FocusHolder {
    private final class Pane: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }
    private var pane: Pane?
    private(set) var monitor: MonitorID?

    /// Makes Panespace active with its key window on `id`'s screen.
    func take(_ id: MonitorID) {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        guard let screen else { return NSApp.activate(ignoringOtherApps: true) }
        let p = pane ?? {
            let p = Pane(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.moveToActiveSpace, .ignoresCycle, .transient]
            pane = p
            return p
        }()
        let v = screen.visibleFrame
        p.setFrame(NSRect(x: v.midX, y: v.midY, width: 1, height: 1), display: false)
        monitor = id
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    /// A real window has focus again.
    func release() {
        guard monitor != nil else { return }
        monitor = nil
        pane?.orderOut(nil)
    }
}
