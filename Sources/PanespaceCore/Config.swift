import CoreGraphics
import Foundation

public enum DefaultOrientation: Equatable { case auto, horizontal, vertical }

public struct Rule {
    public var criteria: Criteria
    public var command: String
}

public struct Assignment {
    public var criteria: Criteria
    public var workspace: WorkspaceTarget
}

/// i3-compatible config. Unknown i3 directives (bar, font, client.*, …) are ignored so
/// an existing i3 config mostly just works.
public struct Config {
    public var modes: [String: [KeyCombo: String]] = ["default": [:]]
    /// Modes declared `mode --oneshot "name" {`: one key, then back to default. A key the mode doesn't bind
    /// just leaves it (and is swallowed). Made for a leader key.
    public var oneShotModes: Set<String> = []
    public var gaps = Gaps()
    public var smartGaps = false
    public var defaultOrientation = DefaultOrientation.auto
    /// `auto_split yes` (Hyprland's dwindle): a new window splits the focused one along its longer side.
    public var autoSplit = false
    /// `workspace_scroll yes`: floating_modifier + scroll wheel goes to the next/previous workspace on the display.
    public var workspaceScroll = true
    /// `which_key yes`: while a mode (the leader, resize) is on, a panel lists its keys.
    public var whichKey = true
    public var workspaceLayout: Layout?
    public var autoBackAndForth = false
    public var focusFollowsMouse = false
    /// i3's `focus_on_window_activation`: what happens when an app brings up a window on a workspace you can't
    /// see (a notification click, Spotlight, an app opening a link). `focus` goes there (default); `none` and
    /// `urgent` stay put. Cmd-Tab always goes there.
    public var focusOnActivation = "urgent"
    public var mouseWarping = true
    /// `key_layout auto` (default): key names follow the current keyboard layout (`Keys.layout`).
    /// `key_layout qwerty`: they always mean the US key positions.
    public var keyLayoutFollowsInput = true
    public var focusWrapping = true
    public var accordionPadding: CGFloat = 30
    public var floatingModifier: Modifiers?
    /// `native_fullscreen panespace`: ⌃⌘F / Globe+F, the green button and `fullscreen` use Panespace zoom (the
    /// window stays tiled, below the menu bar). Default `macos`: they all use real macOS full screen.
    public var interceptNativeFullscreen = false
    /// Switching workspaces shows the new windows before parking the old ones, so the bare desktop never flashes.
    public var smoothLayout = true
    /// Layout changes glide instead of jumping (`animations no` turns it off).
    public var animations = true
    /// About when a layout animation looks finished, in seconds (`animation_duration <ms>`); it moves on a spring.
    public var animationDuration = 0.18
    /// Trackpad swipes: sideways switches workspace (windows follow the fingers), up/down zooms.
    public var gestures = true
    /// How many fingers a swipe takes (3 or 4). Pick the count macOS isn't using for its own swipes.
    public var gestureFingers = 4
    /// Menu bar indicator look: number | pill | panes | circle | minimal (current workspace) or segmented | dots | tiles.
    public var workspaceIndicator = "number"
    /// nil = leave the macOS menu bar/Dock alone; true/false = set immersive mode at startup.
    public var immersive: Bool?
    /// Focus border drawn around the focused window (i3: default_border pixel N / client.focused).
    public var borderWidth: CGFloat = 0
    public var borderColor = "#5294E2"
    public var borderRadius: CGFloat = 12
    public var execs: [String] = []
    public var execAlways: [String] = []
    public var rules: [Rule] = []
    public var assignments: [Assignment] = []
    public var workspaceOutputs: [String: [String]] = [:]
    /// The `workspace … output …` lines' workspaces, in config order (the first free one opens on a display).
    public var workspaceOutputOrder: [String] = []
    public var warnings: [String] = []

    public init() {}

    /// Any binding or the floating modifier uses Caps Lock.
    public var usesCapsLock: Bool {
        floatingModifier?.contains(.caps) == true || modes.values.contains { $0.keys.contains { $0.modifiers.contains(.caps) } }
    }

    static let ignored: Set<String> = [
        "font", "hide_edge_borders", "new_window", "new_float",
        "title_align", "floating_minimum_size", "floating_maximum_size", "popup_during_fullscreen",
        "force_display_urgency_hint", "show_marks", "ipc-socket", "ipc_socket",
        "force_focus_wrapping", "for_window_title", "include", "smart_borders", "border_radius", "bindswitch",
        "no_focus", "tiling_drag", "bar", "default_floating_border",
    ]

