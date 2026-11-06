public struct Modifiers: OptionSet, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = Modifiers(rawValue: 1)
    public static let control = Modifiers(rawValue: 2)
    public static let option = Modifiers(rawValue: 4)
    public static let command = Modifiers(rawValue: 8)
    /// Caps Lock used as a modifier (panespace remaps it to F18 and tracks it).
    public static let caps = Modifiers(rawValue: 16)

    /// i3 and macOS spellings. Mod1 = alt, Mod4 = super = cmd, as on X11.
    static func named(_ s: String) -> Modifiers? {
        switch s.lowercased() {
        case "shift": return .shift
        case "ctrl", "control": return .control
        case "alt", "opt", "option", "mod1": return .option
        case "cmd", "command", "super", "mod4": return .command
        case "caps", "capslock", "caps_lock": return .caps
        case "hyper": return [.shift, .control, .option, .command]
        case "meh": return [.shift, .control, .option]
        default: return nil
        }
    }
}

public struct KeyCombo: Hashable, CustomStringConvertible {
    /// Key name for display ("f", "return", …).
    public var keyName: String? { Keys.name(for: keyCode) }

    public var keyCode: UInt16
    public var modifiers: Modifiers
    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Parses "$mod+Shift+h" style specs (variables already substituted). `isCode` = bindcode.
    public static func parse(_ spec: String, isCode: Bool = false) -> KeyCombo? {
        let parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let keyName = parts.last, !keyName.isEmpty else { return nil }
        var mods: Modifiers = []
        for p in parts.dropLast() {
            guard let m = Modifiers.named(p) else { return nil }
            mods.formUnion(m)
        }
        let code: UInt16?
        if isCode { code = UInt16(keyName) } else { code = Keys.code(for: keyName) }
        return code.map { KeyCombo(keyCode: $0, modifiers: mods) }
    }

    public var description: String {
        var s = ""
        if modifiers.contains(.caps) { s += "caps+" }
        if modifiers.contains(.control) { s += "ctrl+" }
        if modifiers.contains(.option) { s += "alt+" }
        if modifiers.contains(.command) { s += "cmd+" }
        if modifiers.contains(.shift) { s += "shift+" }
        return s + (Keys.name(for: keyCode) ?? "code\(keyCode)")
    }
}

/// X11 keysym names → macOS virtual key codes (ANSI positions).
public enum Keys {
    /// The current keyboard layout's characters → key codes, set by the app (nil = US positions). Key names that
    /// stand for a character ("q", "1", "bracketleft") follow it, so a binding means the key that types it; names
    /// it can't type (a Devanagari or Cyrillic layout) keep their US position.
    public static var layout: [String: UInt16]?

    /// The character a key name stands for.
    static func character(_ name: String) -> String? {
        if name.count == 1 { return name }
        return [
            "bracketleft": "[", "leftbracket": "[", "bracketright": "]", "rightbracket": "]", "semicolon": ";",
            "apostrophe": "'", "quote": "'", "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
            "grave": "`", "backtick": "`", "quoteleft": "`", "minus": "-", "dash": "-", "equal": "=", "plus": "+",
        ][name]
    }

    static let table: [String: UInt16] = {
        var t: [String: UInt16] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
            "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
            "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "equal": 0x18,
            "9": 0x19, "7": 0x1A, "minus": 0x1B, "8": 0x1C, "0": 0x1D, "bracketright": 0x1E, "o": 0x1F,
            "u": 0x20, "bracketleft": 0x21, "i": 0x22, "p": 0x23, "return": 0x24, "l": 0x25, "j": 0x26,
            "apostrophe": 0x27, "k": 0x28, "semicolon": 0x29, "backslash": 0x2A, "comma": 0x2B,
            "slash": 0x2C, "n": 0x2D, "m": 0x2E, "period": 0x2F, "tab": 0x30, "space": 0x31, "grave": 0x32,
            "backspace": 0x33, "escape": 0x35, "section": 0x0A,
            "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
            "home": 0x73, "end": 0x77, "prior": 0x74, "next": 0x79, "delete": 0x75, "help": 0x72,
            "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
            "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F, "f13": 0x69, "f14": 0x6B, "f15": 0x71,
            "f16": 0x6A, "f17": 0x40, "f18": 0x4F, "f19": 0x50, "f20": 0x5A,
            "kp_0": 0x52, "kp_1": 0x53, "kp_2": 0x54, "kp_3": 0x55, "kp_4": 0x56, "kp_5": 0x57,
            "kp_6": 0x58, "kp_7": 0x59, "kp_8": 0x5B, "kp_9": 0x5C, "kp_decimal": 0x41,
            "kp_multiply": 0x43, "kp_add": 0x45, "kp_divide": 0x4B, "kp_enter": 0x4C,
            "kp_subtract": 0x4E, "kp_equal": 0x51,
        ]
        let aliases: [String: String] = [
            "enter": "return", "esc": "escape", "page_up": "prior", "pageup": "prior",
            "page_down": "next", "pagedown": "next", "plus": "equal", "quoteleft": "grave",
            "dash": "minus", "quote": "apostrophe", "leftbracket": "bracketleft",
            "rightbracket": "bracketright", "backtick": "grave",
            "[": "bracketleft", "]": "bracketright", ";": "semicolon", "'": "apostrophe", ",": "comma",
            ".": "period", "/": "slash", "\\": "backslash", "`": "grave", "-": "minus", "=": "equal",
        ]
        for (a, b) in aliases { t[a] = t[b] }
        return t
    }()

    public static func code(for name: String) -> UInt16? {
        let n = name.lowercased()
        if let layout, let ch = character(n), let code = layout[ch] { return code }
        return table[n]
    }

    public static func name(for code: UInt16) -> String? {
        // What the key types in the current layout: a letter or digit reads better than its US name.
        if let layout, let ch = layout.filter({ $0.value == code }).map(\.key)
            .filter({ $0.allSatisfy { $0.isLetter || $0.isNumber } }).min() { return ch }
        return table.filter { $0.value == code }.map(\.key).min { $0.count < $1.count || ($0.count == $1.count && $0 < $1) }
    }
}
