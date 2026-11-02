import AppKit
import DictateCore
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let controller: DictationController

    init(controller: DictationController) { self.controller = controller }

    func show(tab: SettingsTab = .general) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(controller: controller, initialTab: tab))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Dictate Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 640, height: 560))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsTab: Hashable { case general, shortcut, openAI, transcription, privacy, usage }

struct SettingsView: View {
    @ObservedObject var controller: DictationController
    @State var initialTab: SettingsTab

    var body: some View {
        TabView(selection: $initialTab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            ShortcutSettings(controller: controller).tabItem { Label("Shortcut", systemImage: "keyboard") }.tag(SettingsTab.shortcut)
            OpenAISettings().tabItem { Label("OpenAI", systemImage: "key") }.tag(SettingsTab.openAI)
            TranscriptionSettings().tabItem { Label("Transcription", systemImage: "text.bubble") }.tag(SettingsTab.transcription)
            PrivacySettings().tabItem { Label("Privacy", systemImage: "hand.raised") }.tag(SettingsTab.privacy)
            UsageSettings().tabItem { Label("Usage", systemImage: "chart.bar") }.tag(SettingsTab.usage)
        }
        .frame(width: 640, height: 560)
    }
}

// MARK: General

struct GeneralSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var micStatus = Permissions.microphone
    @State private var axTrusted = Permissions.accessibilityTrusted
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Permissions") {
                PermissionRow(title: "Microphone", granted: micStatus == .authorized,
                              detail: "Needed to record your voice. Audio is only captured while you hold or toggle the shortcut.") {
                    if micStatus == .notDetermined {
                        Task { _ = await Permissions.requestMicrophone(); micStatus = Permissions.microphone }
                    } else {
                        Permissions.openMicrophoneSettings()
                    }
                }
                PermissionRow(title: "Accessibility", granted: axTrusted,
                              detail: "Needed to type the transcript into other apps (Accessibility insertion and simulated ⌘V). Without it, text is copied to the clipboard instead.") {
                    Permissions.promptForAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            }
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do { try LaunchAtLogin.set(enabled); launchError = nil }
                        catch { launchError = error.localizedDescription; launchAtLogin = LaunchAtLogin.isEnabled }
                    }
                if let launchError { Text(launchError).font(.caption).foregroundStyle(.red) }
                if LaunchAtLogin.needsApproval {
                    Button("Approve in Login Items…") { Permissions.openLoginItemsSettings() }
                }
                Toggle("Show floating recording indicator", isOn: $settings.showHUD)
                Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
                if !settings.showMenuBarIcon {
                    Text("To get back here with the icon hidden, open Dictate again from Applications or Spotlight.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Play sounds", isOn: $settings.playSounds)
            }
            Section("Notifications") {
                Toggle("Notify when dictation fails or text could not be inserted", isOn: $settings.notifyOnError)
                Toggle("Notify after each successful dictation", isOn: $settings.notifyOnSuccess)
            }
            .onChange(of: settings.notifyOnError) { _, on in if on { Notifier.requestAuthorization() } }
            .onChange(of: settings.notifyOnSuccess) { _, on in if on { Notifier.requestAuthorization() } }
            Section("Text insertion") {
                Picker("Method", selection: $settings.insertionMethod) {
                    ForEach(InsertionMethod.allCases) { Text($0.title).tag($0) }
                }
                Text("Automatic writes directly into native Mac text fields through Accessibility when the change can be verified, and pastes everywhere else (browsers, Electron apps, terminals). Paste restores your previous clipboard afterwards.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Return to the app I was in when recording started", isOn: $settings.returnToOriginalApp)
                Toggle("Replace selected text", isOn: $settings.replaceSelection)
                Toggle("Join lines into one in terminal apps", isOn: $settings.singleLineInTerminals)
            }
        }
        .formStyle(.grouped)
        .onReceive(refresh) { _ in
            micStatus = Permissions.microphone
            axTrusted = Permissions.accessibilityTrusted
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Grant…", action: action) }
        }
    }
}

// MARK: Shortcut

