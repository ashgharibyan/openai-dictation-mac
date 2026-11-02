import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// Where the user was typing when recording started.
struct InsertionTarget {
    let app: NSRunningApplication?
    let element: AXUIElement?

    var appName: String? { app?.localizedName }
    var bundleID: String? { app?.bundleIdentifier }

    @MainActor
    static func capture() -> InsertionTarget {
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        return InsertionTarget(app: app, element: AXHelpers.focusedElement())
    }
}

enum InsertionOutcome: Equatable {
    case insertedWithAccessibility
    case pasted
    /// Could not insert; the text is on the clipboard for the user to paste.
    case copiedToClipboard(reason: String)
    /// Deliberately not inserted (e.g. password field). Text stays available via "Copy Last Transcript".
    case skipped(reason: String)

    var summary: String {
        switch self {
        case .insertedWithAccessibility, .pasted: return "Inserted"
        case .copiedToClipboard: return "Copied – press ⌘V to paste"
        case .skipped: return "Not inserted"
        }
    }
}

enum AXHelpers {
    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    static func setSelectedRange(_ element: AXUIElement, _ range: CFRange) -> Bool {
        var r = range
        guard let value = AXValueCreate(.cfRange, &r) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        string(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String)
            || string(element, kAXRoleAttribute) == "AXSecureTextField"
    }
}

/// Inserts text at the cursor of another app: Accessibility insertion where it can be verified,
/// otherwise a synthesized ⌘V with the previous clipboard restored afterwards.
@MainActor
final class TextInserter {
    private let log = Logger(subsystem: "local.dictate", category: "insert")

    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty",
        "com.github.wez.wezterm", "co.zeit.hyper", "com.raphaelamorim.rio", "dev.commandline.waveterm",
    ]

    /// Apps whose text views accept Accessibility writes unreliably or without updating their own
    /// state (browsers, Electron/Chromium apps, terminals). These always use paste.
    private static let pastePreferredBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari", "org.mozilla.firefox",
        "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "com.operasoftware.Opera",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "notion.id", "com.linear", "com.openai.chat", "com.anthropic.claudefordesktop",
        "com.apple.dt.Xcode", "md.obsidian",
    ]

    func insert(_ text: String, target: InsertionTarget, settings: AppSettings) async -> InsertionOutcome {
        guard !text.isEmpty else { return .skipped(reason: "Empty text") }

        guard AXIsProcessTrusted() else {
            copyToClipboard(text)
            return .copiedToClipboard(reason: "Accessibility permission is off, so Dictate cannot type into other apps.")
        }

        if settings.returnToOriginalApp, let app = target.app, !app.isTerminated, !app.isActive {
            app.activate()
            for _ in 0..<20 where !app.isActive { try? await Task.sleep(nanoseconds: 25_000_000) }
            // Give the app a moment to restore its focused field.
            try? await Task.sleep(nanoseconds: 60_000_000)
        }

        if IsSecureEventInputEnabled() {
            // A password field or "Secure Keyboard Entry" blocks synthetic keystrokes.
            copyToClipboard(text)
            return .copiedToClipboard(reason: "Secure input is active (password field or Secure Keyboard Entry).")
        }

        let element = AXHelpers.focusedElement()
        if let element, AXHelpers.isSecure(element) {
            return .skipped(reason: "The focused field is a password field.")
        }

        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? target.bundleID ?? ""
        let isTerminal = Self.terminalBundleIDs.contains(bundleID)
        let output = isTerminal && settings.singleLineInTerminals
            ? text.replacingOccurrences(of: #"\s*[\r\n]+\s*"#, with: " ", options: .regularExpression)
            : text

        if let element, !settings.replaceSelection {
            collapseSelection(element)
        }

        if settings.insertionMethod == .automatic, let element, !isTerminal,
           !Self.pastePreferredBundleIDs.contains(bundleID), !Self.isElectronApp(bundleID: bundleID),
           insertWithAccessibility(output, into: element) {
            return .insertedWithAccessibility
        }

        return await paste(output)
    }

    /// Moves the caret to the end of any selection so dictation does not replace it.
    private func collapseSelection(_ element: AXUIElement) {
        guard let range = AXHelpers.selectedRange(element), range.length > 0 else { return }
        if AXHelpers.isSettable(element, kAXSelectedTextRangeAttribute),
           AXHelpers.setSelectedRange(element, CFRange(location: range.location + range.length, length: 0)) {
            return
        }
        // Right arrow collapses a text selection to its end in standard text views.
        postKey(UInt16(kVK_RightArrow), flags: [])
    }

    /// Only reports success when the field's value demonstrably changed to include the text,
    /// so a silently ignored write falls back to paste instead of losing the dictation.
    private func insertWithAccessibility(_ text: String, into element: AXUIElement) -> Bool {
        let role = AXHelpers.string(element, kAXRoleAttribute) ?? ""
        guard role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String) || role == "AXComboBox",
              AXHelpers.isSettable(element, kAXSelectedTextAttribute),
              let before = AXHelpers.string(element, kAXValueAttribute),
              before.utf16.count < 200_000 else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            return false
        }
        guard let after = AXHelpers.string(element, kAXValueAttribute) else { return false }
        let ok = after != before && after.contains(text)
        if !ok { log.notice("Accessibility insertion not reflected; falling back to paste") }
        return ok
    }

    private static func isElectronApp(bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let frameworks = url.appendingPathComponent("Contents/Frameworks")
        let fm = FileManager.default
        return fm.fileExists(atPath: frameworks.appendingPathComponent("Electron Framework.framework").path)
            || ((try? fm.contentsOfDirectory(atPath: frameworks.path))?.contains { $0.hasSuffix("Chromium Framework.framework") } ?? false)
    }

    // MARK: Paste with clipboard preservation

    private func paste(_ text: String) async -> InsertionOutcome {
        let pasteboard = NSPasteboard.general
        let snapshot = ClipboardSnapshot.capture(pasteboard)

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Conventions (nspasteboard.org) that ask clipboard managers not to record this entry.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pasteboard.writeObjects([item])
        let ourChangeCount = pasteboard.changeCount

        postKey(Self.keyCodeForV(), flags: .maskCommand)

        // Apps read the pasteboard asynchronously after ⌘V; Electron apps can take a while.
        try? await Task.sleep(nanoseconds: 700_000_000)
        if pasteboard.changeCount == ourChangeCount {
            snapshot.restore(to: pasteboard)
        } else {
            // Something else wrote to the clipboard meanwhile; leave it alone.
            log.notice("Clipboard changed during paste; not restoring")
        }
        return .pasted
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Posts a single key press. Flags are set explicitly so held modifiers (e.g. ⌥ from the
    /// shortcut) cannot turn ⌘V into ⌥⌘V. Never posts Return.
    private func postKey(_ keyCode: UInt16, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    /// Key code that types "v" in the current layout (Dvorak etc.), defaulting to ANSI V.
    private static func keyCodeForV() -> UInt16 {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return UInt16(kVK_ANSI_V) }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> UInt16 in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return UInt16(kVK_ANSI_V) }
            for code in UInt16(0)..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
                if status == noErr, length == 1, chars[0] == UniChar(("v" as Unicode.Scalar).value) { return code }
            }
            return UInt16(kVK_ANSI_V)
        }
    }
}
