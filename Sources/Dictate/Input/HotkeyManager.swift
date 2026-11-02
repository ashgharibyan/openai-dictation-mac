import Carbon.HIToolbox
import DictateCore
import Foundation
import os

/// Global shortcuts through Carbon `RegisterEventHotKey`. It delivers both press and release
/// events system-wide, consumes the keystroke (so ⌥Space does not also type a character), and
/// needs no Accessibility or Input Monitoring permission.
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onPress: (() -> Void)?
    var onEscape: (() -> Void)?

    private let log = Logger(subsystem: "local.dictate", category: "hotkey")
    private var handler: EventHandlerRef?
    private var mainRef: EventHotKeyRef?
    private var escapeRef: EventHotKeyRef?
    private(set) var registered: KeyCombo?
    /// Set while the main shortcut is held; filters key-repeat press events.
    private(set) var isDown = false

    private let signature: OSType = 0x4443_5441 // 'DCTA'
    private enum ID: UInt32 { case main = 1, escape = 2 }

    private init() {}

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            manager.handle(id: hotKeyID.id, pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
            return noErr
        }, types.count, &types, selfPtr, &handler)
    }

    private func handle(id: UInt32, pressed: Bool) {
        switch ID(rawValue: id) {
        case .main:
            if pressed {
                guard !isDown else { return }
                isDown = true
                onPress?()
            } else {
                isDown = false
            }
        case .escape:
            if pressed { onEscape?() }
        case nil:
            break
        }
    }

    /// Registers (or replaces) the main shortcut. Returns a user-facing error on failure.
    @discardableResult
    func register(_ combo: KeyCombo) -> String? {
        installHandlerIfNeeded()
        unregister()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: signature, id: ID.main.rawValue),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            log.error("Hotkey registration failed: \(status, privacy: .public)")
            return status == eventHotKeyExistsErr
                ? "\(combo.displayString) is already taken by another app. Choose a different shortcut."
                : "Could not register \(combo.displayString) (error \(status))."
        }
        mainRef = ref
        registered = combo
        return nil
    }

    func unregister() {
        if let mainRef { UnregisterEventHotKey(mainRef) }
        mainRef = nil
        registered = nil
        isDown = false
    }

    /// Escape is only claimed while recording or transcribing, so it never interferes otherwise.
    func setEscapeEnabled(_ enabled: Bool) {
        if enabled, escapeRef == nil {
            installHandlerIfNeeded()
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: signature, id: ID.escape.rawValue),
                                   GetApplicationEventTarget(), 0, &ref) == noErr {
                escapeRef = ref
            }
        } else if !enabled, let escapeRef {
            UnregisterEventHotKey(escapeRef)
            self.escapeRef = nil
        }
    }

}
