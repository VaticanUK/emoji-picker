import Carbon.HIToolbox
import Foundation

/// A global hotkey: a virtual key code plus a Carbon modifier mask.
public struct Shortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_Period), modifiers: UInt32(optionKey))

    /// True when Option is the only modifier (these combos type characters, e.g. ⌥. gives ≥).
    public var isOptionOnly: Bool { modifiers == UInt32(optionKey) }

    /// Why this can't be a global shortcut, or nil when it's fine: it needs a modifier, and
    /// Shift alone would block normal typing.
    public var validationError: String? {
        let mask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let mods = modifiers & mask
        if mods == 0 { return "Include at least one modifier key (⌃ ⌥ ⌘)" }
        if mods == UInt32(shiftKey) { return "Shift alone isn't enough; add ⌃ ⌥ or ⌘" }
        return nil
    }

    /// Modifier symbols in the order ⌃⌥⇧⌘, then the key.
    public var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(for: keyCode)
    }

    private static let namedKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
        kVK_Escape: "⎋", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func keyName(for keyCode: UInt32) -> String {
        if let name = namedKeys[Int(keyCode)] { return name }
        return translated(keyCode)?.uppercased() ?? "Key\(keyCode)"
    }

    /// Character for the key on the current keyboard layout, via UCKeyTranslate.
    private static func translated(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeys, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return nil }
        let result = String(utf16CodeUnits: chars, count: length)
        return result.unicodeScalars.allSatisfy { $0.value >= 0x20 } ? result : nil
    }
}
