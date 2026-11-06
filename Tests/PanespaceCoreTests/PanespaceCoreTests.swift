import CoreGraphics
import XCTest
@testable import PanespaceCore

private let mon1 = Monitor(id: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1000, height: 500),
                           visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 500), isMain: true)
private let mon2 = Monitor(id: 2, name: "DELL U2720Q", frame: CGRect(x: 1000, y: 0, width: 1000, height: 500),
                           visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 500), isMain: false)

/// Compact tree notation: H[1 V[2 3]] (T = tabbed, S = stacking).
private func describe(_ n: Node) -> String {
    if let w = n as? WindowNode { return "\(w.id)" }
    let c = n as! Container
    let tag = ["splith": "H", "splitv": "V", "tabbed": "T", "stacking": "S"][c.layout.rawValue]!
    return tag + "[" + c.children.map(describe).joined(separator: " ") + "]"
}

final class TreeTests: XCTestCase {
    var m: Model!

    override func setUp() { m = Model(config: Config(), monitors: [mon1]) }

    func add(_ ids: WindowID..., floating: Bool = false, app: String = "App") {
        for id in ids { m.addWindow(id, info: WindowInfo(app: app), floating: floating, frame: nil) }
    }
    var ws: Workspace { m.focusedWorkspace }
    var tree: String { describe(ws.root) }
    var focused: WindowID? { m.focusedWindow?.id }
    func run(_ s: String, file: StaticString = #filePath, line: UInt = #line) {
        let r = m.run(s)
        XCTAssert(r.ok, "\(s): \(r.errors)", file: file, line: line)
    }
    func frame(_ id: WindowID) -> CGRect? {
        if case .tiled(let r)? = m.placements()[id] { return r }
        return nil
    }

    func testInsertAfterFocusedAndEqualSplit() {
        add(1, 2, 3)
        XCTAssertEqual(tree, "H[1 2 3]")
        XCTAssertEqual(focused, 3)
        XCTAssertEqual(frame(1), CGRect(x: 0, y: 0, width: 333, height: 500))
        XCTAssertEqual(frame(3), CGRect(x: 666, y: 0, width: 334, height: 500))
        run("focus left")
        add(4)
        XCTAssertEqual(tree, "H[1 2 4 3]")
    }

    func testNativeTabSwitchKeepsTile() {
        add(1, 2, 3)
        run("focus left")
        m.replaceWindow(2, with: 9, info: WindowInfo(app: "App", title: "tab 2"))
        XCTAssertEqual(tree, "H[1 9 3]")
        XCTAssertEqual(focused, 9)
        XCTAssertNil(m.windows[2])
        XCTAssertEqual(frame(9), CGRect(x: 333, y: 0, width: 333, height: 500))
        m.replaceWindow(9, with: 1, info: WindowInfo(app: "App"))  // already managed: no-op
        XCTAssertEqual(tree, "H[1 9 3]")
    }

    func testWindowComesBackToItsTile() {
        add(1, 2, 3)
        let spot = m.tileSpot(1)!  // leftmost: goes back before 2
        XCTAssertEqual(spot.neighbor, 2)
        XCTAssertTrue(spot.before)
        m.removeWindow(1)
        run("focus right")  // focus elsewhere, so the default would append after 3
        m.addWindow(1, info: WindowInfo(app: "App"), floating: false, frame: nil, near: spot.neighbor, before: spot.before)
        XCTAssertEqual(tree, "H[1 2 3]")
    }

    func testTabMatesComeForwardTogether() {
        add(1, 2)
        run("split v")
        add(3)  // H[1 V[2 3]]
        run("focus left")  // window 1, a direct child of the root
        run("layout tabbed")
        XCTAssertEqual(tree, "T[1 V[2 3]]")
        XCTAssertEqual(Set(m.tabMates(3)), [2])
        XCTAssertEqual(m.tabMates(1), [])
    }

    func testFocusOnActivationParses() {
        XCTAssertEqual(Config.parse("focus_on_window_activation none\n").focusOnActivation, "none")
        XCTAssertEqual(Config.parse("focus_on_window_activation smart\n").focusOnActivation, "urgent")
        XCTAssertEqual(Config.parse("").focusOnActivation, "focus")
        XCTAssertFalse(Config.parse("focus_on_window_activation bogus\n").warnings.isEmpty)
    }

