import CoreGraphics
import XCTest
@testable import PanespaceCore

/// Throws long random runs of commands, window opens/closes, focus changes and monitor plugs at the model,
/// checking after every step that it is still a consistent state. Seeded, so a failure replays exactly.
final class FuzzTests: XCTestCase {
    private let main = Monitor(id: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                               visibleFrame: CGRect(x: 0, y: 33, width: 1512, height: 949), isMain: true)
    private let ext = Monitor(id: 2, name: "DELL U2720Q", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                              visibleFrame: CGRect(x: 1512, y: 25, width: 2560, height: 1415), isMain: false)
    private let portrait = Monitor(id: 3, name: "LG Portrait", frame: CGRect(x: -1080, y: 0, width: 1080, height: 1920),
                                   visibleFrame: CGRect(x: -1080, y: 0, width: 1080, height: 1920), isMain: false)

    private static let commands = [
        "focus left", "focus right", "focus up", "focus down", "focus parent", "focus child", "focus mode_toggle",
        "focus output next", "focus output left", "focus output right",
        "move left", "move right", "move up", "move down", "move container to output next",
        "move workspace to output next", "move workspace to output prev",
        "split h", "split v", "split toggle", "layout tabbed", "layout stacking", "layout splith", "layout splitv",
        "layout toggle split", "layout toggle tabbed split", "layout toggle all",
        "fullscreen toggle", "floating toggle", "floating enable", "floating disable",
        "resize grow width 50 px or 5 ppt", "resize shrink height 50 px or 5 ppt", "balance",
        "workspace number 1", "workspace number 2", "workspace number 3", "workspace number 7",
        "workspace next", "workspace prev", "workspace next_on_output", "workspace back_and_forth",
        "workspace number 2 output next", "workspace number 5 output next", "workspace number 1 output prev",
        "move container to workspace number 1", "move container to workspace number 3",
        "move container to workspace number 9", "move scratchpad", "scratchpad show", "kill",
        "mode default", "focus left; move right; split v", "workspace 4; layout tabbed",
    ]

    func testRandomRunsStayConsistent() {
        for seed in UInt64(1)...25 { run(seed: seed, steps: 600) }
    }

    private func run(seed: UInt64, steps: Int) {
        var rng = SplitMix(seed)
        let m = Model(config: Config(), monitors: [main, ext])
        var nextID: WindowID = 1
        var log: [String] = []
        for step in 0..<steps {
            let ids = Array(m.windows.keys).sorted()
            let roll = rng.next() % 100
            var what = ""
            switch roll {
            case 0..<22:  // a window opens somewhere
                let floating = rng.next() % 5 == 0
                let mon = m.monitors[Int(rng.next() % UInt64(m.monitors.count))]
                let f = CGRect(x: mon.frame.minX + 40, y: 80, width: 600, height: 400)
                m.addWindow(nextID, info: WindowInfo(app: "App\(nextID % 4)"), floating: floating, frame: f,
                            useMonitorOfFrame: rng.next() % 2 == 0)
                what = "open \(nextID)\(floating ? " floating" : "")"
                nextID += 1
            case 22..<34:  // one closes
                guard let id = ids.randomElement(using: &rng) else { continue }
                m.removeWindow(id)
                what = "close \(id)"
            case 34..<44:  // the user clicks or Cmd-Tabs to one
                guard let id = ids.randomElement(using: &rng) else { continue }
                m.osFocused(id)
                what = "os focus \(id)"
            case 44..<47:  // a native tab takes over
                guard let id = ids.randomElement(using: &rng) else { continue }
                m.replaceWindow(id, with: nextID, info: WindowInfo(app: "Tabbed"))
                what = "tab \(id) → \(nextID)"
                nextID += 1
            case 47..<49:  // a floating window is dragged somewhere
                guard let id = ids.randomElement(using: &rng), m.windows[id]?.isFloating == true else { continue }
                let mon = m.monitors.randomElement(using: &rng)!
                m.floatingWindowDropped(id, frame: CGRect(x: mon.frame.midX, y: mon.frame.midY, width: 300, height: 200))
                what = "drop \(id) on \(mon.id)"
            case 49..<52:  // displays plugged, unplugged, rearranged
                let sets = [[main], [main, ext], [main, ext, portrait], [ext], [main, portrait]]
                let s = sets.randomElement(using: &rng)!
                m.setMonitors(s)
                what = "monitors \(s.map(\.id))"
            default:
                let c = Self.commands.randomElement(using: &rng)!
                _ = m.run(c)
                what = c
            }
            log.append(what)
            if let problem = check(m) {
                XCTFail("seed \(seed), step \(step) after '\(what)': \(problem)\nlast steps: \(log.suffix(12))")
                return
            }
        }
    }

