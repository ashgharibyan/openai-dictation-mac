import DictateCore
import Foundation

// Minimal test runner (XCTest needs a full Xcode install). Run: swift run DictateCoreTests
var failures = 0
var passes = 0

func check(_ condition: @autoclosure () -> Bool, _ name: String, file: StaticString = #file, line: UInt = #line) {
    if condition() { passes += 1 } else { failures += 1; print("FAIL \(name) (\(file):\(line))") }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ name: String, line: UInt = #line) {
    if a == b { passes += 1 } else { failures += 1; print("FAIL \(name) line \(line)\n  got:      \(a)\n  expected: \(b)") }
}

func formFields(_ form: MultipartForm) -> [(String, String)] {
    let body = String(decoding: form.body, as: UTF8.self)
    var result: [(String, String)] = []
    for part in body.components(separatedBy: "--\(form.boundary)") {
        guard let nameRange = part.range(of: "name=\""),
              let end = part[nameRange.upperBound...].firstIndex(of: "\""),
              let valueStart = part.range(of: "\r\n\r\n") else { continue }
        let name = String(part[nameRange.upperBound..<end])
        let value = String(part[valueStart.upperBound...]).replacingOccurrences(of: "\r\n", with: "")
        result.append((name, value))
    }
    return result
}

// MARK: Request building

do {
    let options = TranscriptionOptions(model: .gptTranscribe, prompt: "  Software engineer dictating.  ",
                                       keywords: ["Django", "Cel<ery>", "django", "Line\nBreak", " "],
                                       languages: ["EN", "hy", "english!", "en"])
    let form = TranscriptionRequestBuilder.makeForm(audio: Data([1, 2, 3]), filename: "a.m4a", mimeType: "audio/m4a",
                                                    options: options, boundary: "B")
    let fields = formFields(form)
    eq(fields.first { $0.0 == "model" }?.1, "gpt-transcribe", "model field")
    eq(fields.first { $0.0 == "prompt" }?.1, "Software engineer dictating.", "prompt trimmed")
    eq(fields.filter { $0.0 == "keywords[]" }.map(\.1), ["Django", "Celery", "Line Break"], "keywords sanitized and deduped")
    eq(fields.filter { $0.0 == "languages[]" }.map(\.1), ["en", "hy"], "languages sanitized")
    check(!fields.contains { $0.0 == "language" }, "no singular language with languages[]")
    eq(fields.first { $0.0 == "response_format" }?.1, "json", "json response")
    check(String(decoding: form.body, as: UTF8.self).hasSuffix("--B--\r\n"), "multipart terminated")
    check(String(decoding: form.body, as: UTF8.self).contains("filename=\"a.m4a\"\r\nContent-Type: audio/m4a"), "file part headers")
}

do {
    let options = TranscriptionOptions(model: .whisper1, prompt: "Context.", keywords: ["Redis", "Celery"], languages: ["en"])
    let fields = formFields(TranscriptionRequestBuilder.makeForm(audio: Data(), filename: "a.m4a", mimeType: "audio/m4a", options: options))
    check(!fields.contains { $0.0 == "keywords[]" }, "older model gets no keywords field")
    eq(fields.first { $0.0 == "prompt" }?.1, "Context. Vocabulary that may appear: Redis, Celery.", "keywords folded into prompt")
    eq(fields.first { $0.0 == "language" }?.1, "en", "singular language for older model")
    let multi = TranscriptionOptions(model: .whisper1, prompt: "", keywords: [], languages: ["en", "hy"])
    let multiFields = formFields(TranscriptionRequestBuilder.makeForm(audio: Data(), filename: "a.m4a", mimeType: "audio/m4a", options: multi))
    check(!multiFields.contains { $0.0 == "language" || $0.0 == "prompt" }, "several hints on older model: auto-detect, no empty prompt")
}

