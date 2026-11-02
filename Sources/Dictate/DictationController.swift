import AppKit
import AVFoundation
import DictateCore
import os

/// Owns the dictation lifecycle: Idle → Recording → Transcribing → Inserting → Idle.
/// Every transition goes through `DictationStateMachine`, which rejects overlapping sessions
/// and duplicate transcription requests.
@MainActor
final class DictationController: ObservableObject {
    @Published private(set) var phase: DictationPhase = .idle
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 28)
    /// Detail line for the HUD and menu (error text, "Copied – press ⌘V", …).
    @Published private(set) var message: String?
    /// A failed recording kept on disk for an explicit Retry or Discard.
    @Published private(set) var pending: PendingRecording?
    /// Last transcript, in memory only (never written to disk unless history is enabled).
    @Published private(set) var lastTranscript: String?
    @Published private(set) var hotkeyError: String?

    let settings = AppSettings.shared
    private let usage = UsageStore.shared
    private let history = HistoryStore.shared
    private let recorder = AudioRecorder()
    private let client = OpenAIClient()
    private let inserter = TextInserter()
    private let hotkeys = HotkeyManager.shared
    private let keyMonitor = ModifierKeyMonitor()
    private let log = Logger(subsystem: "local.dictate", category: "controller")

    private var target: InsertionTarget?
    private var currentFileName: String?
    private var transcriptionTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var watchdog: Timer?
    private var trustTimer: Timer?
    private var maxDurationTimer: Timer?
    private var keySeenDown = false
    private var releaseMisses = 0

    static let minimumDuration: Double = 0.35
    /// Below this peak level (dBFS) the recording is treated as silence and not sent.
    static let silenceThreshold: Float = -58

    init() {
        pending = PendingRecording.restoreOnLaunch()
        recorder.onLevel = { [weak self] level in self?.pushLevel(level) }
        recorder.onInterrupted = { [weak self] in
            self?.stopRecording(note: "Microphone disconnected – transcribing what was captured.")
        }
        recorder.onDeviceSwitched = { [weak self] in self?.message = "Switched to the new input device." }
        hotkeys.onPress = { [weak self] in self?.togglePressed() }
        hotkeys.onEscape = { [weak self] in self?.cancel() }
        keyMonitor.onDown = { [weak self] key in self?.modifierDown(key) }
        keyMonitor.onUp = { [weak self] key in self?.modifierUp(key) }
        keyMonitor.onInterrupted = { [weak self] in self?.modifierInterrupted() }
        registerHotkey()
        applyModifierKeys()
        // System-wide key monitors only start working once Accessibility is granted, and a monitor
        // added before the grant stays deaf, so re-install it when the grant appears.
        var wasTrusted = Permissions.accessibilityTrusted
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let trusted = Permissions.accessibilityTrusted
                if trusted && !wasTrusted { self?.applyModifierKeys() }
                wasTrusted = trusted
            }
        }
    }

    // MARK: Shortcuts
    //
    // Tap key (default Right ⌘): tap to start, tap again to stop.
    // Hold key (default Right ⌥): hold while speaking, release to transcribe.
    // Same key for both: a quick tap starts hands-free recording, holding records until release.
    // Optional key combination (Carbon hotkey, off by default): press to start, press again to stop.

    /// Releases shorter than this count as a tap rather than a hold.
    static let tapThreshold: TimeInterval = 0.4

    private var keyDownAt: [ModifierKey: Date] = [:]
    private var keyInterrupted = false
    private var ignoreNextUp: ModifierKey?

    func registerHotkey() {
        if settings.comboEnabled {
            hotkeyError = hotkeys.register(settings.hotkey)
        } else {
            hotkeys.unregister()
            hotkeyError = nil
        }
    }

    func applyModifierKeys() {
        keyMonitor.start([settings.holdKey, settings.tapKey])
    }

    /// Used while the shortcut recorder in Settings is capturing keys.
    func suspendHotkey() { hotkeys.unregister() }

    private func togglePressed() {
        if phase == .recording { stopRecording() } else { startRecording(trigger: .tap) }
    }

    private func modifierDown(_ key: ModifierKey) {
        keyDownAt[key] = Date()
        keyInterrupted = false
        if phase == .recording {
            // Second tap of a hands-free recording: stop right away, and ignore this key's release.
            if trigger == .tap && key == settings.tapKey {
                ignoreNextUp = key
                stopRecording()
            }
            return
        }
        if key == settings.holdKey { startRecording(trigger: .hold) }
    }

    private func modifierUp(_ key: ModifierKey) {
        let held = keyDownAt.removeValue(forKey: key).map { Date().timeIntervalSince($0) } ?? .infinity
        if ignoreNextUp == key {
            ignoreNextUp = nil
            return
        }
        let isTap = held < Self.tapThreshold && !keyInterrupted

        if phase == .recording && trigger == .hold && key == settings.holdKey {
            if isTap && key == settings.tapKey {
                switchToHandsFree()
            } else if held < Self.tapThreshold {
                // A quick tap of a hold-only key is not dictation: drop it quietly.
                cancel()
            } else {
                stopRecording()
            }
            return
        }
        if key == settings.tapKey && isTap && phase != .recording {
            startRecording(trigger: .tap)
        }
    }

    /// Another key or a click happened while a trigger key was down (⌘C, ⌘-click, ⌥←…):
    /// the modifier was being used normally, so it is not a tap, and a just-started hold is dropped.
    private func modifierInterrupted() {
        keyInterrupted = true
        if phase == .recording, trigger == .hold, let start = recordingStartedAt,
           Date().timeIntervalSince(start) < 1 {
            cancel()
        }
    }

    private func switchToHandsFree() {
        trigger = .tap
        watchdog?.invalidate()
        watchdog = nil
        message = "Hands-free – tap \(settings.tapKey.shortName) again to stop"
    }

    /// Menu / HUD action.
    func toggleFromUI() {
        if phase == .recording { stopRecording() } else { startRecording(trigger: .tap) }
    }

    // MARK: Recording

    private enum Trigger { case hold, tap }
    private var trigger: Trigger = .tap

    private func startRecording(trigger: Trigger) {
        guard DictationStateMachine.next(phase, .start) != nil else {
            if trigger == .tap, phase == .transcribing || phase == .inserting { NSSound.beep() }
            return
        }
        guard KeychainStore.loadAPIKey() != nil else {
            fail("Add your OpenAI API key in Settings → OpenAI.")
            return
        }
        switch Permissions.microphone {
        case .authorized:
            break
        case .notDetermined:
            Task {
                let granted = await Permissions.requestMicrophone()
                self.message = granted ? "Microphone enabled. Press the shortcut again to dictate." : nil
                if !granted { self.fail("Microphone access was denied.") }
            }
            return
        default:
            fail("Microphone access is off. Enable Dictate in System Settings → Privacy & Security → Microphone.")
            return
        }

        target = InsertionTarget.capture()
        let fileName = UUID().uuidString + ".m4a"
        do {
            try recorder.start(to: AppPaths.recordings.appendingPathComponent(fileName))
        } catch {
            fail(error.localizedDescription)
            return
        }
        currentFileName = fileName
        settleTask?.cancel()
        message = nil
        levels = Array(repeating: 0, count: levels.count)
        recordingStartedAt = Date()
        transition(.start)
        play("Tink")
        self.trigger = trigger
        startTimers()
    }

    private func startTimers() {
        keySeenDown = false
        releaseMisses = 0
        if trigger == .hold {
            // Recovers if the key-up event is lost (e.g. secure input briefly grabbed the keyboard).
            watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkHoldKeyStillDown() }
            }
        }
        let limit = TimeInterval(settings.maxRecordingMinutes * 60)
        let minutes = settings.maxRecordingMinutes
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: limit, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording(note: "Reached the \(minutes)-minute limit.") }
        }
    }

    private func checkHoldKeyStillDown() {
        guard phase == .recording, trigger == .hold else { return }
        if keyMonitor.isPhysicallyDown(settings.holdKey) {
            keySeenDown = true
            releaseMisses = 0
        } else if keySeenDown {
            // Only trusted after the key was seen down once, so a key state we cannot read never stops a recording.
            releaseMisses += 1
            if releaseMisses >= 3 {
                log.notice("Recovered from a missed shortcut release")
                keyMonitor.forget(settings.holdKey)
                stopRecording()
            }
        }
    }

    private func stopTimers() {
        watchdog?.invalidate()
        watchdog = nil
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
    }

    func stopRecording(note: String? = nil) {
        guard phase == .recording else { return }
        stopTimers()
        recordingStartedAt = nil
        guard let result = recorder.stop(), let fileName = currentFileName else {
            transition(.audioUnusable)
            showMessage("The recording could not be saved.", isError: true)
            return
        }
        currentFileName = nil
        if result.duration < Self.minimumDuration {
            try? FileManager.default.removeItem(at: result.url)
            transition(.audioUnusable)
            showMessage("Recording was too short.", isError: true)
            return
        }
        if result.peakDecibels < Self.silenceThreshold {
            try? FileManager.default.removeItem(at: result.url)
            transition(.audioUnusable)
            showMessage("No sound was picked up. Check the input device in System Settings → Sound.", isError: true)
            return
        }
        play("Pop")
        let job = PendingRecording(fileName: fileName, duration: result.duration, createdAt: Date())
        // Written before the request so a crash or quit still leaves a retryable recording.
        job.saveMetadata()
        transition(.stop)
        message = note
        startTranscription(job, target: target ?? InsertionTarget(app: nil, element: nil))
    }

    func cancel() {
        switch phase {
        case .recording:
            stopTimers()
            recordingStartedAt = nil
            recorder.stop(discard: true)
            currentFileName = nil
            transition(.cancel)
        case .transcribing:
            // The task observes cancellation and removes the recording.
            transcriptionTask?.cancel()
            transition(.cancel)
        case .success, .error:
            transition(.cancel)
        default:
            break
        }
    }

    // MARK: Transcription

    func retryPending() {
        guard let job = pending, DictationStateMachine.next(phase, .retry) != nil else { return }
        pending = nil
        transition(.retry)
        message = nil
        // Inserts wherever the cursor is now; the menu and HUD do not take focus.
        startTranscription(job, target: InsertionTarget.capture())
    }

    func discardPending() {
        pending?.delete()
        pending = nil
        if phase == .error { transition(.cancel) }
    }

    func copyLastTranscript() {
        if let lastTranscript { inserter.copyToClipboard(lastTranscript) }
    }

    private func startTranscription(_ job: PendingRecording, target: InsertionTarget) {
        transcriptionTask = Task { [weak self] in
            await self?.transcribe(job, target: target)
        }
    }

    private func transcribe(_ job: PendingRecording, target: InsertionTarget) async {
        guard let apiKey = KeychainStore.loadAPIKey() else {
            handleFailure(.missingAPIKey, job: job)
            return
        }
        let options = settings.transcriptionOptions
        let result: OpenAIClient.TranscriptionResult
        do {
            result = try await client.transcribe(fileURL: job.url, audioSeconds: job.duration, options: options, apiKey: apiKey)
        } catch let error as TranscriptionError {
            handleFailure(error, job: job)
            return
        } catch {
            handleFailure(.network(error.localizedDescription), job: job)
            return
        }
        usage.update { $0.recordRequest(audioSeconds: job.duration, model: options.model) }

        let raw = result.response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            handleFailure(.emptyTranscript, job: job)
            return
        }
        guard phase == .transcribing else {
            // Cancelled after the response arrived: keep the text reachable, insert nothing.
            lastTranscript = raw
            job.delete()
            return
        }

        var note: String?
        var text: String
        switch settings.outputMode {
        case .verbatim:
            text = raw
        case .clean:
            text = TextCleaner.clean(raw)
        case .polished:
            text = TextCleaner.clean(raw)
            message = "Polishing…"
            do {
                let polished = try await client.polish(raw, model: settings.polishModel, apiKey: apiKey)
                usage.update { $0.recordPolish(inputTokens: polished.inputTokens, outputTokens: polished.outputTokens, model: self.settings.polishModel) }
                if PolishGuard.isAcceptable(original: raw, polished: polished.text) {
                    text = polished.text
                } else {
                    note = "Polished text looked altered; inserted Clean text instead."
                }
            } catch {
                note = "Polishing failed; inserted Clean text instead."
            }
            guard phase == .transcribing else { lastTranscript = text; job.delete(); return }
        }
        text = TextCleaner.prepareForInsertion(text, singleLine: false)
        lastTranscript = text

        transition(.transcribed)
        let outcome = await inserter.insert(text, target: target, settings: settings)

        usage.update { $0.recordSuccess(audioSeconds: job.duration, latency: result.latency) }
        if settings.keepTranscriptHistory { history.add(text, appName: target.appName) }
        if settings.keepAudioHistory { job.archive() } else { job.delete() }

        switch outcome {
        case .insertedWithAccessibility, .pasted:
            message = note
            transition(.inserted)
            if settings.notifyOnSuccess { Notifier.post(title: "Dictation inserted", body: "\(TextCleaner.wordCount(text)) words") }
        case .copiedToClipboard(let reason), .skipped(let reason):
            message = "\(outcome.summary). \(reason)"
            transition(.inserted)
            if settings.notifyOnError { Notifier.post(title: "Dictate: \(outcome.summary)", body: reason) }
        }
    }

    private func handleFailure(_ error: TranscriptionError, job: PendingRecording) {
        if error == .cancelled {
            job.delete()
            return
        }
        usage.update { $0.recordFailure() }
        log.error("Transcription failed: \(String(describing: error), privacy: .private)")
        var text = error.userMessage
        if error.isRetryableLater {
            var kept = job
            kept.lastError = error.userMessage
            kept.saveMetadata()
            pending = kept
            text += " Your recording is kept – choose Retry."
        } else {
            job.delete()
        }
        if phase == .transcribing { transition(.failed) }
        showMessage(text, isError: true)
    }

    // MARK: State

    private func fail(_ text: String) {
        if transition(.failed) { showMessage(text, isError: true) }
    }

    private func showMessage(_ text: String, isError: Bool) {
        message = text
        if isError {
            play("Basso")
            if settings.notifyOnError { Notifier.post(title: "Dictate", body: text) }
        }
    }

    @discardableResult
    private func transition(_ event: DictationEvent) -> Bool {
        guard let next = DictationStateMachine.next(phase, event) else {
            log.debug("Ignored event \(String(describing: event), privacy: .public) in \(String(describing: self.phase), privacy: .public)")
            return false
        }
        phase = next
        hotkeys.setEscapeEnabled(next == .recording || next == .transcribing)
        scheduleSettle(for: next)
        return true
    }

    private func scheduleSettle(for phase: DictationPhase) {
        settleTask?.cancel()
        let delay: Double
        switch phase {
        case .success: delay = message == nil ? 1.0 : 4.0
        case .error: delay = pending == nil ? 4.0 : 8.0
        default: return
        }
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.phase == phase else { return }
            self.transition(.settle)
            self.message = nil
        }
    }

    private func pushLevel(_ level: Float) {
        guard phase == .recording else { return }
        levels.removeFirst()
        levels.append(level)
    }

    private func play(_ name: String) {
        guard settings.playSounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