    /// nil when the model is consistent, else what's wrong.
    private func check(_ m: Model) -> String? {
        let names = m.workspaces.map(\.name)
        if Set(names).count != names.count { return "duplicate workspace names \(names)" }
        for mon in m.monitors {
            guard let ws = m.visible[mon.id] else { return "monitor \(mon.id) shows nothing" }
            if ws.monitorID != mon.id { return "workspace \(ws.name) shown on \(mon.id) but belongs to \(ws.monitorID)" }
            if !m.workspaces.contains(where: { $0 === ws }) { return "visible workspace \(ws.name) not in the list" }
        }
        if !m.isVisible(m.focusedWorkspace) { return "focused workspace \(m.focusedWorkspace.name) isn't shown" }
        if !m.workspaces.contains(where: { $0 === m.focusedWorkspace }) { return "focused workspace not in the list" }
        let monitorIDs = Set(m.monitors.map(\.id))

        var placed = Set<WindowID>()
        for ws in m.workspaces {
            if !monitorIDs.contains(ws.monitorID) { return "workspace \(ws.name) on a monitor that's gone" }
            if let p = checkTree(ws.root, isRoot: true) { return "workspace \(ws.name): \(p)" }
            for w in ws.allWindows {
                if !placed.insert(w.id).inserted { return "window \(w.id) is in two places" }
                if m.windows[w.id] !== w { return "window \(w.id) in \(ws.name) isn't the model's window \(w.id)" }
                if w.workspace !== ws { return "window \(w.id) thinks it's in \(w.workspace?.name ?? "nil"), is in \(ws.name)" }
            }
            for w in ws.floating where !w.isFloating { return "tiled window \(w.id) in the floating list" }
            for w in ws.tiledWindows where w.isFloating { return "floating window \(w.id) in the tree" }
            for w in ws.mru where !ws.allWindows.contains(where: { $0 === w }) { return "mru of \(ws.name) has stranger \(w.id)" }
            if let fs = ws.fullscreen, !ws.allWindows.contains(where: { $0 === fs }) { return "fullscreen \(fs.id) not in \(ws.name)" }
        }
        for w in m.scratchpad {
            if !placed.insert(w.id).inserted && w.workspace == nil { return "scratchpad window \(w.id) twice" }
        }
        for (id, w) in m.windows {
            if w.id != id { return "window keyed \(id) has id \(w.id)" }
            if !placed.contains(id) { return "window \(id) is nowhere" }
        }
        let placements = m.placements()
        for (id, p) in placements {
            guard m.windows[id] != nil else { return "placement for unknown window \(id)" }
            if case .tiled(let r) = p {
                if !(r.minX.isFinite && r.minY.isFinite && r.width.isFinite && r.height.isFinite) { return "window \(id) at \(r)" }
                if r.width < 0 || r.height < 0 { return "window \(id) has negative size \(r)" }
            }
        }
        return nil
    }

    private func checkTree(_ c: Container, isRoot: Bool) -> String? {
        if !isRoot && c.children.isEmpty && !c.pendingSplit { return "empty container left behind" }
        for child in c.children {
            if child.parent !== c { return "child's parent link is wrong" }
            if !(child.weight.isFinite && child.weight > 0) { return "weight \(child.weight)" }
            if let sub = child as? Container, let p = checkTree(sub, isRoot: false) { return p }
        }
        return nil
    }
}

/// Small deterministic RNG, so a failing seed replays the same run.
struct SplitMix: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class SwitcherTests: XCTestCase {
    private func e(_ id: WindowID, _ app: String, _ title: String, ws: String = "1") -> SwitcherEntry {
        SwitcherEntry(id: id, app: app, bundleID: "", pid: 0, title: title, workspace: ws, isFloating: false)
    }

    func testFuzzyPrefersAppNamesAndWordStarts() {
        let all = [e(1, "Zen", "Issues · AeroSpace"), e(2, "Ghostty", "~/zspace"), e(3, "WhatsApp", "WhatsApp"),
                   e(4, "Google Chrome", "Gmail - Inbox", ws: "3")]
        XCTAssertEqual(Fuzzy.filter("gho", all).first?.id, 2)
        XCTAssertEqual(Fuzzy.filter("chr", all).first?.id, 4)
        XCTAssertEqual(Fuzzy.filter("aero", all).first?.id, 1)
        XCTAssertEqual(Fuzzy.filter("gmail", all).first?.id, 4)
        XCTAssertEqual(Fuzzy.filter("wa", all).first?.id, 3)
        XCTAssertTrue(Fuzzy.filter("xyzzy", all).isEmpty)
        XCTAssertEqual(Fuzzy.filter("", all).map(\.id), [1, 2, 3, 4])  // empty query keeps recency order
    }

    func testEntriesPutFocusedWindowLast() {
        let mon = Monitor(id: 1, name: "M", frame: CGRect(x: 0, y: 0, width: 1000, height: 500),
                          visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 500), isMain: true)
        let m = Model(config: Config(), monitors: [mon])
        for id: WindowID in 1...3 { m.addWindow(id, info: WindowInfo(app: "A\(id)"), floating: false, frame: nil) }
        _ = m.run("move container to workspace number 2")  // 3 → ws 2
        let ids = m.switcherEntries().map(\.id)
        XCTAssertEqual(Set(ids), [1, 2, 3])
        XCTAssertEqual(ids.last, m.focusedWindow?.id)
        XCTAssertEqual(ids.first(where: { $0 != m.focusedWindow?.id }).map { m.windows[$0]?.workspace?.name }, "1")
    }
}
