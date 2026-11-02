import Foundation

/// A global shortcut: a virtual key code plus Carbon modifier flags.
public struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    // Carbon modifier bits (Events.h).
    public static let cmd: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12

    public static let spaceKey: UInt32 = 49
    public static let escapeKey: UInt32 = 53
    public static let `default` = KeyCombo(keyCode: spaceKey, modifiers: option)

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & (Self.cmd | Self.shift | Self.option | Self.control)
    }

    public var displayString: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.cmd != 0 { s += "⌘" }
        return s + KeyNames.name(for: keyCode)
    }

    public var isFunctionKey: Bool { KeyNames.functionKeys.keys.contains(keyCode) }

    /// Rejects shortcuts that would swallow normal typing (a bare letter, or Shift+letter).
    public var validationError: String? {
        let meaningful = modifiers & (Self.cmd | Self.option | Self.control)
        if meaningful == 0 && !isFunctionKey {
            return "Use at least one of ⌃, ⌥ or ⌘, or a function key, so normal typing is not affected."
        }
        if keyCode == Self.escapeKey { return "Escape is reserved for cancelling a recording." }
        return nil
    }

    /// Converts Cocoa `NSEvent.ModifierFlags` raw bits to Carbon bits.
    public static func carbonModifiers(fromCocoa flags: UInt) -> UInt32 {
        var m: UInt32 = 0
        if flags & (1 << 17) != 0 { m |= shift }
        if flags & (1 << 18) != 0 { m |= control }
        if flags & (1 << 19) != 0 { m |= option }
        if flags & (1 << 20) != 0 { m |= cmd }
        return m
    }
}

public enum KeyNames {
    static let functionKeys: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
    static let named: [UInt32: String] = [
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "PgUp", 121: "PgDn",
    ]
    // US ANSI layout; good enough for display purposes.
    static let ansi: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K",
        37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U",
        9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z", 29: "0", 18: "1", 19: "2", 20: "3", 21: "4",
        23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 27: "-", 24: "=", 33: "[", 30: "]", 42: "\\",
        41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`",
    ]

    public static func name(for keyCode: UInt32) -> String {
        functionKeys[keyCode] ?? named[keyCode] ?? ansi[keyCode] ?? "Key \(keyCode)"
    }
}

/// Detects clashes with enabled macOS keyboard shortcuts stored in
/// `com.apple.symbolichotkeys` → `AppleSymbolicHotKeys`.
public enum SystemShortcutConflicts {
    static let knownNames: [Int: String] = [
        60: "Select the previous input source", 61: "Select next source in Input menu",
        64: "Show Spotlight search", 65: "Show Finder search window",
        32: "Mission Control", 33: "Application windows", 36: "Show Desktop",
        79: "Move left a space", 81: "Move right a space", 52: "Turn Dock hiding on/off",
        28: "Save picture of screen as a file", 29: "Copy picture of screen to the clipboard",
        30: "Save picture of selected area as a file", 31: "Copy picture of selected area to the clipboard",
        184: "Screenshot and recording options", 162: "Show Launchpad / Apps", 98: "Show Help menu",
        7: "Move focus to the menu bar", 8: "Move focus to the Dock", 9: "Move focus to active or next window",
        10: "Move focus to window toolbar", 11: "Move focus to floating window",
        27: "Move focus to next window", 57: "Move focus to status menus",
    ]

    /// Returns human-readable names of enabled system shortcuts equal to `combo`.
    public static func conflicts(for combo: KeyCombo, in symbolicHotKeys: [String: Any]) -> [String] {
        var names: [String] = []
        for (key, raw) in symbolicHotKeys {
            guard let entry = raw as? [String: Any],
                  (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let value = entry["value"] as? [String: Any],
                  (value["type"] as? String) == "standard",
                  let params = value["parameters"] as? [NSNumber], params.count >= 3 else { continue }
            let keyCode = params[1].uint32Value
            let modifiers = KeyCombo.carbonModifiers(fromCocoa: params[2].uintValue)
            if keyCode == combo.keyCode && modifiers == combo.modifiers {
                let id = Int(key) ?? -1
                names.append(knownNames[id] ?? "macOS shortcut #\(key)")
            }
        }
        return names.sorted()
    }

    /// Popular apps that default to the same shortcut. Their registrations cannot be detected
    /// reliably, so this is shown as a hint only.
    public static func commonAppHints(for combo: KeyCombo) -> [String] {
        if combo == .default {
            return ["ChatGPT desktop (Companion window)", "Raycast", "Alfred"]
        }
        if combo == KeyCombo(keyCode: KeyCombo.spaceKey, modifiers: KeyCombo.cmd) {
            return ["Spotlight"]
        }
        return []
    }
}
