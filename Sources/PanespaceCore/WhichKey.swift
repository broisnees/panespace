import Foundation

/// The which-key panel's rows: every key of a mode, with a short label made from its command.
public enum WhichKey {
    public struct Entry: Equatable {
        /// What to press, as printed on the keycap ("⇧W", "␣", "esc").
        public let key: String
        public let label: String
    }

    public struct Group: Equatable {
        public let title: String
        public let entries: [Entry]
    }

    /// The mode's keys sorted into columns by what they do. Four keys doing one thing in four directions
    /// (focus ←↑↓→) share a row; digits doing the same thing with their own number become "1–5".
    public static func groups(_ bindings: [KeyCombo: String]) -> [Group] {
        let order = ["Move", "Window", "Layout", "Workspaces", "Tools"]
        var buckets: [String: [(rank: (Int, String, Int), entry: Entry)]] = [:]
        func rank(_ c: KeyCombo) -> (Int, String, Int) {
            let name = Keys.name(for: c.keyCode) ?? ""
            let g = c.keyCode == 0x35 ? 3 : (name.count == 1 && name.first!.isLetter ? 0 : (name.count == 1 ? 1 : 2))
            return (g, name, Int(c.modifiers.rawValue))
        }
        var parsed: [(KeyCombo, String, Command?)] = bindings.map { combo, text in
            let cmd = (try? CommandParser.parse(text))?.first { $0.command != .mode("default") }?.command
                ?? (try? CommandParser.parse(text))?.first?.command
            return (combo, text, cmd)
        }
        // focus/move/resize in all four directions with the same modifiers: one row.
        for (kind, makeLabel) in [("focus", "Focus"), ("move", "Move"), ("resize", "Resize")] {
            let byMods = Dictionary(grouping: parsed.filter { _, text, cmd in
                guard let cmd else { return false }
                switch (kind, cmd) {
                case ("focus", .focus), ("move", .move(_, nil)): return true
                case ("resize", .resize(let r)): if case .border = r.dimension { return true } else { return false }
                default: return false
                }
            }, by: { $0.0.modifiers.rawValue })
            for (_, rows) in byMods {
                var dirKey: [Direction: KeyCombo] = [:]
                for (combo, _, cmd) in rows {
                    let d: Direction?
                    switch cmd {
                    case .focus(let x)?: d = x
                    case .move(let x, _)?: d = x
                    case .resize(let r)?: if case .border(let x) = r.dimension { d = x } else { d = nil }
                    default: d = nil
                    }
                    // Letters before arrows: hjkl/wasd read better than the arrow keys that do the same.
                    if let d, dirKey[d] == nil || (Keys.name(for: dirKey[d]!.keyCode)?.count ?? 9) > (Keys.name(for: combo.keyCode)?.count ?? 9) {
                        dirKey[d] = combo
                    }
                }
                guard dirKey.count == 4 else { continue }
                // In keyboard order, so the row reads like the keys under your fingers (W A S D, H J K L).
                let row = "`1234567890-=qwertyuiop[]asdfghjkl;'zxcvbnm,./"
                func pos(_ c: KeyCombo) -> Int {
                    let n = Keys.name(for: c.keyCode) ?? ""
                    if n.count == 1, let i = row.firstIndex(of: Character(n)) { return row.distance(from: row.startIndex, to: i) }
                    return 100 + (["left", "down", "up", "right"].firstIndex(of: n) ?? 100)
                }
                let dirs = [Direction.up, .left, .down, .right].sorted { pos(dirKey[$0]!) < pos(dirKey[$1]!) }
                let keys = dirs.map { dirKey[$0]! }
                let caps = keys.map(keycap)
                let prefix = caps[0].hasPrefix("⇧") ? "⇧ " : ""
                let joined = prefix + caps.map { $0.replacingOccurrences(of: "⇧", with: "") }.joined(separator: " ")
                let used = Set(rows.map(\.0))
                parsed.removeAll { used.contains($0.0) }
                let group = kind == "resize" ? "Layout" : "Move"
                buckets[group, default: []].append(((-1, kind, Int(keys[0].modifiers.rawValue)), Entry(key: joined, label: makeLabel + " " + dirs.map(arrow).joined())))
            }
        }
        var digits: [Int: (String, String)] = [:]  // number → (generic label, group)
        for (combo, text, cmd) in parsed {
            let l = label(text)
            let g = group(cmd)
            let name = Keys.name(for: combo.keyCode) ?? ""
            if combo.modifiers.isEmpty, let n = Int(name), name.count == 1 {
                digits[n] = (l.replacingOccurrences(of: " \(n)", with: ""), g)
                continue
            }
            // Several keys that leave the mode: only esc is worth a row.
            if cmd == .mode("default"), combo.keyCode != 0x35, bindings.keys.contains(where: { $0.keyCode == 0x35 }) { continue }
            buckets[g, default: []].append((rank(combo), Entry(key: keycap(combo), label: l)))
        }
        // Runs of digits with one label: a single "1–5" row.
        var run: [Int] = []
        func flush() {
            guard let first = run.first, let (l, g) = digits[first] else { return }
            if run.count >= 3 {
                buckets[g, default: []].append(((1, "\(first)", 0), Entry(key: "\(first)–\(run.last!)", label: l)))
            } else {
                for n in run { buckets[digits[n]!.1, default: []].append(((1, "\(n)", 0), Entry(key: "\(n)", label: label(bindings.first { Keys.name(for: $0.key.keyCode) == "\(n)" && $0.key.modifiers.isEmpty }!.value)))) }
            }
            run = []
        }
        for n in digits.keys.sorted() {
            if let last = run.last, last + 1 != n || digits[last]!.0 != digits[n]!.0 { flush() }
            run.append(n)
        }
        flush()
        return order.compactMap { title in
            guard let rows = buckets[title], !rows.isEmpty else { return nil }
            return Group(title: title, entries: rows.sorted { $0.rank < $1.rank }.map(\.entry))
        }
    }