struct ShortcutSettings: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Tap to start, tap again to stop") {
                Picker("Tap key", selection: $settings.tapKey) {
                    ForEach(ModifierKey.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.tapKey) { _, _ in controller.applyModifierKeys() }
                Text("Tap once and speak hands-free; tap again to transcribe. A tap only counts when the key is pressed on its own and released quickly, so ⌘C, ⌘-click and other shortcuts don't trigger it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Hold to talk") {
                Picker("Hold key", selection: $settings.holdKey) {
                    ForEach(ModifierKey.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.holdKey) { _, _ in controller.applyModifierKeys() }
                Text(settings.holdKey != .off && settings.holdKey == settings.tapKey
                     ? "Same key for both: a quick tap starts hands-free recording, and holding records until you let go."
                     : "Hold the key while you speak, and let go to transcribe. A quick tap, or using the key in a shortcut like ⌥←, is ignored.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Modifier keys on their own type nothing, so they never add characters to your text.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.tapKey == .fn || settings.holdKey == .fn {
                    Text("Set System Settings → Keyboard → \"Press 🌐 key to\" to \"Do Nothing\", or macOS will also react to fn.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !Permissions.accessibilityTrusted {
                    Label("These keys need the Accessibility permission (General tab) to work while you are in other apps.",
                          systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            Section("Key combination (optional)") {
                Toggle("Also use a key combination to start and stop", isOn: $settings.comboEnabled)
                    .onChange(of: settings.comboEnabled) { _, _ in controller.registerHotkey() }
                LabeledContent("Shortcut") {
                    ShortcutRecorder(combo: $settings.hotkey,
                                     onBegin: { controller.suspendHotkey() },
                                     onEnd: { controller.registerHotkey() })
                }
                if let error = controller.hotkeyError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                let conflicts = SystemShortcutConflicts.conflicts(
                    for: settings.hotkey,
                    in: UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:])
                if !conflicts.isEmpty {
                    Label("Also used by macOS: \(conflicts.joined(separator: ", ")). Disable it in System Settings → Keyboard → Keyboard Shortcuts, or pick another shortcut.",
                          systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                let hints = SystemShortcutConflicts.commonAppHints(for: settings.hotkey)
                if !hints.isEmpty {
                    Text("Often also used by: \(hints.joined(separator: ", ")). If one of these is installed and claims the shortcut first, Dictate shows an error here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Reset to ⌥Space") {
                    settings.hotkey = .default
                    controller.registerHotkey()
                }
                .disabled(!settings.comboEnabled)
            }
            Section("Recording") {
                Text("Press Esc while recording or transcribing to cancel. Esc is only captured during those moments.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Maximum recording length: \(settings.maxRecordingMinutes) min",
                        value: $settings.maxRecordingMinutes, in: 1...30)
            }
        }
        .formStyle(.grouped)
    }
}

/// Click, then press the new key combination. Esc cancels.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo
    let onBegin: () -> Void
    let onEnd: () -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(recording ? "Press shortcut… (Esc to cancel)" : combo.displayString) {
                recording ? stop() : start()
            }
            .frame(minWidth: 180)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onDisappear { if recording { stop() } }
    }

    private func start() {
        error = nil
        recording = true
        onBegin()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(KeyCombo.escapeKey) && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stop()
                return nil
            }
            let candidate = KeyCombo(keyCode: UInt32(event.keyCode),
                                     modifiers: KeyCombo.carbonModifiers(fromCocoa: event.modifierFlags.rawValue))
            if let problem = candidate.validationError {
                error = problem
            } else {
                combo = candidate
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        onEnd()
    }
}

// MARK: OpenAI

struct OpenAISettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var keyInput = ""
    @State private var storedKey = KeychainStore.loadAPIKey()
    @State private var status: String?
    @State private var statusOK = false
    @State private var validating = false

    var body: some View {
        Form {
            Section("API key") {
                if let storedKey {
                    LabeledContent("Saved key", value: KeychainStore.masked(storedKey))
                }
                SecureField("sk-…", text: $keyInput)
                HStack {
                    Button("Paste & Save") {
                        if let pasted = NSPasteboard.general.string(forType: .string) {
                            keyInput = pasted
                            save()
                        }
                    }
                    Button("Save to Keychain") { save() }.disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Validate") { Task { await validate() } }.disabled(storedKey == nil || validating)
                    if storedKey != nil {
                        Button("Remove", role: .destructive) {
                            KeychainStore.deleteAPIKey()
                            storedKey = nil
                            status = nil
                        }
                    }
                    if validating { ProgressView().controlSize(.small) }
                }
                if let status {
                    Label(status, systemImage: statusOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(statusOK ? .green : .red)
                }
                Text("Stored in your macOS login Keychain. It is sent only to api.openai.com over HTTPS and never logged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Transcription model") {
                Picker("Model", selection: $settings.modelID) {
                    ForEach(TranscriptionModel.all) { model in
                        Text(model.displayName + (model.deprecationNote == nil ? "" : " (deprecated)")).tag(model.id)
                    }
                }
                let model = settings.model
                Text(String(format: "Estimated $%.4f per minute of audio.", model.usdPerMinute)
                     + (model.deprecationNote.map { " \($0)." } ?? "")
                     + (model.supportsKeywords ? "" : " This model has no keywords field; vocabulary is added to the prompt instead."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = KeychainStore.saveAPIKey(key)
        if result == errSecSuccess {
            storedKey = key
            keyInput = ""
            Task { await validate() }
        } else {
            status = "Keychain error \(result)"
            statusOK = false
        }
    }

    private func validate() async {
        guard let key = storedKey else { return }
        validating = true
        defer { validating = false }
        do {
            try await OpenAIClient().validate(apiKey: key)
            status = "Connected – key is valid."
            statusOK = true
        } catch let error as TranscriptionError {
            status = error.userMessage
            statusOK = false
        } catch {
            status = error.localizedDescription
            statusOK = false
        }
    }
}

// MARK: Transcription

struct TranscriptionSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Language") {
                Toggle("Detect language automatically", isOn: $settings.autoDetectLanguage)
                TextField("Expected languages (ISO-639-1, comma separated)", text: $settings.languagesText)
                    .disabled(settings.autoDetectLanguage)
                Text("Default \"en\". Add more codes (for example \"es\" or \"de\") if you mix languages. GPT-Transcribe accepts several hints; older models use one or auto-detect.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Context prompt") {
                TextEditor(text: $settings.contextPrompt)
                    .font(.body)
                    .frame(height: 70)
                Text("Describes the speaker and topics so the model can resolve ambiguous words. It is context only; it is not inserted into your text.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Restore default") { settings.contextPrompt = AppSettings.defaultPrompt }
            }
            Section("Vocabulary (keywords)") {
                TextEditor(text: $settings.keywordsText)
                    .font(.body.monospaced())
                    .frame(height: 110)
                Text("One term per line. Sent as keyword hints: they help spelling when the word is spoken and are not forced into the transcript.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Output") {
                Picker("Mode", selection: $settings.outputMode) {
                    ForEach(OutputMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(settings.outputMode.explanation).font(.caption).foregroundStyle(.secondary)
                if settings.outputMode == .polished {
                    TextField("Text model", text: $settings.polishModelID)
                    Text(String(format: "Extra cost: about $%.2f / $%.2f per million input / output tokens for %@ — roughly $0.0001 per typical dictation. The transcript is sent with store=false.",
                                settings.polishModel.usdPerMillionInput, settings.polishModel.usdPerMillionOutput, PolishModel.default.id))
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Privacy

struct PrivacySettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var history = HistoryStore.shared

    var body: some View {
        Form {
            Section("Retention") {
                Toggle("Keep transcript history (last 50, stored on this Mac)", isOn: $settings.keepTranscriptHistory)
                    .onChange(of: settings.keepTranscriptHistory) { _, on in if !on { history.clear() } }
                Toggle("Keep audio recordings after successful transcription", isOn: $settings.keepAudioHistory)
                Text("By default, each recording is deleted as soon as its text is inserted. A recording is only kept when transcription fails, so you can retry it; kept recordings are deleted after 24 hours or when you discard them.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show recordings folder in Finder") { NSWorkspace.shared.open(AppPaths.support) }
            }
            Section("Data flow") {
                Text("Audio goes only to api.openai.com/v1/audio/transcriptions. In Polished mode the transcript text also goes to api.openai.com/v1/responses. There is no other server, no analytics and no telemetry. Logs never contain your key, audio or transcripts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if settings.keepTranscriptHistory {
                Section("History") {
                    if history.entries.isEmpty {
                        Text("No transcripts yet.").foregroundStyle(.secondary)
                    }
                    ForEach(history.entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.text).textSelection(.enabled).lineLimit(4)
                            Text("\(entry.date.formatted(date: .abbreviated, time: .shortened))\(entry.appName.map { " · \($0)" } ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !history.entries.isEmpty {
                        Button("Clear history", role: .destructive) { history.clear() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Usage

struct UsageSettings: View {
    @ObservedObject private var usage = UsageStore.shared

    var body: some View {
        let u = usage.current
        Form {
            Section("This month (\(u.month))") {
                LabeledContent("Recorded audio transcribed", value: String(format: "%.1f min", u.recordedSeconds / 60))
                LabeledContent("Successful transcriptions", value: "\(u.successCount)")
                LabeledContent("Failed attempts", value: "\(u.failureCount)")
                LabeledContent("Average transcription time", value: String(format: "%.2f s", u.averageTranscriptionSeconds))
                LabeledContent("Estimated transcription cost", value: String(format: "$%.4f", u.estimatedTranscriptionUSD))
                LabeledContent("Estimated Polished-mode cost", value: String(format: "$%.4f", u.estimatedPolishUSD))
                LabeledContent("Estimated total", value: String(format: "$%.4f", u.estimatedTotalUSD))
            }
            Section {
                Text("Estimates use OpenAI's published prices (GPT-Transcribe: $0.0045 per minute) and the audio length measured on this Mac. They count only requests that returned a transcript. OpenAI's own rounding and any failed requests it billed are not reflected, so your actual bill can differ. See platform.openai.com/usage for billed amounts.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open OpenAI usage dashboard") { NSWorkspace.shared.open(URL(string: "https://platform.openai.com/usage")!) }
                    Button("Reset counters", role: .destructive) { usage.reset() }
                }
            }
        }
        .formStyle(.grouped)
    }
}
