import CoreGraphics

public enum Toggle: Equatable { case enable, disable, toggle }

public enum WorkspaceTarget: Equatable {
    case name(String)
    case number(String)
    case next, prev, nextOnOutput, prevOnOutput, backAndForth
}

public enum OutputTarget: Equatable {
    case direction(Direction)
    case next, prev
    case name(String)
}

public enum LayoutArg: Equatable {
    case set(Layout)
    case toggleSplit, toggleAll, defaultSplit
    /// `layout toggle tabbed stacking split`; nil = "split" (the container's last split layout).
    case cycle([Layout?])
}

public enum ResizeDimension: Equatable { case width, height, edge(Direction) }

public struct ResizeArg: Equatable {
    public var grow: Bool
    public var dimension: ResizeDimension
    public var px: Int?
    public var ppt: Int?
}

public enum Command: Equatable {
    case exec(String)
    case focus(Direction)
    /// `[criteria] focus`: jump to the matched window.
    case focusTarget
    case focusParent, focusChild, focusModeToggle, focusFloating, focusTiling
    case focusOutput(OutputTarget)
    case move(Direction, px: Int?)
    case moveToWorkspace(WorkspaceTarget)
    case moveToOutput(OutputTarget)
    case moveWorkspaceToOutput(OutputTarget)
    case moveToScratchpad
    case movePositionCenter
    case scratchpadShow
    case workspace(WorkspaceTarget, noAutoBackAndForth: Bool)
    /// panespace: `workspace number 3 output next` shows that workspace on that monitor, bringing it over if it
    /// lives on another one.
    case workspaceOnOutput(WorkspaceTarget, OutputTarget)
    case split(Orientation?)  // nil = toggle
    case layout(LayoutArg)
    case fullscreen(Toggle)
    case floating(Toggle)
    case resize(ResizeArg)
    case balance
    /// panespace: auto-hide the macOS menu bar and Dock so tiles use the whole screen (Omarchy-style).
    case immersive(Toggle)
    /// panespace: a search box over every window (type, arrows, Return to jump to it).
    case switcher
    case kill
    case reload
    case exit
    case mode(String)
    case nop
}

public struct ParsedCommand: Equatable {
    public var criteria: String?
    public var command: Command
}