    /// Drops a trailing "  # comment" (a `#` after whitespace and followed by a space), outside quotes.
    /// Colors like `#5294e2` and quoted text are left alone.
    public static func stripTrailingComment(_ line: String) -> String {
        let chars = Array(line)
        var quote: Character?
        for i in chars.indices {
            let c = chars[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#", i > 0, chars[i - 1].isWhitespace, i + 1 == chars.count || chars[i + 1] == " " {
                return String(chars[..<i])
            }
        }
        return line
    }

    /// Index of the first top-level line whose leading words are `key` (e.g. "focus_follows_mouse" or
    /// "set $mod"); lines inside `mode { … }` blocks and comments don't count.
    private static func settingLine(_ key: String, in lines: [String]) -> Int? {
        let keyWords = key.split(separator: " ").map(String.init)
        var depth = 0
        for (i, raw) in lines.enumerated() {
            let line = stripTrailingComment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line == "}" { depth = max(0, depth - 1); continue }
            let words = CommandParser.words(line)
            if depth == 0, words.count > keyWords.count,
               zip(words, keyWords).allSatisfy({ $0.lowercased() == $1.lowercased() }) { return i }
            if line.hasSuffix("{") { depth += 1 }
        }
        return nil
    }

    /// The value of a top-level setting in config `text`, e.g. `value(of: "set $mod", in:)` → "alt".
    public static func value(of key: String, in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let i = settingLine(key, in: lines) else { return nil }
        let words = CommandParser.words(stripTrailingComment(lines[i]))
        return words.dropFirst(key.split(separator: " ").count).joined(separator: " ")
    }

    /// `text` with the setting changed to `value` in place (its trailing comment kept), or added before the
    /// first setting when the config doesn't have it. Used by the menu bar's Settings items.
    public static func setting(_ key: String, to value: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let body = "\(key) \(value)"
        if let i = settingLine(key, in: lines) {
            let code = stripTrailingComment(lines[i])
            let comment = lines[i].dropFirst(code.count)
            lines[i] = comment.isEmpty ? body : body.padding(toLength: max(code.count, body.count + 1), withPad: " ", startingAt: 0) + comment
        } else {
            let first = lines.firstIndex {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && !t.hasPrefix("#")
            } ?? lines.count
            lines.insert(body, at: first)
        }
        return lines.joined(separator: "\n")
    }