    func testSplitThenOpen() {
        add(1, 2)
        run("split v")
        add(3)
        XCTAssertEqual(tree, "H[1 V[2 3]]")
        XCTAssertEqual(frame(3), CGRect(x: 500, y: 250, width: 500, height: 250))
        run("split toggle")  // parent is V → split h around 3
        add(4)
        XCTAssertEqual(tree, "H[1 V[2 H[3 4]]]")
    }

    func testSplitOnLoneWindowChangesParentLayout() {
        add(1)
        run("split v")
        add(2)
        XCTAssertEqual(tree, "V[1 2]")
    }

    func testFocusDirections() {
        add(1, 2)
        run("split v")
        add(3)
        run("focus up")
        XCTAssertEqual(focused, 2)
        run("focus left")
        XCTAssertEqual(focused, 1)
        run("focus right")  // enters V[2 3] at the most recent child
        XCTAssertEqual(focused, 2)
        run("focus down")
        XCTAssertEqual(focused, 3)
        run("focus right")  // wraps
        XCTAssertEqual(focused, 1)
    }

    func testMoveSwapsAndForcesOrientation() {
        add(1, 2, 3)
        run("move left")
        XCTAssertEqual(tree, "H[1 3 2]")
        run("move up")
        XCTAssertEqual(tree, "V[3 H[1 2]]")
        run("move down")  // i3: moving into a sibling container joins it
        XCTAssertEqual(tree, "H[1 2 3]")
    }

    func testMoveOutOfAndIntoContainers() {
        add(1, 2)
        run("split v")
        add(3)
        XCTAssertEqual(tree, "H[1 V[2 3]]")
        run("move right")  // leaves V, lands after it, V flattens
        XCTAssertEqual(tree, "H[1 2 3]")
        run("split v")
        run("focus left")
        run("move right")  // 2 swaps past… into the V[3] pending split
        XCTAssertEqual(tree, "H[1 V[3 2]]")
    }

    func testCloseNormalizes() {
        add(1, 2)
        run("split v")
        add(3)
        run("focus left")
        run("focus right")
        XCTAssertEqual(focused, 3)
        m.removeWindow(3)
        XCTAssertEqual(tree, "H[1 2]")
        XCTAssertEqual(focused, 1)  // MRU, not the neighbour
        m.removeWindow(1)
        m.removeWindow(2)
        XCTAssertEqual(tree, "H[]")
    }

    func testLayoutTabbedAccordion() {
        add(1, 2, 3)
        run("layout tabbed")
        XCTAssertEqual(tree, "T[1 2 3]")
        run("focus left")
        XCTAssertEqual(focused, 2)
        let p = Config().accordionPadding
        XCTAssertEqual(frame(1), CGRect(x: 0, y: 0, width: 1000 - p, height: 500))
        XCTAssertEqual(frame(2), CGRect(x: p, y: 0, width: 1000 - 2 * p, height: 500))
        XCTAssertEqual(frame(3), CGRect(x: p, y: 0, width: 1000 - p, height: 500))
        run("layout toggle split")
        XCTAssertEqual(tree, "H[1 2 3]")
    }

    func testResizeAndBalance() {
        add(1, 2)
        run("focus left")
        run("resize grow width 10 ppt")
        XCTAssertEqual(frame(1)?.width, 600)
        XCTAssertEqual(frame(2)?.width, 400)
        run("resize shrink width 100 px")
        XCTAssertEqual(frame(1)?.width, 500)
        run("resize grow width 2000 px")  // clamped
        XCTAssertEqual(frame(2)?.width, 50)
        run("balance")
        XCTAssertEqual(frame(1)?.width, 500)
    }

    func testMouseResizeAdaptsWeights() {
        add(1, 2, 3)
        _ = m.placements()
        m.userResized(2, to: CGRect(x: 333, y: 0, width: 433, height: 500))  // dragged right edge +100
        XCTAssertEqual(frame(2)?.width, 433)
        XCTAssertEqual(frame(1)?.width, 333)
        XCTAssertEqual(frame(3)?.width, 234)
    }

