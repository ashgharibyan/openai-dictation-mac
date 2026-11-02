import Foundation

/// User-controlled context sent with a transcription request.
public struct TranscriptionOptions: Equatable, Sendable {
    public var model: TranscriptionModel
    /// Free-form context about the speaker and topic (the documented `prompt` field).
    public var prompt: String
    /// Literal terms likely to appear (the documented `keywords[]` field).
    public var keywords: [String]
    /// ISO-639-1 codes. Empty means let the model detect the language.
    public var languages: [String]

    public init(model: TranscriptionModel, prompt: String, keywords: [String], languages: [String]) {
        self.model = model
        self.prompt = prompt
        self.keywords = keywords
        self.languages = languages
    }
}

public struct MultipartForm {
    public let boundary: String
    private(set) public var body = Data()

    public init(boundary: String = "Boundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.append(value)
        body.append("\r\n")
    }

    public mutating func addFile(_ name: String, filename: String, mimeType: String, data: Data) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.append("\r\n")
    }

    public mutating func finalize() {
        body.append("--\(boundary)--\r\n")
    }
}

private extension Data {
    mutating func append(_ string: String) { append(Data(string.utf8)) }
}

public enum TranscriptionRequestBuilder {
    public static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    /// Builds the multipart body. Only fields documented for the chosen model are sent.
    public static func makeForm(audio: Data, filename: String, mimeType: String,
                                options: TranscriptionOptions, boundary: String? = nil) -> MultipartForm {
        var form = boundary.map(MultipartForm.init(boundary:)) ?? MultipartForm()
        let model = options.model
        form.addField("model", model.id)
        form.addField("response_format", "json")

        let keywords = KeywordSanitizer.sanitize(options.keywords)
        var prompt = options.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.supportsKeywords && !keywords.isEmpty {
            // Older models have no keywords field; vocabulary goes into the prompt context instead.
            let vocab = "Vocabulary that may appear: " + keywords.joined(separator: ", ") + "."
            prompt = prompt.isEmpty ? vocab : prompt + " " + vocab
        }
        if model.supportsPrompt && !prompt.isEmpty {
            form.addField("prompt", prompt)
        }
        if model.supportsKeywords {
            for keyword in keywords { form.addField("keywords[]", keyword) }
        }

        let languages = LanguageCodes.sanitize(options.languages)
        if model.supportsLanguageList {
            for code in languages { form.addField("languages[]", code) }
        } else if languages.count == 1 {
            // The singular field cannot express several hints; with more than one, let the model detect.
            form.addField("language", languages[0])
        }

        form.addFile("file", filename: filename, mimeType: mimeType, data: audio)
        form.finalize()
        return form
    }

    public static func makeRequest(apiKey: String, form: MultipartForm, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Generous timeout that scales with audio length: transcription time grows with duration.
    public static func timeout(forAudioSeconds seconds: Double) -> TimeInterval {
        min(300, max(30, 20 + seconds * 1.5))
    }
}

public enum KeywordSanitizer {
    /// The API rejects the whole request if a keyword contains `<`, `>`, CR or LF.
    public static func sanitize(_ keywords: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in keywords {
            let cleaned = raw
                .replacingOccurrences(of: "<", with: "")
                .replacingOccurrences(of: ">", with: "")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty, seen.insert(cleaned.lowercased()).inserted else { continue }
            result.append(cleaned)
        }
        return result
    }

    /// Parses the settings text area: one keyword per line or comma separated.
    public static func parse(_ text: String) -> [String] {
        sanitize(text.components(separatedBy: CharacterSet(charactersIn: ",\n")))
    }
}

public enum LanguageCodes {
    /// Lower-cases and keeps only plausible codes (`en`, `hy`, `eng`, `zh-tw`), so a typo in
    /// settings is dropped locally instead of failing the request.
    public static func sanitize(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        return codes.compactMap { raw in
            let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard code.range(of: "^[a-z]{2,3}(-[a-z]{2})?$", options: .regularExpression) != nil,
                  seen.insert(code).inserted else { return nil }
            return code
        }
    }
}