    public static func parse(_ text: String) -> Config {
        var c = Config()
        var vars: [(String, String)] = []
        var modeStack: [String] = []
        var skipDepth = 0

        // Join continuation lines.
        var lines: [(Int, String)] = []
        var pending = ""
        var pendingLine = 0
        for (n, l) in text.components(separatedBy: .newlines).enumerated() {
            if pending.isEmpty { pendingLine = n + 1 }
            if l.hasSuffix("\\") { pending += l.dropLast() + " "; continue }
            lines.append((pendingLine, pending + l))
            pending = ""
        }

        for (lineNo, rawLine) in lines {
            var line = Config.stripTrailingComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            func warn(_ s: String) { c.warnings.append("line \(lineNo): \(s)") }

            if skipDepth > 0 {
                if line.hasSuffix("{") { skipDepth += 1 }
                if line == "}" { skipDepth -= 1 }
                continue
            }
            if line == "}" {
                if modeStack.popLast() == nil { warn("unexpected '}'") }
                continue
            }

            let first = CommandParser.words(line).first?.lowercased() ?? ""
            if first == "set" {
                let w = CommandParser.words(line)
                guard w.count >= 3, w[1].hasPrefix("$") else { warn("bad set"); continue }
                var value = CommandParser.rest(CommandParser.rest(line))
                for (k, v) in vars { value = value.replacingOccurrences(of: k, with: v) }
                vars.removeAll { $0.0 == w[1] }
                vars.append((w[1], value))
                vars.sort { $0.0.count > $1.0.count }
                continue
            }
            for (k, v) in vars { line = line.replacingOccurrences(of: k, with: v) }
            let w = CommandParser.words(line)
            let args = Array(w.dropFirst())
            let a = args.map { $0.lowercased() }
            func bool(_ s: String?) -> Bool { ["yes", "on", "true", "1", "enable", "output"].contains(s ?? "") }

            switch first {
            case "bindsym", "bindcode":
                var rest = CommandParser.rest(line)
                var release = false
                while rest.hasPrefix("--") {
                    if rest.hasPrefix("--release") { release = true }
                    rest = CommandParser.rest(rest)
                }
                let keySpec = CommandParser.words(rest).first ?? ""
                let command = CommandParser.rest(rest)
                guard let combo = KeyCombo.parse(keySpec, isCode: first == "bindcode") else {
                    warn("unknown key '\(keySpec)'"); continue
                }
                guard !command.isEmpty else { warn("binding '\(keySpec)' has no command"); continue }
                if release { warn("--release is not supported; binding fires on press") }
                do { _ = try CommandParser.parse(command) } catch { warn("\(keySpec): \(error)") }
                let mode = modeStack.last ?? "default"
                c.modes[mode, default: [:]][combo] = command

            case "mode":
                guard line.hasSuffix("{"), let name = args.first(where: { !$0.hasPrefix("--") }) else {
                    warn("expected: mode \"name\" {"); continue
                }
                modeStack.append(name)
                c.modes[name, default: [:]] = c.modes[name] ?? [:]
                if args.contains("--oneshot") { c.oneShotModes.insert(name) }

            case "gaps":
                guard a.count >= 2, let v = Double(a[1].replacingOccurrences(of: "px", with: "")) else {
                    warn("expected: gaps inner|outer|horizontal|vertical|top|bottom|left|right <px>"); continue
                }
                let px = CGFloat(v)
                switch a[0] {
                case "inner": c.gaps.inner = px
                case "outer": (c.gaps.top, c.gaps.bottom, c.gaps.left, c.gaps.right) = (px, px, px, px)
                case "horizontal": (c.gaps.left, c.gaps.right) = (px, px)
                case "vertical": (c.gaps.top, c.gaps.bottom) = (px, px)
                case "top": c.gaps.top = px
                case "bottom": c.gaps.bottom = px
                case "left": c.gaps.left = px
                case "right": c.gaps.right = px
                default: warn("unknown gaps kind '\(a[0])'")
                }

            case "default_border", "new_window":
                switch a.first {
                case "none": c.borderWidth = 0
                case "pixel", "normal": c.borderWidth = a.count > 1 ? CGFloat(Double(a[1]) ?? 2) : 2
                default: warn("expected: default_border none|pixel <px>")
                }
            case "border_radius":
                if let v = a.first.flatMap(Double.init) { c.borderRadius = CGFloat(v) } else { warn("bad border_radius") }
            case "client.focused":
                // i3: border background text indicator [child_border]; the child border is what frames the window.
                let colors = args.filter { $0.hasPrefix("#") }
                if let col = colors.count >= 5 ? colors[4] : colors.first { c.borderColor = col } else { warn("client.focused needs colors") }
            case "immersive": c.immersive = bool(a.first)
            case "native_fullscreen": c.interceptNativeFullscreen = a.first == "panespace"
            case "smooth_layout": c.smoothLayout = bool(a.first)
            case "animations": c.animations = bool(a.first)
            case "gestures": c.gestures = bool(a.first)
            case "auto_split": c.autoSplit = bool(a.first) || a.first == "dwindle"
            case "workspace_scroll": c.workspaceScroll = bool(a.first)
            case "which_key": c.whichKey = bool(a.first)
            case "gesture_fingers":
                if let v = a.first.flatMap(Int.init), v == 3 || v == 4 { c.gestureFingers = v } else { warn("expected: gesture_fingers 3|4") }
            case "animation_duration":
                if let v = a.first.flatMap(Double.init), v >= 0 { c.animationDuration = min(v, 1000) / 1000 } else { warn("bad animation_duration") }
            case "workspace_indicator":
                if let v = a.first, ["number", "pill", "panes", "circle", "minimal", "segmented", "dots", "tiles"].contains(v) { c.workspaceIndicator = v } else {
                    warn("expected: workspace_indicator number|pill|panes|circle|minimal|segmented|dots|tiles")
                }
            case "smart_gaps": c.smartGaps = bool(a.first)
            case "workspace_auto_back_and_forth": c.autoBackAndForth = bool(a.first)
            case "focus_follows_mouse": c.focusFollowsMouse = bool(a.first)
            case "mouse_warping": c.mouseWarping = a.first != "none"
            case "key_layout":
                let v = a.first?.lowercased() ?? ""
                if ["auto", "current"].contains(v) { c.keyLayoutFollowsInput = true }
                else if ["qwerty", "us", "physical"].contains(v) { c.keyLayoutFollowsInput = false }
                else { c.warnings.append("key_layout: expected auto or qwerty, got '\(v)'") }
            case "focus_on_window_activation":
                if let v = a.first?.lowercased(), ["focus", "smart", "urgent", "none"].contains(v) {
                    c.focusOnActivation = v == "smart" ? "urgent" : v
                } else { warn("expected: focus_on_window_activation focus|smart|urgent|none") }
            case "focus_wrapping": c.focusWrapping = a.first != "no" && a.first != "false"
            case "accordion_padding":
                if let v = a.first.flatMap(Double.init) { c.accordionPadding = CGFloat(v) } else { warn("bad accordion_padding") }
            case "default_orientation":
                switch a.first {
                case "horizontal": c.defaultOrientation = .horizontal
                case "vertical": c.defaultOrientation = .vertical
                default: c.defaultOrientation = .auto
                }
            case "workspace_layout":
                switch a.first {
                case "tabbed": c.workspaceLayout = .tabbed
                case "stacking", "stacked": c.workspaceLayout = .stacking
                default: c.workspaceLayout = nil
                }
            case "floating_modifier":
                var m: Modifiers = []
                for p in (args.first ?? "").split(separator: "+") {
                    if let x = Modifiers.named(String(p)) { m.formUnion(x) } else { warn("unknown modifier '\(p)'") }
                }
                c.floatingModifier = m.isEmpty ? nil : m

            case "exec", "exec_always":
                var cmd = CommandParser.rest(line)
                if cmd.hasPrefix("--no-startup-id") { cmd = CommandParser.rest(cmd) }
                if first == "exec" { c.execs.append(cmd) } else { c.execAlways.append(cmd) }

            case "for_window", "assign":
                let body = CommandParser.rest(line)
                guard body.hasPrefix("["), let close = CommandParser.closingBracket(body) else {
                    warn("\(first) needs [criteria]"); continue
                }
                let crit: Criteria
                do { crit = try Criteria.parse(String(body[body.index(after: body.startIndex)..<close])) } catch {
                    warn("\(error)"); continue
                }
                let tail = String(body[body.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                if first == "for_window" {
                    do { _ = try CommandParser.parse(tail) } catch { warn("for_window: \(error)"); continue }
                    c.rules.append(Rule(criteria: crit, command: tail))
                } else {
                    var t = CommandParser.words(tail)
                    if let f = t.first, f == "→" || f == "->" { t.removeFirst() }
                    if t.first?.lowercased() == "workspace" { t.removeFirst() }
                    if t.first?.lowercased() == "output" { warn("assign to output is not supported"); continue }
                    let isNumber = t.first?.lowercased() == "number"
                    if isNumber { t.removeFirst() }
                    let name = t.joined(separator: " ")
                    guard !name.isEmpty else { warn("assign needs a workspace"); continue }
                    c.assignments.append(Assignment(criteria: crit, workspace: isNumber ? .number(name) : .name(name)))
                }

            case "workspace":
                // workspace <name> output <out1> [<out2> …]
                guard let o = a.firstIndex(of: "output"), o > 0, o + 1 < args.count else {
                    warn("expected: workspace <name> output <output>"); continue
                }
                let name = args[..<o].joined(separator: " ")
                if c.workspaceOutputs[name] == nil { c.workspaceOutputOrder.append(name) }
                c.workspaceOutputs[name] = Array(args[(o + 1)...])

            default:
                if first.hasPrefix("client.") || Config.ignored.contains(first) {
                    if line.hasSuffix("{") { skipDepth = 1 }
                } else if line.hasSuffix("{") {
                    skipDepth = 1
                    warn("ignoring unknown block '\(first)'")
                } else {
                    warn("unknown directive '\(first)'")
                }
            }
        }
        if !modeStack.isEmpty { c.warnings.append("unclosed mode block '\(modeStack.last!)'") }
        return c
    }
}