    func testAppMinimumSizeIsTiledAround() {
        add(1, 2)
        _ = m.placements()
        // Window 1 refused to go below 700 wide: its neighbour gets what's left instead of being overlapped.
        XCTAssertTrue(m.noteMinimumSize(1, actual: CGSize(width: 700, height: 500), wanted: CGSize(width: 500, height: 500)))
        XCTAssertFalse(m.noteMinimumSize(1, actual: CGSize(width: 700, height: 500), wanted: CGSize(width: 500, height: 500)))
        XCTAssertEqual(frame(1)?.width, 700)
        XCTAssertEqual(frame(2), CGRect(x: 700, y: 0, width: 300, height: 500))
        // Resizing can't squeeze it below that either.
        m.userResized(2, to: CGRect(x: 600, y: 0, width: 400, height: 500))
        XCTAssertEqual(frame(1)?.width, 700)
        XCTAssertEqual(frame(2)?.width, 300)
    }

    func testDistributeHonoursMinimums() {
        XCTAssertEqual(LayoutEngine.distribute(900, weights: [1, 1, 1], mins: [0, 0, 0]), [300, 300, 300])
        XCTAssertEqual(LayoutEngine.distribute(900, weights: [1, 1, 1], mins: [500, 0, 0]), [500, 200, 200])
        XCTAssertEqual(LayoutEngine.distribute(900, weights: [1, 2, 1], mins: [0, 0, 300]), [200, 400, 300])
        XCTAssertEqual(LayoutEngine.distribute(900, weights: [1, 1], mins: [600, 600]), [450, 450])
    }

    func testMouseResizeDiffsAgainstRealFrame() {
        add(1, 2)
        _ = m.placements()
        // A terminal snapped itself 7 px narrower and 9 px shorter than its slot. Dragging its right edge
        // 50 px must move the split by 50, and the snapped height must not read as a vertical drag.
        let real = CGRect(x: 0, y: 0, width: 493, height: 491)
        m.userResized(1, from: real, to: CGRect(x: 0, y: 0, width: 543, height: 491))
        XCTAssertEqual(frame(1)?.width, 550)
        XCTAssertEqual(frame(2)?.width, 450)
        XCTAssertEqual(frame(1)?.height, 500)
        // Live drags arrive 1 px at a time; each step must count.
        for x in 0..<10 {
            let w = CGFloat(543 + x)
            m.userResized(1, from: CGRect(x: 0, y: 0, width: w, height: 491), to: CGRect(x: 0, y: 0, width: w + 1, height: 491))
        }
        XCTAssertEqual(frame(1)?.width, 560)
    }

    func testDragDropSwaps() {
        add(1, 2, 3)
        _ = m.placements()
        m.userDropped(1, at: CGPoint(x: 900, y: 100))
        XCTAssertEqual(tree, "H[3 2 1]")
    }

    func testGaps() {
        var c = Config()
        c.gaps.inner = 10
        (c.gaps.top, c.gaps.bottom, c.gaps.left, c.gaps.right) = (5, 5, 5, 5)
        m.setConfig(c)
        add(1, 2)
        XCTAssertEqual(frame(1), CGRect(x: 5, y: 5, width: 490, height: 490))
        XCTAssertEqual(frame(2), CGRect(x: 505, y: 5, width: 490, height: 490))
        c.smartGaps = true
        m.setConfig(c)
        m.removeWindow(2)
        XCTAssertEqual(frame(1), mon1.visibleFrame)
    }

    func testFullscreenAndFloating() {
        add(1, 2)
        run("fullscreen toggle")
        XCTAssertEqual(frame(2), mon1.visibleFrame)
        run("focus left")  // focusing another window drops fullscreen
        XCTAssertNil(ws.fullscreen)
        run("floating toggle")
        XCTAssertEqual(tree, "H[2]")
        XCTAssertTrue(m.windows[1]!.isFloating)
        guard case .floating(let f?, apply: true)? = m.placements()[1] else { return XCTFail("not floating") }
        XCTAssertTrue(mon1.visibleFrame.contains(f))
        run("focus mode_toggle")
        XCTAssertEqual(focused, 2)
        run("focus mode_toggle")
        XCTAssertEqual(focused, 1)
        run("floating disable")
        XCTAssertEqual(tree, "H[2 1]")
    }