do {
    let request = TranscriptionRequestBuilder.makeRequest(apiKey: "sk-test", form: MultipartForm(boundary: "X"), timeout: 42)
    eq(request.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions", "endpoint")
    eq(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test", "auth header")
    eq(request.timeoutInterval, 42, "timeout")
    eq(TranscriptionRequestBuilder.timeout(forAudioSeconds: 0), 30, "min timeout")
    eq(TranscriptionRequestBuilder.timeout(forAudioSeconds: 1000), 300, "max timeout")
    eq(KeywordSanitizer.parse("Django, Celery\nRedis\n\nClaude Code"), ["Django", "Celery", "Redis", "Claude Code"], "keyword parsing")
}

// MARK: Response parsing

do {
    let r = try! TranscriptionResponse.decode(Data(#"{"text":"Hello Django.","languages":[{"code":"en"}]}"#.utf8))
    eq(r.text, "Hello Django.", "decode text")
    eq(r.languages?.first?.code, "en", "decode languages")
    eq(r.usage, nil, "usage optional")
    let t = try! TranscriptionResponse.decode(Data(#"{"text":"x","usage":{"type":"tokens","input_tokens":14,"input_token_details":{"text_tokens":0,"audio_tokens":14},"output_tokens":45,"total_tokens":59}}"#.utf8))
    eq(t.usage, .tokens(input: 14, output: 45, audio: 14), "token usage")
    let d = try! TranscriptionResponse.decode(Data(#"{"text":"x","usage":{"type":"duration","seconds":27}}"#.utf8))
    eq(d.usage, .duration(seconds: 27), "duration usage")
    check((try? TranscriptionResponse.decode(Data(#"{"error":{}}"#.utf8))) == nil, "missing text fails")
}

// MARK: Errors and retries

do {
    let quota = Data(#"{"error":{"message":"You exceeded your current quota","type":"insufficient_quota","code":"insufficient_quota"}}"#.utf8)
    eq(TranscriptionError.from(status: 429, body: quota, retryAfterHeader: nil), .quotaExceeded("You exceeded your current quota"), "quota 429")
    eq(TranscriptionError.from(status: 429, body: Data(), retryAfterHeader: "3"), .rateLimited(retryAfter: 3), "rate limit 429")
    let bad = Data(#"{"error":{"message":"Invalid language","param":"languages"}}"#.utf8)
    eq(TranscriptionError.from(status: 400, body: bad, retryAfterHeader: nil), .badRequest(message: "Invalid language", param: "languages"), "400 with param")
    if case .unauthorized = TranscriptionError.from(status: 401, body: Data(), retryAfterHeader: nil) { passes += 1 } else { failures += 1; print("FAIL 401") }
    eq(TranscriptionError.from(status: 503, body: Data(), retryAfterHeader: nil), .server(status: 503), "503")
    eq(TranscriptionError.from(urlError: URLError(.notConnectedToInternet)), .offline, "offline")
    eq(TranscriptionError.from(urlError: URLError(.timedOut)), .timedOut, "timeout")

    let policy = RetryPolicy(maxAttempts: 3, baseDelay: 1, maxDelay: 8)
    eq(policy.delay(after: .server(status: 500), attempt: 1, jitter: 0), 1, "first backoff")
    eq(policy.delay(after: .server(status: 500), attempt: 2, jitter: 0), 2, "second backoff")
    eq(policy.delay(after: .server(status: 500), attempt: 3, jitter: 0), nil, "attempts capped")
    eq(policy.delay(after: .rateLimited(retryAfter: 5), attempt: 1, jitter: 0), 5, "Retry-After honoured")
    eq(policy.delay(after: .timedOut, attempt: 1, jitter: 0), nil, "timeouts never auto-retried (avoid double billing)")
    eq(policy.delay(after: .quotaExceeded("x"), attempt: 1, jitter: 0), nil, "quota never retried")
    check(TranscriptionError.offline.isRetryableLater, "offline keeps recording")
    check(!TranscriptionError.cancelled.isRetryableLater, "cancel discards")
}

// MARK: Text processing

do {
    eq(TextCleaner.clean("Um, so I think, uh, we should use Celery."), "So I think, we should use Celery.", "fillers removed, capitalized")
    eq(TextCleaner.clean("The umbrella is, hmm, uhm red."), "The umbrella is, red.", "umbrella preserved")
    eq(TextCleaner.clean("I said it um."), "I said it.", "trailing filler keeps period")
    eq(TextCleaner.clean("Deploy to github.com today. Uh, then e.g. restart."), "Deploy to github.com today. Then e.g. restart.", "no over-capitalization")
    eq(TextCleaner.clean("Already clean text."), "Already clean text.", "idempotent on clean text")
    eq(TextCleaner.prepareForInsertion("  ls -la\n", singleLine: false), "ls -la", "no trailing newline ever")
    eq(TextCleaner.prepareForInsertion("first line\n\nsecond line", singleLine: true), "first line second line", "single line for terminals")
    eq(TextCleaner.prepareForInsertion("a\nb", singleLine: false), "a\nb", "multi-line kept outside terminals")
    check(PolishGuard.isAcceptable(original: "um so I think we should uh deploy the the Django app today", polished: "I think we should deploy the Django app today."), "polish accepted")
    check(!PolishGuard.isAcceptable(original: "Deploy it.", polished: "Sure! Here is a detailed plan to deploy your application to production safely."), "polish expansion rejected")
    check(!PolishGuard.isAcceptable(original: "one two three", polished: ""), "empty polish rejected")
}

do {
    let body = try! JSONSerialization.jsonObject(with: PolishRequestBuilder.makeBody(transcript: "hi", model: "gpt-6-luna", includeReasoning: true)) as! [String: Any]
    eq(body["model"] as? String, "gpt-6-luna", "polish model")
    eq(body["store"] as? Bool, false, "polish not stored")
    check((body["input"] as? String)?.contains("<transcript>\nhi\n</transcript>") == true, "transcript wrapped as data")
    let response = Data(#"{"output":[{"type":"reasoning"},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello there."}]}],"usage":{"input_tokens":120,"output_tokens":5}}"#.utf8)
    eq(try! PolishResponse.parse(response), PolishResponse(text: "Hello there.", inputTokens: 120, outputTokens: 5), "responses API parsing")
}

// MARK: State machine

do {
    typealias M = DictationStateMachine
    eq(M.next(.idle, .start), .recording, "start")
    eq(M.next(.recording, .start), nil, "no overlapping recording")
    eq(M.next(.transcribing, .start), nil, "no recording while transcribing")
    eq(M.next(.recording, .stop), .transcribing, "stop -> transcribe")
    eq(M.next(.transcribing, .stop), nil, "no duplicate transcription")
    eq(M.next(.transcribing, .retry), nil, "no retry while transcribing")
    eq(M.next(.transcribing, .transcribed), .inserting, "insert")
    eq(M.next(.inserting, .inserted), .success, "success")
    eq(M.next(.success, .settle), .idle, "settle")
    eq(M.next(.error, .retry), .transcribing, "retry from error")
    eq(M.next(.recording, .cancel), .idle, "cancel recording")
    eq(M.next(.transcribing, .cancel), .idle, "cancel transcription")
    eq(M.next(.inserting, .cancel), nil, "insertion not cancellable mid-paste")
    eq(M.next(.idle, .stop), nil, "stray release ignored")
    eq(M.next(.recording, .audioUnusable), .error, "empty recording")
    eq(M.next(.idle, .failed), .error, "preflight error from idle")
    eq(M.next(.transcribing, .settle), nil, "settle only from display states")
}

// MARK: Usage

do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let nov = Date(timeIntervalSince1970: 1_793_620_800) // 2026-11-02
    var usage = MonthlyUsage(month: MonthlyUsage.monthKey(for: nov, calendar: cal))
    eq(usage.month, "2026-11", "month key")
    usage.recordRequest(audioSeconds: 120, model: .gptTranscribe)
    usage.recordSuccess(audioSeconds: 120, latency: 2)
    usage.recordSuccess(audioSeconds: 60, latency: 4)
    check(abs(usage.estimatedTranscriptionUSD - 0.009) < 1e-9, "transcription cost 2 min * $0.0045")
    eq(usage.averageTranscriptionSeconds, 3, "average latency")
    usage.recordPolish(inputTokens: 1_000_000, outputTokens: 1_000_000, model: .default)
    check(abs(usage.estimatedPolishUSD - 0.60) < 1e-9, "polish cost")
    let dec = Date(timeIntervalSince1970: 1_796_212_800) // 2026-12-02
    eq(usage.rolledOver(to: dec, calendar: cal).successCount, 0, "rollover resets")
    eq(usage.rolledOver(to: nov, calendar: cal).successCount, 2, "same month kept")
}

// MARK: Shortcuts

do {
    eq(KeyCombo.default.displayString, "⌥Space", "default display")
    check(KeyCombo.default.validationError == nil, "default valid")
    check(KeyCombo(keyCode: 0, modifiers: 0).validationError != nil, "bare letter rejected")
    check(KeyCombo(keyCode: 0, modifiers: KeyCombo.shift).validationError != nil, "shift+letter rejected")
    check(KeyCombo(keyCode: 96, modifiers: 0).validationError == nil, "F5 alone allowed")
    eq(KeyCombo.carbonModifiers(fromCocoa: 524288), KeyCombo.option, "cocoa option")
    eq(KeyCombo.carbonModifiers(fromCocoa: 1048576 | 131072), KeyCombo.cmd | KeyCombo.shift, "cocoa cmd+shift")

    let plist: [String: Any] = [
        "64": ["enabled": NSNumber(value: true), "value": ["type": "standard", "parameters": [NSNumber(value: 32), NSNumber(value: 49), NSNumber(value: 1048576)]]],
        "60": ["enabled": NSNumber(value: true), "value": ["type": "standard", "parameters": [NSNumber(value: 32), NSNumber(value: 49), NSNumber(value: 262144)]]],
        "61": ["enabled": NSNumber(value: false), "value": ["type": "standard", "parameters": [NSNumber(value: 32), NSNumber(value: 49), NSNumber(value: 524288)]]],
    ]
    eq(SystemShortcutConflicts.conflicts(for: KeyCombo(keyCode: 49, modifiers: KeyCombo.cmd), in: plist), ["Show Spotlight search"], "spotlight conflict")
    eq(SystemShortcutConflicts.conflicts(for: .default, in: plist), [], "disabled shortcut ignored")
}

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
