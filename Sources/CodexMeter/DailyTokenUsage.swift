import Foundation

struct DailyTokenUsage: Equatable, Sendable {
    var totalTokens: Int64
    var cachedInputTokens: Int64
    var nonCachedInputTokens: Int64
    var outputTokens: Int64
    var reasoningOutputTokens: Int64
    var latestEventAt: Date?

    static let zero = DailyTokenUsage(
        totalTokens: 0,
        cachedInputTokens: 0,
        nonCachedInputTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        latestEventAt: nil
    )

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            totalTokens: lhs.totalTokens + rhs.totalTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            nonCachedInputTokens: lhs.nonCachedInputTokens + rhs.nonCachedInputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            reasoningOutputTokens: lhs.reasoningOutputTokens + rhs.reasoningOutputTokens,
            latestEventAt: [lhs.latestEventAt, rhs.latestEventAt].compactMap { $0 }.max()
        )
    }

    var cachedFraction: Double { fraction(cachedInputTokens) }
    var nonCachedFraction: Double { fraction(nonCachedInputTokens) }
    var outputFraction: Double { fraction(outputTokens) }

    private func fraction(_ value: Int64) -> Double {
        guard totalTokens > 0 else { return 0 }
        return min(max(Double(value) / Double(totalTokens), 0), 1)
    }
}

struct DailyTokenEvent: Equatable, Sendable {
    let timestamp: Date
    let usage: DailyTokenUsage
}

enum DailyTokenLogParser {
    static func parse(line: String, inside interval: DateInterval) -> DailyTokenEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestampText = object["timestamp"] as? String,
              let timestamp = parseDate(timestampText),
              interval.contains(timestamp),
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any] else {
            return nil
        }

        let input = int64(last["input_tokens"])
        let cached = int64(last["cached_input_tokens"])
        let output = int64(last["output_tokens"])
        let total = int64(last["total_tokens"])
        let reasoning = int64(last["reasoning_output_tokens"])
        guard total > 0 else { return nil }

        return DailyTokenEvent(
            timestamp: timestamp,
            usage: DailyTokenUsage(
                totalTokens: total,
                cachedInputTokens: cached,
                nonCachedInputTokens: max(input - cached, 0),
                outputTokens: output,
                reasoningOutputTokens: reasoning,
                latestEventAt: timestamp
            )
        )
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let value = value as? Int64 { return max(value, 0) }
        if let value = value as? Int { return Int64(max(value, 0)) }
        if let value = value as? Double { return Int64(max(value, 0)) }
        if let value = value as? String, let number = Int64(value) { return max(number, 0) }
        return 0
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

enum TokenCountFormatter {
    static func compact(_ value: Int64) -> String {
        if value >= 100_000_000 {
            return String(format: "%.1f亿", Double(value) / 100_000_000)
        }
        if value >= 10_000 {
            return String(format: "%.1f万", Double(value) / 10_000)
        }
        return value.formatted(.number.grouping(.automatic))
    }
}
