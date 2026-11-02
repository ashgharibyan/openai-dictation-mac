import Foundation

/// Static description of an OpenAI transcription model and which documented request
/// fields it accepts. Add new models here; nothing else needs to change.
///
/// Source: developers.openai.com/api/docs/guides/speech-to-text, the
/// `POST /v1/audio/transcriptions` reference, and the pricing page (read 2026-11-02).
public struct TranscriptionModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    /// Accepts `keywords[]` (literal terms expected in the audio).
    public let supportsKeywords: Bool
    /// Accepts `languages[]`. Models without it take the singular `language` field.
    public let supportsLanguageList: Bool
    public let supportsPrompt: Bool
    /// Published estimated price, USD per minute of audio.
    public let usdPerMinute: Double
    /// Scheduled for removal from the API.
    public let deprecationNote: String?

    public static let gptTranscribe = TranscriptionModel(
        id: "gpt-transcribe", displayName: "GPT-Transcribe (recommended)",
        supportsKeywords: true, supportsLanguageList: true, supportsPrompt: true,
        usdPerMinute: 0.0045, deprecationNote: nil)

    public static let gpt4oTranscribe = TranscriptionModel(
        id: "gpt-4o-transcribe", displayName: "GPT-4o Transcribe",
        supportsKeywords: false, supportsLanguageList: false, supportsPrompt: true,
        usdPerMinute: 0.006, deprecationNote: "Removed from the API on Feb 26, 2027")

    public static let gpt4oMiniTranscribe = TranscriptionModel(
        id: "gpt-4o-mini-transcribe", displayName: "GPT-4o mini Transcribe",
        supportsKeywords: false, supportsLanguageList: false, supportsPrompt: true,
        usdPerMinute: 0.003, deprecationNote: "Removed from the API on Feb 26, 2027")

    public static let whisper1 = TranscriptionModel(
        id: "whisper-1", displayName: "Whisper",
        supportsKeywords: false, supportsLanguageList: false, supportsPrompt: true,
        usdPerMinute: 0.006, deprecationNote: "Removed from the API on Feb 26, 2027")

    public static let all: [TranscriptionModel] = [gptTranscribe, gpt4oTranscribe, gpt4oMiniTranscribe, whisper1]
    public static let `default` = gptTranscribe

    public static func named(_ id: String) -> TranscriptionModel {
        all.first { $0.id == id } ?? .default
    }
}

/// Published audio limits for the file transcription endpoint.
public enum TranscriptionLimits {
    /// "Files can be up to 25 MB." Keep a margin for multipart overhead.
    public static let maxUploadBytes = 24 * 1024 * 1024
}

/// Text model used only for the optional "Polished" mode, billed separately.
public struct PolishModel: Hashable, Sendable {
    public let id: String
    public let usdPerMillionInput: Double
    public let usdPerMillionOutput: Double

    public static let `default` = PolishModel(id: "gpt-6-luna", usdPerMillionInput: 0.10, usdPerMillionOutput: 0.50)

    public static func named(_ id: String) -> PolishModel {
        id == PolishModel.default.id ? .default
            // Unknown model: price unknown, estimate with the default rates and say so in the UI.
            : PolishModel(id: id, usdPerMillionInput: PolishModel.default.usdPerMillionInput,
                          usdPerMillionOutput: PolishModel.default.usdPerMillionOutput)
    }
}
