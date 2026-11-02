import Foundation

public enum TranscriptionError: Error, Equatable, Sendable {
    case missingAPIKey
    case unauthorized(String)
    case forbidden(String)
    /// Request-rate limit. Safe to retry after a wait.
    case rateLimited(retryAfter: TimeInterval?)
    /// Billing, spend or quota limits. Retrying will not help.
    case quotaExceeded(String)
    case badRequest(message: String, param: String?)
    case server(status: Int)
    case offline
    case timedOut
    case network(String)
    case cancelled
    case invalidResponse
    case fileTooLarge(bytes: Int)
    case emptyTranscript

    private static let billingCodes: Set<String> = [
        "insufficient_quota", "credit_balance_exhausted", "organization_spend_limit_exceeded",
        "project_spend_limit_exceeded", "organization_usage_limit_exceeded", "billing_hard_limit_reached",
    ]

    /// Maps a non-2xx response. Messages come from OpenAI and never contain the key.
    public static func from(status: Int, body: Data, retryAfterHeader: String?) -> TranscriptionError {
        let detail = (try? JSONDecoder().decode(OpenAIErrorBody.self, from: body))?.error
        let message = detail?.message ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch status {
        case 400, 413, 415, 422:
            return .badRequest(message: message, param: detail?.param)
        case 401:
            return .unauthorized(message)
        case 403:
            return .forbidden(message)
        case 429:
            if let code = detail?.code, billingCodes.contains(code) { return .quotaExceeded(message) }
            if let type = detail?.type, type == "insufficient_quota" { return .quotaExceeded(message) }
            return .rateLimited(retryAfter: retryAfterHeader.flatMap(TimeInterval.init))
        default:
            return .server(status: status)
        }
    }

    public static func from(urlError: URLError) -> TranscriptionError {
        switch urlError.code {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        default: return .network(urlError.localizedDescription)
        }
    }

    /// Errors where an automatic retry is reasonable. Timeouts are excluded: the server may
    /// have finished (and billed) the first attempt, so those wait for an explicit retry.
    public var isAutoRetryable: Bool {
        switch self {
        case .rateLimited, .server: return true
        default: return false
        }
    }

    /// Whether keeping the recording for a manual retry makes sense.
    public var isRetryableLater: Bool {
        switch self {
        case .missingAPIKey, .unauthorized, .forbidden, .rateLimited, .quotaExceeded, .server,
             .offline, .timedOut, .network, .invalidResponse:
            return true
        case .badRequest, .cancelled, .fileTooLarge, .emptyTranscript:
            return false
        }
    }

    public var userMessage: String {
        switch self {
        case .missingAPIKey: return "Add your OpenAI API key in Settings."
        case .unauthorized(let m): return "OpenAI rejected the API key: \(m)"
        case .forbidden(let m): return "Access denied: \(m)"
        case .rateLimited: return "Rate limited by OpenAI. Try again shortly."
        case .quotaExceeded(let m): return "OpenAI billing limit: \(m)"
        case .badRequest(let m, let p): return p.map { "Request rejected (\($0)): \(m)" } ?? "Request rejected: \(m)"
        case .server(let s): return "OpenAI server error (\(s))."
        case .offline: return "No internet connection."
        case .timedOut: return "The request timed out."
        case .network(let m): return "Network error: \(m)"
        case .cancelled: return "Cancelled."
        case .invalidResponse: return "Unexpected response from OpenAI."
        case .fileTooLarge(let b): return "Recording is too large (\(b / 1_048_576) MB)."
        case .emptyTranscript: return "No speech was recognized."
        }
    }
}

public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 8) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// Delay before attempt `attempt + 1`, or nil when no further attempt should be made.
    public func delay(after error: TranscriptionError, attempt: Int, jitter: Double = Double.random(in: 0...0.3)) -> TimeInterval? {
        guard error.isAutoRetryable, attempt < maxAttempts else { return nil }
        if case .rateLimited(let retryAfter?) = error { return min(maxDelay * 2, retryAfter) }
        let exponential = baseDelay * pow(2, Double(attempt - 1))
        return min(maxDelay, exponential) * (1 + jitter)
    }
}
