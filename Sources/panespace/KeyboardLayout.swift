import Carbon
import Foundation
import PanespaceCore

/// The current keyboard layout as a character → key code table, so `bindsym $mod+q` means the key that types
/// "q" (i3's keysym meaning) on AZERTY, Dvorak or Colemak too, not the US key in that spot.
enum KeyboardLayout {
    /// The keys that type characters: the main block (no keypad, which also types digits), plus ISO § and JIS ¥ _.
    private static let codes: [UInt16] = Array(0x00...0x32).filter { ![0x24, 0x30, 0x31].contains($0) } + [0x5D, 0x5E]

    /// Unshifted characters first, then shifted ones for what's still missing (AZERTY types digits with shift).
    /// nil when the layout has no character table (some input methods).
    static func current() -> [String: UInt16]? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var out: [String: UInt16] = [:]
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            for shift in [false, true] {
                let mods: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
                for code in codes {
                    var dead: UInt32 = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    var length = 0
                    let err = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                                             OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars)
                    guard err == noErr, length == 1 else { continue }
                    let s = String(utf16CodeUnits: chars, count: 1).lowercased()
                    guard let u = s.unicodeScalars.first, !CharacterSet.controlCharacters.contains(u), s != " " else { continue }
                    if out[s] == nil { out[s] = code }
                }
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Calls `body` on the main queue whenever the user switches input source.
    static func observe(_ body: @escaping () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil,
            queue: .main) { _ in body() }
    }
}
