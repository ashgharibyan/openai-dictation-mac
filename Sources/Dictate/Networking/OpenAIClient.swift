import DictateCore
import Foundation
import os

/// Talks only to api.openai.com over HTTPS. Never logs keys, audio or transcripts.
final class OpenAIClient {
    private let session: URLSession
    private let log = Logger(subsystem: "local.dictate", category: "network")
    private let retryPolicy = RetryPolicy()

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
    }

    struct TranscriptionResult {
        let response: TranscriptionResponse
        let latency: TimeInterval
    }

    /// Uploads the file and returns the transcript. Retries only rate limits and 5xx (where the
    /// request was not processed); timeouts are surfaced so the user decides whether to resend.
    func transcribe(fileURL: URL, audioSeconds: Double, options: TranscriptionOptions, apiKey: String) async throws -> TranscriptionResult {
        let audio: Data
        do { audio = try Data(contentsOf: fileURL) } catch { throw TranscriptionError.invalidResponse }
        guard audio.count <= TranscriptionLimits.maxUploadBytes else { throw TranscriptionError.fileTooLarge(bytes: audio.count) }

        let form = TranscriptionRequestBuilder.makeForm(audio: audio, filename: "audio.m4a", mimeType: "audio/m4a", options: options)
        let request = TranscriptionRequestBuilder.makeRequest(
            apiKey: apiKey, form: form, timeout: TranscriptionRequestBuilder.timeout(forAudioSeconds: audioSeconds))

        let started = Date()
        let data = try await send(request, body: form.body)
        do {
            let response = try TranscriptionResponse.decode(data)
            return TranscriptionResult(response: response, latency: Date().timeIntervalSince(started))
        } catch {
            throw TranscriptionError.invalidResponse
        }
    }

    func polish(_ text: String, model: PolishModel, apiKey: String) async throws -> PolishResponse {
        func attempt(reasoning: Bool) async throws -> PolishResponse {
            let body = try PolishRequestBuilder.makeBody(transcript: text, model: model.id, includeReasoning: reasoning)
            let request = PolishRequestBuilder.makeRequest(apiKey: apiKey, body: body)
            return try PolishResponse.parse(try await send(request, body: nil))
        }
        do {
            return try await attempt(reasoning: true)
        } catch TranscriptionError.badRequest(_, let param) where param?.hasPrefix("reasoning") == true {
            // Some text models do not take a reasoning setting.
            return try await attempt(reasoning: false)
        }
    }

    /// Cheap authenticated call used by "Validate key".
    func validate(apiKey: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!, timeoutInterval: 15)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        _ = try await send(request, body: nil, retries: false)
    }

    private func send(_ request: URLRequest, body: Data?, retries: Bool = true) async throws -> Data {
        var attempt = 1
        while true {
            do {
                try Task.checkCancellation()
                let (data, response): (Data, URLResponse)
                if let body {
                    (data, response) = try await session.upload(for: request, from: body)
                } else {
                    (data, response) = try await session.data(for: request)
                }
                guard let http = response as? HTTPURLResponse else { throw TranscriptionError.invalidResponse }
                if (200..<300).contains(http.statusCode) { return data }
                let error = TranscriptionError.from(status: http.statusCode, body: data,
                                                    retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"))
                log.notice("OpenAI request failed with status \(http.statusCode, privacy: .public)")
                guard retries, let delay = retryPolicy.delay(after: error, attempt: attempt) else { throw error }
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch let error as URLError {
                throw TranscriptionError.from(urlError: error)
            } catch is CancellationError {
                throw TranscriptionError.cancelled
            }
        }
    }
}