    func testFocusParentMovesWholeContainer() {
        add(1, 2)
        run("split v")
        add(3)
        run("focus parent")
        XCTAssertNotNil(ws.selected)
        run("move left")
        XCTAssertEqual(tree, "H[V[2 3] 1]")
        run("focus child")
        XCTAssertNil(ws.selected)
    }

    func testCriteriaCommands() {
        add(1, app: "Safari")
        add(2, app: "Terminal")
        run("[app=\"^Safari$\"] floating enable")
        XCTAssertTrue(m.windows[1]!.isFloating)
        XCTAssertFalse(m.windows[2]!.isFloating)
        let r = m.run("[app=\"Term\"] kill")
        XCTAssertEqual(r.effects, [.close(2)])
    }
}

final class WorkspaceTests: XCTestCase {
    var m: Model!
    override func setUp() { m = Model(config: Config(), monitors: [mon1]) }
    func add(_ ids: WindowID..., app: String = "App") {
        for id in ids { m.addWindow(id, info: WindowInfo(app: app), floating: false, frame: nil) }
    }
    func run(_ s: String, file: StaticString = #filePath, line: UInt = #line) {
        let r = m.run(s)
        XCTAssert(r.ok, "\(s): \(r.errors)", file: file, line: line)
    }

    func testSwitchHideAndGarbageCollect() {
        add(1)
        run("workspace 2")
        XCTAssertEqual(m.focusedWorkspace.name, "2")
        XCTAssertEqual(m.placements()[1], .hidden(1))
        add(2)
        run("workspace 1")
        XCTAssertEqual(m.placements()[2], .hidden(1))
        XCTAssertEqual(m.sortedWorkspaces.map(\.name), ["1", "2"])
        m.removeWindow(2)
        XCTAssertEqual(m.sortedWorkspaces.map(\.name), ["1"])  // empty + hidden → gone
        run("workspace back_and_forth")
        XCTAssertEqual(m.focusedWorkspace.name, "2")
    }

    func testMoveToWorkspaceKeepsFocusHere() {
        add(1, 2)
        run("move container to workspace number 3")
        XCTAssertEqual(m.focusedWorkspace.name, "1")
        XCTAssertEqual(m.focusedWindow?.id, 1)
        XCTAssertEqual(m.workspace(named: "3")?.tiledWindows.map(\.id), [2])
        run("workspace number 3")
        XCTAssertEqual(m.focusedWindow?.id, 2)
    }

    func testNumberMatchesNamedWorkspace() {
        add(1)
        run("move container to workspace \"4: web\"")
        run("workspace number 4")
        XCTAssertEqual(m.focusedWorkspace.name, "4: web")
    }

    func testAutoBackAndForth() {
        var c = Config()
        c.autoBackAndForth = true
        m.setConfig(c)
        add(1)
        run("workspace 2")
        run("workspace 2")
        XCTAssertEqual(m.focusedWorkspace.name, "1")
    }

    func testNextPrev() {
        add(1)
        run("workspace 3; workspace 5")
        add(2)
        run("workspace 3")
        add(3)
        run("workspace next")
        XCTAssertEqual(m.focusedWorkspace.name, "5")
        run("workspace next")
        XCTAssertEqual(m.focusedWorkspace.name, "1")
        run("workspace prev")
        XCTAssertEqual(m.focusedWorkspace.name, "5")
    }

    func testAssignRule() {
        m.setConfig(Config.parse("assign [app=\"^Slack$\"] → number 9"))
        add(1, app: "Slack")
        XCTAssertEqual(m.windows[1]?.workspace?.name, "9")
        XCTAssertEqual(m.focusedWorkspace.name, "1")
    }

    func testScratchpad() {
        add(1, 2)
        run("move scratchpad")
        XCTAssertEqual(m.placements()[2], .hidden(1))
        XCTAssertEqual(m.focusedWindow?.id, 1)
        run("scratchpad show")
        XCTAssertEqual(m.focusedWindow?.id, 2)
        XCTAssertTrue(m.windows[2]!.isFloating)
        guard case .floating(_?, apply: true)? = m.placements()[2] else { return XCTFail() }
        run("scratchpad show")
        XCTAssertEqual(m.placements()[2], .hidden(1))
        // Shows up on whichever workspace is current.
        run("workspace 7; scratchpad show")
        XCTAssertEqual(m.windows[2]?.workspace?.name, "7")
    }

