import XCTest
@testable import PanespaceCore

/// Tricky windows from real bug reports (AeroSpace issue numbers), described the way Accessibility reports them.
/// Record more with `panespace msg -t get_windows` and add them here.
final class WindowKindTests: XCTestCase {
    private func kind(_ t: WindowTraits) -> WindowKind { t.kind }

    func testOrdinaryWindowsTile() {
        XCTAssertEqual(kind(.init(bundleID: "com.apple.finder", title: "Downloads")), .tile)
        XCTAssertEqual(kind(.init(bundleID: "com.mitchellh.ghostty", title: "~", fullScreenButtonEnabled: nil)), .tile)
        XCTAssertEqual(kind(.init(bundleID: "com.google.Chrome", title: "Gmail", fullScreenButtonEnabled: false)), .tile)
    }

    func testPopupsAndOverlaysAreNotWindows() {
        // #1101 macOS screen-sharing pill, #1271 Screen Studio, #933 Meet PiP: above the normal layer.
        XCTAssertEqual(kind(.init(bundleID: "com.apple.controlcenter", layer: 25)), .ignore)
        XCTAssertEqual(kind(.init(bundleID: "com.google.Chrome", title: "Picture in Picture", layer: 3)), .ignore)
        // #1324 Chrome extension popup, #776/#721 Emacs child frame: standard subrole, no title, no close button.
        XCTAssertEqual(kind(.init(bundleID: "com.google.Chrome", hasCloseButton: false, hasMinimizeButton: false)), .ignore)
        XCTAssertEqual(kind(.init(bundleID: "org.gnu.Emacs", hasCloseButton: false, hasMinimizeButton: false,
                                  fullScreenButtonEnabled: nil)), .ignore)
        // #2170 Wispr Flow / #53 Sonoma text cursor: bare standard windows of ordinary apps.
        XCTAssertEqual(kind(.init(bundleID: "com.electron.wispr-flow", hasCloseButton: false, hasMinimizeButton: false,
                                  fullScreenButtonEnabled: nil)), .ignore)
        // #204 qutebrowser dropdown: an untitled dialog with no close button.
        XCTAssertEqual(kind(.init(bundleID: "org.qutebrowser.qutebrowser", subrole: "AXDialog", hasCloseButton: false)), .ignore)
        // Menus, sheets, tooltips are not AXWindow at all.
        XCTAssertEqual(kind(.init(bundleID: "com.apple.Safari", role: "AXSheet")), .ignore)
        XCTAssertEqual(kind(.init(bundleID: "com.apple.Safari", subrole: "AXUnknown", title: "x")), .ignore)
    }

    func testDialogsAndUtilityWindowsFloat() {
        XCTAssertEqual(kind(.init(bundleID: "com.apple.finder", subrole: "AXDialog", title: "Copy")), .float)
        XCTAssertEqual(kind(.init(bundleID: "com.apple.calculator", title: "Calculator", fullScreenButtonEnabled: nil)), .float)
        XCTAssertEqual(kind(.init(bundleID: "com.apple.systempreferences", title: "Wi-Fi", fullScreenButtonEnabled: false)), .float)
        XCTAssertEqual(kind(.init(bundleID: "com.example.fixed", title: "Fixed size", sizeSettable: false)), .float)
        // #250 Little Arc.
        XCTAssertEqual(kind(.init(bundleID: "company.thebrowser.Browser", title: "Little Arc",
                                  identifier: "littleBrowserWindow-1")), .float)
        XCTAssertEqual(kind(.init(bundleID: "company.thebrowser.Browser", title: "Arc", identifier: "bigBrowserWindow-1")), .tile)
    }

    func testAppsWithOddMainWindowsStillTile() {
        // #166/#276 qutebrowser's main window is a titled dialog.
        XCTAssertEqual(kind(.init(bundleID: "org.qutebrowser.qutebrowser", subrole: "AXDialog", title: "GitHub")), .tile)
        // #1293 Adobe apps have no working full-screen button.
        XCTAssertEqual(kind(.init(bundleID: "com.adobe.Photoshop", title: "Untitled-1", fullScreenButtonEnabled: nil)), .tile)
    }
}