    /// Which column a command goes in.
    static func group(_ cmd: Command?) -> String {
        switch cmd {
        case .focus?, .focusTarget?, .focusParent?, .focusChild?, .focusModeToggle?, .focusFloating?, .focusTiling?, .move?:
            return "Move"
        case .kill?, .floating?, .pseudo?, .pin?, .fullscreen?, .zoom?, .movePositionCenter?:
            return "Window"
        case .split?, .layout?, .balance?, .resize?, .mode("resize")?:
            return "Layout"
        case .workspace?, .workspaceOnOutput?, .moveToWorkspace?, .moveToOutput?, .moveWorkspaceToOutput?,
             .swapWorkspaceWithOutput?, .focusOutput?, .scratchpadShow?, .moveToScratchpad?:
            return "Workspaces"
        default:
            return "Tools"
        }
    }

    /// "shift+w" → "⇧W", "space" → "␣".
    public static func keycap(_ c: KeyCombo) -> String {
        var s = ""
        if c.modifiers.contains(.fn) { s += "fn " }
        if c.modifiers.contains(.control) { s += "⌃" }
        if c.modifiers.contains(.option) { s += "⌥" }
        if c.modifiers.contains(.command) { s += "⌘" }
        if c.modifiers.contains(.shift) { s += "⇧" }
        let name = c.keyCode == 0x35 ? "escape" : Keys.name(for: c.keyCode) ?? "?"
        let symbols = [
            "space": "space", "tab": "tab", "escape": "esc", "return": "↩", "backspace": "⌫", "left": "←", "right": "→",
            "up": "↑", "down": "↓", "minus": "-", "equal": "=", "grave": "`", "semicolon": ";", "comma": ",",
            "period": ".", "slash": "/", "bracketleft": "[", "bracketright": "]", "apostrophe": "'", "backslash": "\\",
        ]
        return s + (symbols[name] ?? (name.count == 1 ? name.uppercased() : name))
    }

    private static func arrow(_ d: Direction) -> String {
        switch d {
        case .left: return "←"
        case .right: return "→"
        case .up: return "↑"
        case .down: return "↓"
        }
    }

    private static func ws(_ t: WorkspaceTarget) -> String {
        switch t {
        case .name(let n), .number(let n): return n
        case .next, .nextOnOutput: return "next"
        case .prev, .prevOnOutput: return "previous"
        case .backAndForth: return "last"
        }
    }

    /// A few words for a binding's command: "focus left" → "Focus ←".
    public static func label(_ command: String) -> String {
        guard let parsed = try? CommandParser.parse(command) else { return command }
        // "move container to workspace 3; workspace 3" says the first part; "mode default; x" says x.
        let cmd = parsed.first { $0.command != .mode("default") }?.command ?? parsed[0].command
        switch cmd {
        case .exec(let s):
            let app = s.range(of: #"-a\s+"?([^"]+?)"?(\s|$)"#, options: .regularExpression).map { String(s[$0]) }
            return "Open " + (app.map { $0.replacingOccurrences(of: "-a", with: "").replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespaces) } ?? (s.split(separator: " ").first.map(String.init) ?? s))
        case .focus(let d): return "Focus \(arrow(d))"
        case .focusTarget: return "Focus"
        case .focusParent: return "Focus parent"
        case .focusChild: return "Focus child"
        case .focusModeToggle: return "Tiles ↔ floating"
        case .focusFloating: return "Focus floating"
        case .focusTiling: return "Focus tiles"
        case .focusOutput: return "Other display"
        case .move(let d, _): return "Move \(arrow(d))"
        case .moveToWorkspace(let t): return "Send to \(ws(t))"
        case .moveToOutput: return "Send to display"
        case .moveWorkspaceToOutput: return "Workspace → display"
        case .swapWorkspaceWithOutput: return "Swap displays"
        case .moveToScratchpad: return "Stash"
        case .movePositionCenter: return "Center"
        case .scratchpadShow: return "Scratchpad"
        case .workspace(let t, _):
            if case .backAndForth = t { return "Last workspace" }
            return "Workspace \(ws(t))"
        case .workspaceOnOutput(let t, _): return "Workspace \(ws(t)) on other display"
        case .split: return "Split"
        case .layout(let a):
            switch a {
            case .set(let l): return l == .tabbed ? "Tabbed" : l == .stacking ? "Stacked" : "Split"
            case .toggleSplit: return "Flip split"
            case .toggleAll, .cycle: return "Tabbed ↔ split"
            case .defaultSplit: return "Split"
            }
        case .fullscreen: return "Fullscreen"
        case .zoom: return "Zoom"
        case .floating: return "Float"
        case .pseudo: return "Pseudotile"
        case .pin: return "Pin"
        case .resize(let r):
            switch r.dimension {
            case .border(let d): return "Resize \(arrow(d))"
            case .width: return r.grow ? "Wider" : "Narrower"
            case .height: return r.grow ? "Taller" : "Shorter"
            case .edge(let d): return (r.grow ? "Grow " : "Shrink ") + arrow(d)
            }
        case .balance: return "Balance"
        case .immersive: return "Immersive"
        case .switcher: return "Switcher"
        case .hints(let swap): return swap ? "Swap with…" : "Jump to…"
        case .kill: return "Close"
        case .reload: return "Reload"
        case .exit: return "Quit"
        case .mode(let m): return m == "default" ? "Cancel" : m.prefix(1).uppercased() + m.dropFirst() + "…"
        case .nop: return "Nothing"
        }
    }
}
