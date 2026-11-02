import AppKit
import Combine
import DictateCore

/// Menu bar icon and menu. The icon reflects Idle / Recording / Transcribing / Success / Error.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: DictationController
    private let openSettings: () -> Void
    private var cancellables = Set<AnyCancellable>()

    init(controller: DictationController, openSettings: @escaping () -> Void) {
        self.controller = controller
        self.openSettings = openSettings
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.toolTip = "Dictate"
        controller.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.updateIcon(phase) }
            .store(in: &cancellables)
        controller.settings.$showMenuBarIcon
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in self?.statusItem.isVisible = visible }
            .store(in: &cancellables)
    }

    private func updateIcon(_ phase: DictationPhase) {
        let (symbol, color): (String, NSColor?) = switch phase {
        case .idle: ("mic", nil)
        case .recording: ("mic.fill", .systemRed)
        case .transcribing, .inserting: ("waveform", nil)
        case .success: ("checkmark.circle", nil)
        case .error: ("exclamationmark.triangle", .systemOrange)
        }
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Dictate: \(phase)")
        if let color {
            image = image?.withSymbolConfiguration(.init(paletteColors: [color]))
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = controller.settings
        let shortcut = settings.hotkey.displayString

        menu.addItem(disabled(statusLine))
        if let error = controller.hotkeyError {
            menu.addItem(disabled("⚠︎ \(error)"))
        }
        menu.addItem(.separator())

        let title = controller.phase == .recording ? "Stop Dictation" : "Start Dictation"
        let start = item(title, #selector(toggleDictation))
        start.toolTip = "Shortcut: \(shortcut)"
        start.isEnabled = !(controller.phase == .transcribing || controller.phase == .inserting)
        menu.addItem(start)
        if controller.phase == .recording || controller.phase == .transcribing {
            menu.addItem(item("Cancel", #selector(cancel)))
        }

        if let pending = controller.pending {
            menu.addItem(.separator())
            let seconds = Int(pending.duration.rounded())
            menu.addItem(disabled("Failed recording (\(seconds)s) kept"))
            if let error = pending.lastError { menu.addItem(disabled(error)) }
            let retry = item("Retry Transcription", #selector(retry))
            retry.isEnabled = DictationStateMachine.next(controller.phase, .retry) != nil
            menu.addItem(retry)
            menu.addItem(item("Discard Recording", #selector(discard)))
        }

        if controller.lastTranscript != nil {
            menu.addItem(.separator())
            menu.addItem(item("Copy Last Transcript", #selector(copyLast)))
        }

        menu.addItem(.separator())
        let usage = UsageStore.shared.current
        menu.addItem(disabled(String(format: "This month: %.1f min · %d dictations · ~$%.2f est.",
                                     usage.recordedSeconds / 60, usage.successCount, usage.estimatedTotalUSD)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(item("Quit Dictate", #selector(quit), key: "q"))
    }

    private var statusLine: String {
        switch controller.phase {
        case .idle:
            return controller.settings.shortcutSummary
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .inserting: return "Inserting…"
        case .success: return controller.message ?? "Inserted"
        case .error: return controller.message ?? "Error"
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleDictation() { controller.toggleFromUI() }
    @objc private func cancel() { controller.cancel() }
    @objc private func retry() { controller.retryPending() }
    @objc private func discard() { controller.discardPending() }
    @objc private func copyLast() { controller.copyLastTranscript() }
    @objc private func showSettings() { openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}