/// Parser for i3's command language: `[criteria] cmd args, cmd args; cmd args`.
public enum CommandParser {
    public static func parse(_ text: String) throws -> [ParsedCommand] {
        var out: [ParsedCommand] = []
        var criteria: String?
        for (segment, separator) in segments(text) {
            var raw = segment.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("[") {
                guard let close = closingBracket(raw) else { throw ParseError("unterminated criteria in '\(raw)'") }
                criteria = String(raw[raw.index(after: raw.startIndex)..<close])
                _ = try Criteria.parse(criteria!)
                raw = String(raw[raw.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            if !raw.isEmpty { out.append(ParsedCommand(criteria: criteria, command: try command(raw))) }
            if separator == ";" { criteria = nil }
        }
        if out.isEmpty { throw ParseError("empty command") }
        return out
    }

    /// Splits on `;` and `,` outside quotes and brackets, keeping the separator that ended each piece.
    static func segments(_ s: String) -> [(String, Character?)] {
        var out: [(String, Character?)] = []
        var cur = ""
        var quote: Character?
        var depth = 0
        var escaped = false
        for ch in s {
            if escaped { cur.append(ch); escaped = false; continue }
            if ch == "\\" && quote == "\"" { cur.append(ch); escaped = true; continue }
            if let q = quote {
                if ch == q { quote = nil }
                cur.append(ch)
                continue
            }
            switch ch {
            case "\"", "'": quote = ch; cur.append(ch)
            case "[": depth += 1; cur.append(ch)
            case "]": depth = max(0, depth - 1); cur.append(ch)
            case ";" where depth == 0, "," where depth == 0:
                out.append((cur, ch))
                cur = ""
            default: cur.append(ch)
            }
        }
        out.append((cur, nil))
        return out
    }

    static func closingBracket(_ s: String) -> String.Index? {
        var quote: Character?
        var i = s.index(after: s.startIndex)
        while i < s.endIndex {
            let ch = s[i]
            if let q = quote { if ch == q { quote = nil } } else if ch == "\"" || ch == "'" { quote = ch } else if ch == "]" { return i }
            i = s.index(after: i)
        }
        return nil
    }

    /// Shell-like word split with quote removal.
    public static func words(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for ch in s {
            if escaped { cur.append(ch); escaped = false; continue }
            if let q = quote {
                if ch == q { quote = nil } else if ch == "\\" && q == "\"" { escaped = true } else { cur.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; inWord = true; continue }
            if ch.isWhitespace {
                if inWord { out.append(cur); cur = ""; inWord = false }
                continue
            }
            cur.append(ch)
            inWord = true
        }
        if inWord { out.append(cur) }
        return out
    }

    /// Text after the first word, untouched (for exec).
    public static func rest(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let sp = t.firstIndex(where: { $0.isWhitespace }) else { return "" }
        return String(t[sp...]).trimmingCharacters(in: .whitespaces)
    }

    static func command(_ raw: String) throws -> Command {
        let w = words(raw)
        guard let head = w.first?.lowercased() else { throw ParseError("empty command") }
        let a = Array(w.dropFirst())
        let lower = a.map { $0.lowercased() }
        func arg(_ i: Int) -> String? { i < lower.count ? lower[i] : nil }

        switch head {
        case "exec":
            var cmd = rest(raw)
            if cmd.hasPrefix("--no-startup-id") { cmd = rest(cmd) }
            if cmd.count >= 2, let f = cmd.first, f == "\"" || f == "'", cmd.last == f,
               !cmd.dropFirst().dropLast().contains(f) {
                cmd = String(cmd.dropFirst().dropLast())
            }
            guard !cmd.isEmpty else { throw ParseError("exec needs a command") }
            return .exec(cmd)
        case "nop": return .nop
        case "kill": return .kill
        case "reload", "restart": return .reload
        case "exit": return .exit
        case "balance": return .balance
        case "immersive": return .immersive(try toggle(arg(0) ?? "toggle"))
        case "switcher": return .switcher
        case "mode":
            guard let m = a.first else { throw ParseError("mode needs a name") }
            return .mode(m)

        case "focus":
            guard let x = arg(0) else { return .focusTarget }
            if let d = Direction(rawValue: x) { return .focus(d) }
            switch x {
            case "parent": return .focusParent
            case "child": return .focusChild
            case "mode_toggle": return .focusModeToggle
            case "floating": return .focusFloating
            case "tiling": return .focusTiling
            case "output": return .focusOutput(try output(Array(a.dropFirst())))
            default: throw ParseError("unknown focus target '\(x)'")
            }

        case "move":
            var i = 0
            if arg(i) == "window" || arg(i) == "container" { i += 1 }
            if arg(i) == "to" { i += 1 }
            guard let x = arg(i) else { throw ParseError("move needs an argument") }
            if let d = Direction(rawValue: x) {
                return .move(d, px: arg(i + 1).flatMap { Int($0) })
            }
            switch x {
            case "workspace":
                i += 1
                if arg(i) == "to" || arg(i) == "output" {
                    if arg(i) == "to" { i += 1 }
                    if arg(i) == "output" { i += 1 }
                    return .moveWorkspaceToOutput(try output(Array(a[i...])))
                }
                return .moveToWorkspace(try workspace(Array(a[i...])).0)
            case "output": return .moveToOutput(try output(Array(a[(i + 1)...])))
            case "scratchpad": return .moveToScratchpad
            case "position", "absolute":
                guard lower.contains("center") else { throw ParseError("only 'move position center' is supported") }
                return .movePositionCenter
            default: throw ParseError("unknown move target '\(x)'")
            }

        case "workspace":
            if let o = a.lastIndex(where: { $0.lowercased() == "output" }), o > 0, o + 1 < a.count {
                return .workspaceOnOutput(try workspace(Array(a[..<o])).0, try output(Array(a[(o + 1)...])))
            }
            let (t, noAuto) = try workspace(a)
            return .workspace(t, noAutoBackAndForth: noAuto)

        case "split":
            switch arg(0) {
            case "h", "horizontal": return .split(.horizontal)
            case "v", "vertical": return .split(.vertical)
            case "t", "toggle": return .split(nil)
            default: throw ParseError("split needs h, v or toggle")
            }

        case "layout":
            guard let x = arg(0) else { throw ParseError("layout needs an argument") }
            if let l = layoutName(x) { return .layout(.set(l)) }
            switch x {
            case "default": return .layout(.defaultSplit)
            case "toggle":
                let items = Array(lower.dropFirst())
                if items.isEmpty || items == ["split"] { return .layout(.toggleSplit) }
                if items == ["all"] { return .layout(.toggleAll) }
                return .layout(.cycle(try items.map { item -> Layout? in
                    if item == "split" { return nil }
                    guard let l = layoutName(item) else { throw ParseError("unknown layout '\(item)'") }
                    return l
                }))
            default: throw ParseError("unknown layout '\(x)'")
            }

        case "fullscreen": return .fullscreen(try toggle(arg(0) ?? "toggle"))
        case "floating":
            guard let x = arg(0) else { throw ParseError("floating needs enable, disable or toggle") }
            return .floating(try toggle(x))

        case "resize":
            guard let kind = arg(0), kind == "grow" || kind == "shrink" else {
                throw ParseError("resize supports 'grow' and 'shrink'")
            }
            let dim: ResizeDimension
            switch arg(1) {
            case "width": dim = .width
            case "height": dim = .height
            case let s?: guard let d = Direction(rawValue: s) else { throw ParseError("bad resize direction '\(s)'") }
                dim = .edge(d)
            case nil: throw ParseError("resize needs width/height/direction")
            }
            var r = ResizeArg(grow: kind == "grow", dimension: dim)
            var j = 2
            while j < lower.count {
                if let n = Int(lower[j]) {
                    if arg(j + 1) == "ppt" { r.ppt = n; j += 1 } else { r.px = n; if arg(j + 1) == "px" { j += 1 } }
                } else if lower[j] != "or" {
                    throw ParseError("unexpected '\(lower[j])' in resize")
                }
                j += 1
            }
            return .resize(r)

        case "scratchpad":
            guard arg(0) == "show" else { throw ParseError("only 'scratchpad show' is supported") }
            return .scratchpadShow

        default:
            throw ParseError("unknown command '\(head)'")
        }
    }

    static func layoutName(_ s: String) -> Layout? {
        switch s {
        case "splith": return .splitH
        case "splitv": return .splitV
        case "tabbed": return .tabbed
        case "stacking", "stacked": return .stacking
        default: return nil
        }
    }

    static func toggle(_ s: String) throws -> Toggle {
        switch s {
        case "enable", "on", "yes": return .enable
        case "disable", "off", "no": return .disable
        case "toggle": return .toggle
        default: throw ParseError("expected enable, disable or toggle, got '\(s)'")
        }
    }

    static func workspace(_ a: [String]) throws -> (WorkspaceTarget, Bool) {
        var a = a[...]
        var noAuto = false
        if a.first == "--no-auto-back-and-forth" { noAuto = true; a = a.dropFirst() }
        guard let f = a.first else { throw ParseError("workspace needs a name") }
        switch f.lowercased() {
        case "next": return (.next, noAuto)
        case "prev": return (.prev, noAuto)
        case "next_on_output": return (.nextOnOutput, noAuto)
        case "prev_on_output": return (.prevOnOutput, noAuto)
        case "back_and_forth": return (.backAndForth, noAuto)
        case "number":
            let name = a.dropFirst().joined(separator: " ")
            guard Int(String(name.prefix { $0.isASCII && $0.isNumber })) != nil else {
                throw ParseError("workspace number needs a number")
            }
            return (.number(name), noAuto)
        default: return (.name(a.joined(separator: " ")), noAuto)
        }
    }

    static func output(_ a: [String]) throws -> OutputTarget {
        guard let f = a.first else { throw ParseError("output needs a target") }
        if let d = Direction(rawValue: f.lowercased()) { return .direction(d) }
        switch f.lowercased() {
        case "next": return .next
        case "prev": return .prev
        default: return .name(a.joined(separator: " "))
        }
    }
}
