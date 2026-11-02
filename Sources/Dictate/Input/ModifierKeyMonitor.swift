import AppKit
import CoreGraphics

/// A single modifier key used as a dictation trigger. A modifier on its own types nothing,
/// so tapping or holding it never inserts characters into the app you are using.
enum ModifierKey: String, CaseIterable, Identifiable {
    case rightOption, rightCommand, rightControl, fn, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: return "Right ⌥ Option"
        case .rightCommand: return "Right ⌘ Command"
        case .rightControl: return "Right ⌃ Control"
        case .fn: return "fn / 🌐"
        case .off: return "Off"
        }
    }

    var shortName: String {
        switch self {
        case .rightOption: return "Right ⌥"
        case .rightCommand: return "Right ⌘"
        case .rightControl: return "Right ⌃"
        case .fn: return "fn"
        case .off: return ""
        }
    }

    fileprivate var keyCode: UInt16? {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .fn: return 63
        case .off: return nil
        }
    }

    /// Device-dependent flag bits (IOLLEvent.h) that tell the right-hand key from the left one.
    fileprivate var deviceMask: UInt64 {
        switch self {
        case .rightOption: return 0x40       // NX_DEVICERALTKEYMASK
        case .rightCommand: return 0x10      // NX_DEVICERCMDKEYMASK
        case .rightControl: return 0x2000    // NX_DEVICERCTLKEYMASK
        case .fn: return CGEventFlags.maskSecondaryFn.rawValue
        case .off: return 0
        }
    }
}

/// Watches modifier keys system-wide via NSEvent monitors. Global monitors only receive events
/// once Dictate is trusted for Accessibility (which text insertion needs anyway).
@MainActor
final class ModifierKeyMonitor {
    var onDown: ((ModifierKey) -> Void)?
    var onUp: ((ModifierKey) -> Void)?
    /// Something else happened while a watched key was down (another key, a click), meaning the
    /// modifier was being used normally, e.g. ⌘C or ⌘-click.
    var onInterrupted: (() -> Void)?

    private var keys: Set<ModifierKey> = []
    private var monitors: [Any] = []
    private(set) var down: Set<ModifierKey> = []

    func start(_ keys: Set<ModifierKey>) {
        stop()
        self.keys = keys.subtracting([.off])
        guard !self.keys.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) { monitors.append(local) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        down = []
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .flagsChanged else {
            if !down.isEmpty { onInterrupted?() }
            return
        }
        guard let key = keys.first(where: { $0.keyCode == event.keyCode }) else {
            // Another modifier pressed alongside (e.g. Right ⌘ + ⇧): a shortcut, not dictation.
            if !down.isEmpty { onInterrupted?() }
            return
        }
        let isDown = UInt64(event.modifierFlags.rawValue) & key.deviceMask != 0
        guard isDown != down.contains(key) else { return }
        if isDown {
            down.insert(key)
            onDown?(key)
        } else {
            down.remove(key)
            onUp?(key)
        }
    }

    /// Current physical state, used to recover from a missed key-up.
    func isPhysicallyDown(_ key: ModifierKey) -> Bool {
        guard key != .off else { return false }
        return CGEventSource.flagsState(.combinedSessionState).rawValue & key.deviceMask != 0
    }

    /// Forgets a key whose release was missed and recovered by polling.
    func forget(_ key: ModifierKey) { down.remove(key) }
}