    func testCriteriaFocusJumpsWorkspaces() {
        add(1, app: "Safari")
        run("workspace 2")
        add(2, app: "Mail")
        run("[app=\"Safari\"] focus")
        XCTAssertEqual(m.focusedWorkspace.name, "1")
        XCTAssertEqual(m.focusedWindow?.id, 1)
    }

    func testSessionRoundTrip() {
        add(1, 2)
        run("move container to workspace number 4")
        run("[app=\"App\"] nop")
        let snap = m.sessionSnapshot()
        XCTAssertEqual(snap.map(\.workspace), ["1", "4"])
        let fresh = Model(config: Config(), monitors: [mon1])
        for s in snap {
            fresh.addWindow(s.id, info: WindowInfo(app: "App"), floating: s.floating, frame: nil, workspaceName: s.workspace)
        }
        XCTAssertEqual(fresh.windows[2]?.workspace?.name, "4")
        XCTAssertEqual(fresh.placements()[2], .hidden(1))
        fresh.restoreFocus(workspace: "4")
        XCTAssertEqual(fresh.focusedWorkspace.name, "4")
    }

    func testOSFocusFollowsToHiddenWorkspace() {
        add(1)
        run("workspace 2")
        m.osFocused(1)
        XCTAssertEqual(m.focusedWorkspace.name, "1")
    }
}

final class MultiMonitorTests: XCTestCase {
    var m: Model!
    override func setUp() { m = Model(config: Config(), monitors: [mon1, mon2]) }
    func add(_ id: WindowID, at x: CGFloat) {
        m.addWindow(id, info: WindowInfo(app: "A"), floating: false,
                    frame: CGRect(x: x, y: 10, width: 100, height: 100), useMonitorOfFrame: true)
    }

    func testStartupPlacementAndCrossMonitorFocus() {
        XCTAssertEqual(m.visible[1]?.name, "1")
        XCTAssertEqual(m.visible[2]?.name, "2")
        add(1, at: 10)
        add(2, at: 1500)
        XCTAssertEqual(m.windows[2]?.workspace?.name, "2")
        m.osFocused(1)
        m.run("focus right")
        XCTAssertEqual(m.focusedWindow?.id, 2)
        XCTAssertEqual(m.focusedWorkspace.name, "2")
        m.run("focus left")
        XCTAssertEqual(m.focusedWindow?.id, 1)
    }

    func testDisplayFallsBackToItsLastWorkspace() {
        add(1, at: 10)       // ws 1 on main
        m.osFocused(1)
        m.run("workspace number 5")
        m.addWindow(5, info: WindowInfo(app: "B"), floating: false, frame: nil)
        m.run("workspace number 3")
        m.addWindow(3, info: WindowInfo(app: "C"), floating: false, frame: nil)
        m.run("workspace number 5")       // last shown before 3... now 5 is shown, 3 most recent hidden
        m.run("move workspace to output right")
        XCTAssertEqual(m.visible[1]?.name, "3")  // the one shown last, not the first created (1)
    }

    func testWorkspacesGoHomeWhenDisplayReturns() {
        add(1, at: 10)
        add(2, at: 1500)  // on ws 2, the external display
        m.osFocused(1)
        m.setMonitors([mon1])  // unplugged: ws 2 moves to the laptop
        XCTAssertEqual(m.workspace(named: "2")?.monitorID, 1)
        m.setMonitors([mon1, mon2])  // plugged back in
        XCTAssertEqual(m.workspace(named: "2")?.monitorID, 2)
        XCTAssertEqual(m.visible[2]?.name, "2")
        XCTAssertEqual(m.visible[1]?.name, "1")
        XCTAssertEqual(m.focusedWorkspace.name, "1")
    }

    func testFloatingWindowLeavingFullscreenGetsItsFrameBack() {
        m.addWindow(5, info: WindowInfo(app: "A"), floating: true, frame: CGRect(x: 100, y: 100, width: 300, height: 200))
        m.osFocused(5)
        m.clearDirty(5)
        m.run("fullscreen toggle")
        m.run("fullscreen toggle")
        XCTAssertEqual(m.windows[5]?.floatingFrameDirty, true)
    }

