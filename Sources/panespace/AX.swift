import AppKit
import PanespaceCore
import ApplicationServices
import MacKit

/// Private but stable since 10.x; maps an AX window to its CGWindowID. Exported from HIServices.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    static func app(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

    func raw(_ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, name as CFString, &v) == .success ? v : nil
    }

    func string(_ name: String) -> String? { raw(name) as? String }

    func bool(_ name: String) -> Bool? { (raw(name) as? NSNumber)?.boolValue }

    func element(_ name: String) -> AXUIElement? {
        guard let v = raw(name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    var role: String? { string(kAXRoleAttribute) }
    var subrole: String? { string(kAXSubroleAttribute) }
    var title: String { string(kAXTitleAttribute) ?? "" }
    var isMinimized: Bool { bool(kAXMinimizedAttribute) ?? false }
    /// In macOS full screen (its own Space), or on its way there.
    var isFullScreen: Bool { bool("AXFullScreen") ?? false }
    var focusedWindow: AXUIElement? { element(kAXFocusedWindowAttribute) }

    var windows: [AXUIElement] {
        guard let v = raw(kAXWindowsAttribute), CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
        return (v as! [AnyObject]).compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        }
    }

    /// nil when the app didn't answer (busy, launching). Callers must not read that as "no windows".
    var windowsIfAvailable: [AXUIElement]? {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(self, kAXWindowsAttribute as CFString, &v)
        if err == .noValue { return [] }
        guard err == .success, let v, CFGetTypeID(v) == CFArrayGetTypeID() else { return nil }
        return (v as! [AnyObject]).compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        }
    }

    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    var position: CGPoint? {
        guard let v = raw(kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    var size: CGSize? {
        guard let v = raw(kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }

    func setPosition(_ p: CGPoint) {
        var p = p
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, v) }
    }

    func setSize(_ s: CGSize) {
        var s = s
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, v) }
    }

    /// Size → position → size: the first size can be clamped by the monitor the window is still on.
    func setFrame(_ r: CGRect) {
        setSize(r.size)
        setPosition(r.origin)
        setSize(r.size)
    }

    func set(_ name: String, _ value: Bool) {
        AXUIElementSetAttributeValue(self, name as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    }

    func isSettable(_ name: String) -> Bool {
        var b = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(self, name as CFString, &b) == .success && b.boolValue
    }

    @discardableResult
    func perform(_ action: String) -> Bool { AXUIElementPerformAction(self, action as CFString) == .success }
}

/// Reads what classification needs from a window (a few AX calls), for `WindowTraits.kind`.
func traits(_ w: AXUIElement, bundleID: String, layer: Int?) -> WindowTraits {
    let role = w.role ?? ""
    guard role == kAXWindowRole, layer ?? 0 == 0 else { return WindowTraits(bundleID: bundleID, role: role, layer: layer) }
    let fs = w.element(kAXFullScreenButtonAttribute)
    return WindowTraits(bundleID: bundleID, role: role, subrole: w.subrole ?? "", title: w.title,
                        identifier: w.string("AXIdentifier"),
                        hasCloseButton: w.element(kAXCloseButtonAttribute) != nil,
                        hasMinimizeButton: w.element(kAXMinimizeButtonAttribute) != nil,
                        fullScreenButtonEnabled: fs.map { $0.bool(kAXEnabledAttribute) ?? true },
                        sizeSettable: w.isSettable(kAXSizeAttribute), layer: layer)
}

func classify(_ w: AXUIElement, bundleID: String, layer: Int?) -> WindowKind {
    traits(w, bundleID: bundleID, layer: layer).kind
}

/// Window number → layer, for every window the window server knows (also off-screen).
struct ServerWindow {
    let layer: Int
    /// On the current Space. A window that's on screen but gone from its app's list is closing.
    let onscreen: Bool
}

func windowServerSnapshot() -> [CGWindowID: ServerWindow] {
    guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] else { return [:] }
    var out: [CGWindowID: ServerWindow] = [:]
    for d in list {
        if let n = d[kCGWindowNumber as String] as? Int {
            out[CGWindowID(n)] = ServerWindow(layer: d[kCGWindowLayer as String] as? Int ?? 0,
                                              onscreen: d[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }
    return out
}

/// `panespace msg -t get_windows`: every window of every app as Accessibility sees it, managed or not, with how
/// Panespace classifies it. Read inside the daemon (which has the permission), off the main thread.
func allWindowsJSON() -> String {
    let server = windowServerSnapshot()
    var rows: [[String: Any]] = []
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        let el = AXUIElement.app(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.5)
        for w in el.windows {
            guard let id = w.windowID else { continue }
            var row: [String: Any] = [
                "id": Int(id), "app": app.localizedName ?? "?", "bundle_id": app.bundleIdentifier ?? "",
                "kind": classify(w, bundleID: app.bundleIdentifier ?? "", layer: server[id]?.layer).rawValue,
                "identifier": w.string("AXIdentifier") ?? "",
                "size_settable": w.isSettable(kAXSizeAttribute),
                "fullscreen_enabled": w.element(kAXFullScreenButtonAttribute).map { $0.bool(kAXEnabledAttribute) ?? true } as Any,
                "role": w.role ?? "", "subrole": w.subrole ?? "", "title": w.title,
                "fullscreen": w.isFullScreen, "minimized": w.isMinimized,
                "buttons": [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute, kAXFullScreenButtonAttribute]
                    .filter { w.element($0) != nil },
            ]
            if let f = w.frame { row["frame"] = [Int(f.minX), Int(f.minY), Int(f.width), Int(f.height)] }
            if let s = server[id] { row["layer"] = s.layer }
            rows.append(row)
        }
    }
    return IPC.json(rows)
}
