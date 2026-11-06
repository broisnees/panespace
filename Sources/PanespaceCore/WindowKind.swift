import Foundation

/// How Panespace treats a window: a tile, a floating window, or not a window at all (popups, overlays,
/// menus, tooltips, child frames).
public enum WindowKind: String { case tile, float, ignore }

/// What Panespace knows about a window when it first sees it: Accessibility attributes plus the window server's
/// layer. Plain data, so the classification can be tested against real windows recorded with
/// `panespace msg -t get_windows`.
public struct WindowTraits: Equatable {
    public var bundleID: String
    public var role: String
    public var subrole: String
    public var title: String
    /// AXIdentifier, when the app sets one.
    public var identifier: String?
    public var hasCloseButton: Bool
    public var hasMinimizeButton: Bool
    /// nil = no full-screen button; false = present but disabled.
    public var fullScreenButtonEnabled: Bool?
    public var sizeSettable: Bool
    /// Window-server layer (0 = normal windows); nil when unknown.
    public var layer: Int?

    public init(bundleID: String, role: String = "AXWindow", subrole: String = "AXStandardWindow", title: String = "",
                identifier: String? = nil, hasCloseButton: Bool = true, hasMinimizeButton: Bool = true,
                fullScreenButtonEnabled: Bool? = true, sizeSettable: Bool = true, layer: Int? = 0) {
        self.bundleID = bundleID
        self.role = role
        self.subrole = subrole
        self.title = title
        self.identifier = identifier
        self.hasCloseButton = hasCloseButton
        self.hasMinimizeButton = hasMinimizeButton
        self.fullScreenButtonEnabled = fullScreenButtonEnabled
        self.sizeSettable = sizeSettable
        self.layer = layer
    }

    /// Apps whose real windows lack (or briefly disable) the full-screen button.
    static let tileAnyway: Set<String> = [
        "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.gnu.Emacs", "com.mitchellh.ghostty",
        "com.microsoft.VSCode", "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac",
        "org.chromium.Chromium", "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "org.gimp.gimp-2.10",
    ]

    /// Apps whose windows are progress or utility panels that only look like normal windows.
    static let alwaysFloat: Set<String> = ["cx.c3.theunarchiver", "com.apple.archiveutility", "com.apple.installer"]

    /// After AeroSpace/yabai's heuristics, plus the fixes for what they got wrong.
    public var kind: WindowKind {
        guard role == "AXWindow" else { return .ignore }
        // Above normal windows: menus, overlays, screen-recorder pills, picture-in-picture, HUDs.
        if let layer, layer != 0 { return .ignore }
        let bare = !hasCloseButton && title.isEmpty  // no close button, no title: a popup, not a window
        switch subrole {
        case "AXStandardWindow":
            if bundleID == "company.thebrowser.Browser", identifier?.hasPrefix("littleBrowserWindow") == true { return .float }
            if Self.tileAnyway.contains(bundleID) { return bare ? .ignore : .tile }
            if bundleID.hasPrefix("com.adobe."), hasCloseButton, hasMinimizeButton, sizeSettable { return .tile }
            if bare { return .ignore }
            if Self.alwaysFloat.contains(bundleID) { return .float }
            if fullScreenButtonEnabled != true || !sizeSettable { return .float }
            return .tile
        case "AXDialog":
            // qutebrowser's main windows are dialogs; its page popups have neither title nor close button.
            if bundleID == "org.qutebrowser.qutebrowser", hasCloseButton, !title.isEmpty { return .tile }
            return bare ? .ignore : .float
        case "AXFloatingWindow", "AXSystemDialog":
            return bare ? .ignore : .float
        default:
            return .ignore
        }
    }
}
