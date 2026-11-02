import Foundation

/// The `json` response format. Only `text` is required; everything else is optional
/// because the docs do not show `usage` for every model.
public struct TranscriptionResponse: Decodable, Equatable, Sendable {
    public struct Language: Decodable, Equatable, Sendable {
        public let code: String
    }

    public enum Usage: Decodable, Equatable, Sendable {
        case tokens(input: Int, output: Int, audio: Int?)
        case duration(seconds: Double)
        case unknown

        private enum Keys: String, CodingKey {
            case type, input_tokens, output_tokens, input_token_details, seconds
        }
        private enum DetailKeys: String, CodingKey { case audio_tokens }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            switch try c.decodeIfPresent(String.self, forKey: .type) {
            case "tokens":
                let details = try? c.nestedContainer(keyedBy: DetailKeys.self, forKey: .input_token_details)
                self = .tokens(input: try c.decodeIfPresent(Int.self, forKey: .input_tokens) ?? 0,
                               output: try c.decodeIfPresent(Int.self, forKey: .output_tokens) ?? 0,
                               audio: try details?.decodeIfPresent(Int.self, forKey: .audio_tokens))
            case "duration":
                self = .duration(seconds: try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0)
            default:
                self = .unknown
            }
        }
    }

    public let text: String
    public let languages: [Language]?
    public let usage: Usage?

    public static func decode(_ data: Data) throws -> TranscriptionResponse {
        try JSONDecoder().decode(TranscriptionResponse.self, from: data)
    }
}

/// Error body shape: `{"error": {"message", "type", "param", "code"}}`.
public struct OpenAIErrorBody: Decodable, Sendable {
    public struct Detail: Decodable, Sendable {
        public let message: String?
        public let type: String?
        public let param: String?
        public let code: String?
    }
    public let error: Detail
}
