import Combine
import DictateCore
import Foundation

enum InsertionMethod: String, CaseIterable, Identifiable {
    /// Accessibility insertion for native text fields, paste everywhere else.
    case automatic
    case alwaysPaste
    var id: String { rawValue }
    var title: String { self == .automatic ? "Automatic" : "Always paste" }
}

/// All user preferences, persisted in UserDefaults. The API key is NOT here; it lives in the Keychain.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    static let defaultPrompt = "Dictation in conversational English. It may include software development terms, product names and technical jargon."
    static let defaultKeywords = ["OpenAI", "ChatGPT", "Claude Code", "Cursor", "GitHub", "Python", "JavaScript", "TypeScript", "Swift", "API", "LLM"]

    // General
    @Published var showHUD: Bool { didSet { defaults.set(showHUD, forKey: "showHUD") } }
    @Published var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    @Published var notifyOnError: Bool { didSet { defaults.set(notifyOnError, forKey: "notifyOnError") } }
    @Published var notifyOnSuccess: Bool { didSet { defaults.set(notifyOnSuccess, forKey: "notifyOnSuccess") } }

    // Shortcut
    /// Tap to start, tap again to stop.
    @Published var tapKey: ModifierKey { didSet { defaults.set(tapKey.rawValue, forKey: "tapKey") } }
    /// Hold to talk, release to transcribe.
    @Published var holdKey: ModifierKey { didSet { defaults.set(holdKey.rawValue, forKey: "holdKey") } }
    /// Optional key combination (press to start, press again to stop). Off by default.
    @Published var comboEnabled: Bool { didSet { defaults.set(comboEnabled, forKey: "comboEnabled") } }
    @Published var hotkey: KeyCombo { didSet { defaults.set(try? JSONEncoder().encode(hotkey), forKey: "hotkey") } }
    @Published var maxRecordingMinutes: Int { didSet { defaults.set(maxRecordingMinutes, forKey: "maxRecordingMinutes") } }

    // OpenAI
    @Published var modelID: String { didSet { defaults.set(modelID, forKey: "modelID") } }

    // Transcription
    @Published var languagesText: String { didSet { defaults.set(languagesText, forKey: "languagesText") } }
    @Published var autoDetectLanguage: Bool { didSet { defaults.set(autoDetectLanguage, forKey: "autoDetectLanguage") } }
    @Published var contextPrompt: String { didSet { defaults.set(contextPrompt, forKey: "contextPrompt") } }
    @Published var keywordsText: String { didSet { defaults.set(keywordsText, forKey: "keywordsText") } }
    @Published var outputMode: OutputMode { didSet { defaults.set(outputMode.rawValue, forKey: "outputMode") } }
    @Published var polishModelID: String { didSet { defaults.set(polishModelID, forKey: "polishModelID") } }

    // Insertion
    @Published var insertionMethod: InsertionMethod { didSet { defaults.set(insertionMethod.rawValue, forKey: "insertionMethod") } }
    @Published var replaceSelection: Bool { didSet { defaults.set(replaceSelection, forKey: "replaceSelection") } }
    @Published var singleLineInTerminals: Bool { didSet { defaults.set(singleLineInTerminals, forKey: "singleLineInTerminals") } }
    @Published var returnToOriginalApp: Bool { didSet { defaults.set(returnToOriginalApp, forKey: "returnToOriginalApp") } }

    // Privacy
    @Published var keepTranscriptHistory: Bool { didSet { defaults.set(keepTranscriptHistory, forKey: "keepTranscriptHistory") } }
    @Published var keepAudioHistory: Bool { didSet { defaults.set(keepAudioHistory, forKey: "keepAudioHistory") } }

    private init() {
        defaults.register(defaults: [
            "showHUD": true, "showMenuBarIcon": true, "playSounds": true,
            "notifyOnError": true, "notifyOnSuccess": false,
            "holdKey": ModifierKey.rightOption.rawValue, "tapKey": ModifierKey.rightCommand.rawValue, "comboEnabled": false, "maxRecordingMinutes": 15,
            "modelID": TranscriptionModel.default.id,
            "languagesText": "en", "autoDetectLanguage": false,
            "contextPrompt": Self.defaultPrompt,
            "keywordsText": Self.defaultKeywords.joined(separator: "\n"),
            "outputMode": OutputMode.verbatim.rawValue, "polishModelID": PolishModel.default.id,
            "insertionMethod": InsertionMethod.automatic.rawValue, "replaceSelection": false,
            "singleLineInTerminals": true, "returnToOriginalApp": true,
            "keepTranscriptHistory": false, "keepAudioHistory": false,
        ])
        showHUD = defaults.bool(forKey: "showHUD")
        showMenuBarIcon = defaults.bool(forKey: "showMenuBarIcon")
        playSounds = defaults.bool(forKey: "playSounds")
        notifyOnError = defaults.bool(forKey: "notifyOnError")
        notifyOnSuccess = defaults.bool(forKey: "notifyOnSuccess")
        hotkey = defaults.data(forKey: "hotkey").flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) } ?? .default
        holdKey = ModifierKey(rawValue: defaults.string(forKey: "holdKey") ?? "") ?? .rightOption
        tapKey = ModifierKey(rawValue: defaults.string(forKey: "tapKey") ?? "") ?? .rightCommand
        comboEnabled = defaults.bool(forKey: "comboEnabled")
        maxRecordingMinutes = min(30, max(1, defaults.integer(forKey: "maxRecordingMinutes")))
        modelID = defaults.string(forKey: "modelID") ?? TranscriptionModel.default.id
        languagesText = defaults.string(forKey: "languagesText") ?? "en"
        autoDetectLanguage = defaults.bool(forKey: "autoDetectLanguage")
        contextPrompt = defaults.string(forKey: "contextPrompt") ?? Self.defaultPrompt
        keywordsText = defaults.string(forKey: "keywordsText") ?? ""
        outputMode = OutputMode(rawValue: defaults.string(forKey: "outputMode") ?? "") ?? .verbatim
        polishModelID = defaults.string(forKey: "polishModelID") ?? PolishModel.default.id
        insertionMethod = InsertionMethod(rawValue: defaults.string(forKey: "insertionMethod") ?? "") ?? .automatic
        replaceSelection = defaults.bool(forKey: "replaceSelection")
        singleLineInTerminals = defaults.bool(forKey: "singleLineInTerminals")
        returnToOriginalApp = defaults.bool(forKey: "returnToOriginalApp")
        keepTranscriptHistory = defaults.bool(forKey: "keepTranscriptHistory")
        keepAudioHistory = defaults.bool(forKey: "keepAudioHistory")
    }

    /// e.g. "Tap Right ⌘ or hold Right ⌥ to dictate"
    var shortcutSummary: String {
        var parts: [String] = []
        if tapKey != .off && tapKey == holdKey {
            parts.append("Tap or hold \(tapKey.shortName)")
        } else {
            if tapKey != .off { parts.append("Tap \(tapKey.shortName)") }
            if holdKey != .off { parts.append("hold \(holdKey.shortName)") }
        }
        if comboEnabled { parts.append("press \(hotkey.displayString)") }
        guard !parts.isEmpty else { return "No shortcut set – see Settings → Shortcut" }
        let text = parts.joined(separator: " or ") + " to dictate"
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    var model: TranscriptionModel { TranscriptionModel.named(modelID) }
    var polishModel: PolishModel { PolishModel.named(polishModelID) }

    var transcriptionOptions: TranscriptionOptions {
        TranscriptionOptions(
            model: model,
            prompt: contextPrompt,
            keywords: KeywordSanitizer.parse(keywordsText),
            languages: autoDetectLanguage ? [] : LanguageCodes.sanitize(languagesText.components(separatedBy: CharacterSet(charactersIn: ", \n"))))
    }
}
