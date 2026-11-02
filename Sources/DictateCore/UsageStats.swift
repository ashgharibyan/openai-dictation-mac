import Foundation

/// Locally computed usage for the current calendar month. These are estimates from published
/// prices and local audio durations, not amounts billed by OpenAI.
public struct MonthlyUsage: Codable, Equatable, Sendable {
    public var month: String
    public var recordedSeconds: Double = 0
    public var successCount: Int = 0
    public var failureCount: Int = 0
    public var totalTranscriptionSeconds: Double = 0
    public var estimatedTranscriptionUSD: Double = 0
    public var estimatedPolishUSD: Double = 0

    public init(month: String) { self.month = month }

    public static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// Starts a fresh month when the stored one is stale.
    public func rolledOver(to date: Date, calendar: Calendar = .current) -> MonthlyUsage {
        let key = Self.monthKey(for: date, calendar: calendar)
        return key == month ? self : MonthlyUsage(month: key)
    }

    public var averageTranscriptionSeconds: Double {
        successCount == 0 ? 0 : totalTranscriptionSeconds / Double(successCount)
    }

    public var estimatedTotalUSD: Double { estimatedTranscriptionUSD + estimatedPolishUSD }

    /// Every request is billed, successful or not, so cost is added per request sent.
    public mutating func recordRequest(audioSeconds: Double, model: TranscriptionModel) {
        estimatedTranscriptionUSD += CostEstimator.transcriptionUSD(seconds: audioSeconds, model: model)
    }

    public mutating func recordSuccess(audioSeconds: Double, latency: Double) {
        recordedSeconds += audioSeconds
        successCount += 1
        totalTranscriptionSeconds += latency
    }

    public mutating func recordFailure() { failureCount += 1 }

    public mutating func recordPolish(inputTokens: Int, outputTokens: Int, model: PolishModel) {
        estimatedPolishUSD += CostEstimator.polishUSD(inputTokens: inputTokens, outputTokens: outputTokens, model: model)
    }
}

public enum CostEstimator {
    public static func transcriptionUSD(seconds: Double, model: TranscriptionModel) -> Double {
        max(0, seconds) / 60 * model.usdPerMinute
    }

    public static func polishUSD(inputTokens: Int, outputTokens: Int, model: PolishModel) -> Double {
        Double(inputTokens) / 1_000_000 * model.usdPerMillionInput
            + Double(outputTokens) / 1_000_000 * model.usdPerMillionOutput
    }
}