    func testMoveAcrossMonitorEdge() {
        add(1, at: 10)
        add(2, at: 1500)
        m.osFocused(1)
        m.run("move right")
        XCTAssertEqual(m.windows[1]?.workspace?.name, "2")
        XCTAssertEqual(describe(m.workspace(named: "2")!.root), "H[1 2]")
        XCTAssertEqual(m.focusedWindow?.id, 1)
        XCTAssertEqual(m.focusedWorkspace.name, "2")
    }

    func testWorkspaceOnOtherMonitorFocusesThatMonitor() {
        add(1, at: 10)
        m.run("workspace 2")
        XCTAssertEqual(m.focusedMonitor.id, 2)
        XCTAssertEqual(m.visible[1]?.name, "1")
    }

    func testMoveWorkspaceToOutputAndUnplug() {
        add(1, at: 10)
        m.run("move workspace to output right")
        XCTAssertEqual(m.visible[2]?.name, "1")
        XCTAssertEqual(m.visible[1]?.name, "3")
        m.setMonitors([mon1])
        XCTAssertEqual(m.windows[1]?.workspace?.monitorID, 1)
        XCTAssertNotNil(m.visible[1])
    }

    func testFloatingDropOnOtherMonitor() {
        m.addWindow(1, info: WindowInfo(app: "A"), floating: true, frame: CGRect(x: 100, y: 100, width: 200, height: 200),
                    useMonitorOfFrame: true)
        m.floatingWindowDropped(1, frame: CGRect(x: 120, y: 90, width: 200, height: 200))
        XCTAssertEqual(m.windows[1]?.workspace?.name, "1")
        XCTAssertEqual(m.windows[1]?.floatingFrame, CGRect(x: 120, y: 90, width: 200, height: 200))
        m.floatingWindowDropped(1, frame: CGRect(x: 1400, y: 100, width: 200, height: 200))
        XCTAssertEqual(m.windows[1]?.workspace?.name, "2")
        XCTAssertEqual(m.focusedWorkspace.name, "2")
        XCTAssertEqual(m.placements()[1], .floating(CGRect(x: 1400, y: 100, width: 200, height: 200), apply: false))
    }

    func testWorkspaceOutputAssignment() {
        let c = Config.parse("workspace 9 output secondary")
        m = Model(config: c, monitors: [mon1, mon2])
        XCTAssertEqual(m.visible[2]?.name, "9")
        m.run("workspace 9")
        XCTAssertEqual(m.focusedMonitor.id, 2)
    }
}

final class ParserTests: XCTestCase {
    func testDefaultConfigParsesCleanly() {
        let c = Config.parse(DefaultConfig.text)
        XCTAssertEqual(c.warnings, [])
        XCTAssertEqual(c.gaps.inner, 8)
        XCTAssertEqual(c.modes.keys.sorted(), ["default", "resize"])
        XCTAssertEqual(c.modes["default"]?[KeyCombo(keyCode: 0x04, modifiers: [.control, .option])], "focus left")
        XCTAssertEqual(c.modes["default"]?[KeyCombo(keyCode: 0x12, modifiers: [.control, .option, .shift])],
                       "move container to workspace number 1")
        XCTAssertEqual(c.modes["resize"]?[KeyCombo(keyCode: 0x35, modifiers: [])], "mode \"default\"")
        XCTAssertEqual(c.rules.count, 2)
        XCTAssertEqual(c.floatingModifier, [.control, .option])
        XCTAssertEqual(c.workspaceIndicator, "number")
    }

    func testI3ConfigCompat() {
        let c = Config.parse("""
        set $mod Mod4
        set $left h
        font pango:monospace 8
        bindsym $mod+$left focus left
        bindsym $mod+Shift+Return exec --no-startup-id alacritty
        bar {
            status_command i3status
            colors { background #000000 }
        }
        client.focused #4c7899 #285577 #ffffff #2e9ef4 #285577
        for_window [class="Pavucontrol"] floating enable
        exec_always --no-startup-id ~/bin/startup.sh
        workspace_layout tabbed
        """)
        XCTAssertEqual(c.warnings, [])
        XCTAssertEqual(c.modes["default"]?[KeyCombo(keyCode: 0x04, modifiers: .command)], "focus left")
        XCTAssertEqual(c.execAlways, ["~/bin/startup.sh"])
        XCTAssertEqual(c.workspaceLayout, .tabbed)
        XCTAssertEqual(c.rules.first?.command, "floating enable")
        XCTAssertEqual(c.borderColor, "#285577")
    }

