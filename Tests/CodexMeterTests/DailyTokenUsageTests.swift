import Foundation
import XCTest
@testable import CodexMeter

final class DailyTokenUsageTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        return calendar
    }

    func testParsesStructuredTokenCountAndSeparatesCachedInput() throws {
        let start = ISO8601DateFormatter().date(from: "2026-07-31T16:00:00Z")!
        let interval = DateInterval(start: start, duration: 86_400)
        let line = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":100,"reasoning_output_tokens":20,"total_tokens":1100}}}}"#

        let event = try XCTUnwrap(DailyTokenLogParser.parse(line: line, inside: interval))

        XCTAssertEqual(event.usage.totalTokens, 1_100)
        XCTAssertEqual(event.usage.cachedInputTokens, 800)
        XCTAssertEqual(event.usage.nonCachedInputTokens, 200)
        XCTAssertEqual(event.usage.outputTokens, 100)
        XCTAssertEqual(event.usage.reasoningOutputTokens, 20)
    }

    func testRejectsNonTokenEventAndEventOutsideToday() {
        let start = ISO8601DateFormatter().date(from: "2026-07-31T16:00:00Z")!
        let interval = DateInterval(start: start, duration: 86_400)
        let wrongType = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"message","info":{}}}"#
        let yesterday = #"{"timestamp":"2026-07-31T15:59:59Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":10}}}}"#

        XCTAssertNil(DailyTokenLogParser.parse(line: wrongType, inside: interval))
        XCTAssertNil(DailyTokenLogParser.parse(line: yesterday, inside: interval))
    }

    func testRejectsTokenEventAtIntervalEnd() {
        let start = ISO8601DateFormatter().date(from: "2026-07-31T16:00:00Z")!
        let interval = DateInterval(start: start, duration: 86_400)
        let atTomorrowMidnight = #"{"timestamp":"2026-08-01T16:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":10}}}}"#

        XCTAssertNil(DailyTokenLogParser.parse(line: atTomorrowMidnight, inside: interval))
    }

    func testUsageAdditionDoesNotAddReasoningTwice() {
        let first = DailyTokenUsage(
            totalTokens: 1_100,
            cachedInputTokens: 800,
            nonCachedInputTokens: 200,
            outputTokens: 100,
            reasoningOutputTokens: 20,
            latestEventAt: Date(timeIntervalSince1970: 10)
        )
        let second = DailyTokenUsage(
            totalTokens: 550,
            cachedInputTokens: 300,
            nonCachedInputTokens: 200,
            outputTokens: 50,
            reasoningOutputTokens: 10,
            latestEventAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual((first + second).totalTokens, 1_650)
        XCTAssertEqual((first + second).outputTokens, 150)
        XCTAssertEqual((first + second).reasoningOutputTokens, 30)
    }

    func testCompactChineseFormatting() {
        XCTAssertEqual(TokenCountFormatter.compact(9_999), "9,999")
        XCTAssertEqual(TokenCountFormatter.compact(10_000), "1.0万")
        XCTAssertEqual(TokenCountFormatter.compact(7_986_313), "798.6万")
        XCTAssertEqual(TokenCountFormatter.compact(100_000_000), "1.0亿")
    }

    func testProviderReadsOnlyNewCompleteLinesWithoutDoubleCounting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-test.jsonl")
        let first = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":10,"reasoning_output_tokens":2,"total_tokens":110}}}}"#
        try (first + "\n").write(to: file, atomically: true, encoding: .utf8)
        let provider = DailyTokenUsageProvider(roots: [root], calendar: calendar)
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!

        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 110)
        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 110)

        let partial = #"{"timestamp":"2026-08-01T02:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":100,"output_tokens":20,"reasoning_output_tokens":4,"total_tokens":220}}}}"#
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(partial.prefix(partial.count / 2).utf8))
        try handle.close()
        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 110)

        let finish = try FileHandle(forWritingTo: file)
        try finish.seekToEnd()
        try finish.write(contentsOf: Data((String(partial.suffix(partial.count - partial.count / 2)) + "\n").utf8))
        try finish.close()
        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 330)
    }

    func testProviderResetsAtLocalMidnight() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-midnight.jsonl")
        let before = #"{"timestamp":"2026-07-31T15:59:59Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":90,"cached_input_tokens":80,"output_tokens":10,"total_tokens":100}}}}"#
        let after = #"{"timestamp":"2026-07-31T16:00:01Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":180,"cached_input_tokens":160,"output_tokens":20,"total_tokens":200}}}}"#
        try (before + "\n" + after + "\n").write(to: file, atomically: true, encoding: .utf8)
        let provider = DailyTokenUsageProvider(roots: [root], calendar: calendar)
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!

        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 200)
    }

    func testProviderDeduplicatesSameRolloutFilenameAcrossRoots() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let active = base.appendingPathComponent("sessions")
        let archived = base.appendingPathComponent("archived")
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let line = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":90,"cached_input_tokens":80,"output_tokens":10,"total_tokens":100}}}}"#
        try (line + "\n").write(to: active.appendingPathComponent("rollout-same.jsonl"), atomically: true, encoding: .utf8)
        try (line + "\n").write(to: archived.appendingPathComponent("rollout-same.jsonl"), atomically: true, encoding: .utf8)
        let provider = DailyTokenUsageProvider(roots: [active, archived], calendar: calendar)
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!

        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 100)
    }
}