    func testBorders() {
        let c = Config.parse("default_border pixel 4\nborder_radius 0\nclient.focused #111111 #222222 #ffffff #333333")
        XCTAssertEqual(c.warnings, [])
        XCTAssertEqual(c.borderWidth, 4)
        XCTAssertEqual(c.borderRadius, 0)
        XCTAssertEqual(c.borderColor, "#111111")
        XCTAssertEqual(Config.parse("default_border none").borderWidth, 0)
    }

    func testTrailingComments() {
        let c = Config.parse("""
        set $mod ctrl+alt   # comment after a variable
        bindsym $mod+h focus left # and after a binding
        bindsym $mod+e exec echo "# not a comment"
        client.focused #111111 #222222 #ffffff #333333 #444444
        """)
        XCTAssertEqual(c.warnings, [])
        XCTAssertEqual(c.modes["default"]?[KeyCombo(keyCode: 0x04, modifiers: [.control, .option])], "focus left")
        XCTAssertEqual(c.modes["default"]?[KeyCombo(keyCode: 0x0E, modifiers: [.control, .option])], "exec echo \"# not a comment\"")
        XCTAssertEqual(c.borderColor, "#444444")
    }

    func testConfigWarnings() {
        let c = Config.parse("bindsym alt+nope focus left\nbindsym alt+h frobnicate\nwat 1")
        XCTAssertEqual(c.warnings.count, 3)
    }

    func testCommandChainsAndCriteria() throws {
        let p = try CommandParser.parse("[app=\"x\"] floating enable, move position center; workspace 2")
        XCTAssertEqual(p.map(\.command), [.floating(.enable), .movePositionCenter,
                                          .workspace(.name("2"), noAutoBackAndForth: false)])
        XCTAssertEqual(p.map(\.criteria), ["app=\"x\"", "app=\"x\"", nil])
    }

    func testExecKeepsQuotes() throws {
        let p = try CommandParser.parse("exec osascript -e 'tell app \"Terminal\" to activate'")
        XCTAssertEqual(p[0].command, .exec("osascript -e 'tell app \"Terminal\" to activate'"))
        XCTAssertEqual(try CommandParser.parse("exec \"open -a Safari\"")[0].command, .exec("open -a Safari"))
    }

    func testVariousCommands() throws {
        func c(_ s: String) throws -> Command { try CommandParser.parse(s)[0].command }
        XCTAssertEqual(try c("move container to workspace number 3"), .moveToWorkspace(.number("3")))
        XCTAssertEqual(try c("move workspace to output left"), .moveWorkspaceToOutput(.direction(.left)))
        XCTAssertEqual(try c("move left 20 px"), .move(.left, px: 20))
        XCTAssertEqual(try c("resize grow width 10 px or 5 ppt"),
                       .resize(ResizeArg(grow: true, dimension: .width, px: 10, ppt: 5)))
        XCTAssertEqual(try c("layout toggle tabbed split"), .layout(.cycle([.tabbed, nil])))
        XCTAssertEqual(try c("mode \"resize\""), .mode("resize"))
        XCTAssertEqual(try c("fullscreen"), .fullscreen(.toggle))
        XCTAssertEqual(try c("immersive"), .immersive(.toggle))
        XCTAssertEqual(Config.parse("immersive yes").immersive, true)
        XCTAssertNil(Config().immersive)
        XCTAssertTrue(Config().interceptNativeFullscreen)
        XCTAssertTrue(Config().smoothLayout)
        XCTAssertFalse(Config.parse("smooth_layout no").smoothLayout)
        XCTAssertFalse(Config.parse("native_fullscreen macos").interceptNativeFullscreen)
        XCTAssertThrowsError(try c("frobnicate"))
    }

    func testCapsLockModifier() {
        let c = Config.parse("set $mod caps\nbindsym $mod+Shift+h move left\nfloating_modifier $mod")
        XCTAssertEqual(c.warnings, [])
        XCTAssertEqual(c.modes["default"]?[KeyCombo(keyCode: 0x04, modifiers: [.caps, .shift])], "move left")
        XCTAssertTrue(c.usesCapsLock)
        XCTAssertFalse(Config.parse("bindsym alt+h focus left").usesCapsLock)
    }

    func testEditSettings() {
        let text = """
        # header
        set $mod alt     # the key
        focus_follows_mouse no
        mode "resize" {
            focus_follows_mouse yes
        }
        """
        XCTAssertEqual(Config.value(of: "set $mod", in: text), "alt")
        XCTAssertEqual(Config.value(of: "focus_follows_mouse", in: text), "no")
        XCTAssertNil(Config.value(of: "workspace_indicator", in: text))

        let mod = Config.setting("set $mod", to: "ctrl+alt", in: text)
        XCTAssertTrue(mod.contains("\nset $mod ctrl+alt # the key\n"))
        XCTAssertEqual(Config.value(of: "set $mod", in: mod), "ctrl+alt")

        let ffm = Config.setting("focus_follows_mouse", to: "yes", in: text)
        XCTAssertTrue(ffm.contains("\nfocus_follows_mouse yes\nmode"))
        XCTAssertTrue(ffm.contains("    focus_follows_mouse yes\n"))  // inside the mode block: untouched

        let added = Config.setting("workspace_indicator", to: "dots", in: text)
        XCTAssertTrue(added.hasPrefix("# header\nworkspace_indicator dots\nset $mod alt"))
        XCTAssertEqual(Config.parse(added).workspaceIndicator, "dots")
    }

    func testKeyCombos() {
        XCTAssertEqual(KeyCombo.parse("hyper+Return"), KeyCombo(keyCode: 0x24, modifiers: [.shift, .control, .option, .command]))
        XCTAssertEqual(KeyCombo.parse("ctrl+F12")?.keyCode, 0x6F)
        XCTAssertEqual(KeyCombo.parse("cmd+50", isCode: true)?.keyCode, 50)
        XCTAssertNil(KeyCombo.parse("alt+nope"))
    }
}

final class MotionTests: XCTestCase {
    func testEaseAndLerp() {
        XCTAssertEqual(Motion.ease(0), 0)
        XCTAssertEqual(Motion.ease(1), 1)
        XCTAssertGreaterThan(Motion.ease(0.5), 0.9)  // ease-out: most of the way by halfway
        XCTAssertEqual(Motion.lerp(CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 100, y: 50, width: 200, height: 100), 0.5),
                       CGRect(x: 50, y: 25, width: 150, height: 100))
    }

    func testSlideDirection() {
        let solo = mon1
        XCTAssertEqual(Motion.slide(on: solo, among: [solo], forward: true),
                       Motion.Slide(enter: CGVector(dx: 1000, dy: 0), exit: CGVector(dx: -1000, dy: 0)))
        // A display to the right: sliding sideways would cross it, so windows rise from below instead.
        XCTAssertEqual(Motion.slide(on: mon1, among: [mon1, mon2], forward: false),
                       Motion.Slide(enter: CGVector(dx: 0, dy: 500), exit: CGVector(dx: 0, dy: 500)))
        XCTAssertTrue(Motion.isForward(from: "2", to: "10", order: []))
        XCTAssertFalse(Motion.isForward(from: "web", to: "chat", order: ["chat", "web"]))
    }

    func testAnimationConfig() {
        let c = Config.parse("animations no\nanimation_duration 250")
        XCTAssertFalse(c.animations)
        XCTAssertEqual(c.animationDuration, 0.25, accuracy: 1e-9)
    }
}

final class IndicatorConfigTests: XCTestCase {
    func testIndicatorLooks() {
        for look in ["number", "pill", "panes", "circle", "minimal", "segmented", "dots", "tiles"] {
            let c = Config.parse("workspace_indicator \(look)")
            XCTAssertEqual(c.workspaceIndicator, look)
            XCTAssertTrue(c.warnings.isEmpty, look)
        }
        let bad = Config.parse("workspace_indicator ring")
        XCTAssertEqual(bad.workspaceIndicator, "number")
        XCTAssertEqual(bad.warnings.count, 1)
    }
}
