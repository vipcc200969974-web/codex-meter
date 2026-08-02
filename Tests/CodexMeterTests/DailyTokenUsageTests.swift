import Foundation
import XCTest
@testable import CodexMeter

private final class AppendingAfterStatFileManager: FileManager, @unchecked Sendable {
    private let target: URL
    private let appendedData: Data
    private var didAppend = false

    init(target: URL, appendedData: Data) {
        self.target = target
        self.appendedData = appendedData
        super.init()
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        let attributes = try super.attributesOfItem(atPath: path)
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url == target.resolvingSymlinksInPath(), !didAppend else { return attributes }

        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: appendedData)
        didAppend = true
        return attributes
    }
}

private final class RootMetadataErrorFileManager: FileManager, @unchecked Sendable {
    private let targetRoot: URL

    init(targetRoot: URL) {
        self.targetRoot = targetRoot.standardizedFileURL
        super.init()
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if URL(fileURLWithPath: path).standardizedFileURL == targetRoot {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: path])
        }
        return try super.attributesOfItem(atPath: path)
    }
}

private final class RecordingDailyTokenFileReader: DailyTokenFileReading, @unchecked Sendable {
    private(set) var totalBytesRead = 0
    private(set) var offsets: [UInt64] = []
    private(set) var boundaryBytesRead = 0
    private(set) var boundaryByteOffsets: [UInt64] = []

    func read(from url: URL, offset: UInt64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        totalBytesRead += data.count
        offsets.append(offset)
        return data
    }

    func readByte(from url: URL, offset: UInt64) throws -> UInt8? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: 1) ?? Data()
        boundaryBytesRead += data.count
        boundaryByteOffsets.append(offset)
        return data.first
    }

    func reset() {
        totalBytesRead = 0
        offsets = []
        boundaryBytesRead = 0
        boundaryByteOffsets = []
    }
}

private final class BlockingCountingDailyTokenFileReader: DailyTokenFileReading, @unchecked Sendable {
    private let condition = NSCondition()
    private var activeReads = 0
    private var maximumActiveReads = 0
    private var readCount = 0
    private var firstReadReleased = false

    func read(from url: URL, offset: UInt64) throws -> Data {
        condition.lock()
        activeReads += 1
        maximumActiveReads = max(maximumActiveReads, activeReads)
        readCount += 1
        let ordinal = readCount
        condition.broadcast()
        while ordinal == 1, !firstReadReleased {
            condition.wait()
        }
        condition.unlock()
        defer {
            condition.lock()
            activeReads -= 1
            condition.broadcast()
            condition.unlock()
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.readToEnd() ?? Data()
    }

    func readByte(from url: URL, offset: UInt64) throws -> UInt8? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: 1)?.first
    }

    func waitForReadCount(_ expected: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while readCount < expected {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func releaseFirstRead() {
        condition.lock()
        firstReadReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var maxActiveReads: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumActiveReads
    }

    var totalReadCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return readCount
    }
}

private final class LockedDailyTokenResults: @unchecked Sendable {
    private let lock = NSLock()
    private var usages: [DailyTokenUsage] = []
    private var failures = 0

    func record(_ body: () throws -> DailyTokenUsage) {
        do {
            let usage = try body()
            lock.lock()
            usages.append(usage)
            lock.unlock()
        } catch {
            lock.lock()
            failures += 1
            lock.unlock()
        }
    }

    var snapshot: (usages: [DailyTokenUsage], failures: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (usages, failures)
    }
}

private final class CountingDailyTokenEventDecoder: DailyTokenEventDecoding {
    private let base: any DailyTokenEventDecoding
    private(set) var decodeCount = 0

    init(base: any DailyTokenEventDecoding = JSONDailyTokenEventDecoder()) {
        self.base = base
    }

    func decodeTokenEvent(from data: Data) -> DailyTokenEvent? {
        decodeCount += 1
        return base.decodeTokenEvent(from: data)
    }
}

private final class RecordingDailyTokenTimestampParser: DailyTokenTimestampParsing, @unchecked Sendable {
    private let result: Date
    private(set) var parsedValues: [String] = []

    init(result: Date) {
        self.result = result
    }

    func parse(_ value: String) -> Date? {
        parsedValues.append(value)
        return result
    }
}

private func mutateJSONCache(
    at url: URL,
    _ mutation: (inout [String: Any]) throws -> Void
) throws {
    var object = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    try mutation(&object)
    try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
}

final class DailyTokenUsageTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        return calendar
    }

    private func restartedUsageAfterMutatingCachedUsage(
        _ mutation: (inout [String: Any]) throws -> Void
    ) throws -> (usage: DailyTokenUsage, readOffsets: [UInt64]) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("sessions")
        let cache = base.appendingPathComponent("cache/daily-tokens.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let line = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120}}}}"#
        try (line + "\n").write(
            to: root.appendingPathComponent("rollout-corrupt-aggregate.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        let seed = DailyTokenUsageProvider(roots: [root], calendar: calendar, cacheURL: cache)
        XCTAssertEqual(try seed.currentUsage(now: now).totalTokens, 120)
        try mutateJSONCache(at: cache) { object in
            var cursors = try XCTUnwrap(object["cursors"] as? [[String: Any]])
            var usage = try XCTUnwrap(cursors[0]["usage"] as? [String: Any])
            try mutation(&usage)
            cursors[0]["usage"] = usage
            object["cursors"] = cursors
        }
        let reader = RecordingDailyTokenFileReader()
        let restarted = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            fileReader: reader,
            cacheURL: cache
        )
        return (try restarted.currentUsage(now: now), reader.offsets)
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

    func testRejectsMalformedLiveTokenMetrics() {
        let start = ISO8601DateFormatter().date(from: "2026-07-31T16:00:00Z")!
        let interval = DateInterval(start: start, duration: 86_400)
        let malformedMetrics = [
            #"{"input_tokens":-1,"total_tokens":10}"#,
            #"{"input_tokens":10,"cached_input_tokens":11,"total_tokens":20}"#,
            #"{"output_tokens":10,"reasoning_output_tokens":11,"total_tokens":20}"#,
            #"{"input_tokens":11,"output_tokens":10,"total_tokens":20}"#,
            #"{"input_tokens":9223372036854775806,"output_tokens":9223372036854775806,"total_tokens":9223372036854775806}"#,
            #"{"total_tokens":9223372036854775807}"#,
            #"{"total_tokens":9.223372036854776e18}"#
        ]

        for metrics in malformedMetrics {
            let line = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":\#(metrics)}}}"#
            XCTAssertNil(
                DailyTokenLogParser.parse(line: line, inside: interval),
                "Accepted malformed metrics: \(metrics)"
            )
        }
    }

    func testMalformedOversizedRecordDoesNotPublishOrPoisonLaterValidUsage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-malformed.jsonl")
        let malformed = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":9.223372036854776e18}}}}"#
        try (malformed + "\n").write(to: file, atomically: true, encoding: .utf8)
        let provider = DailyTokenUsageProvider(roots: [root], calendar: calendar)
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!

        XCTAssertEqual(try provider.currentUsage(now: now), .zero)

        let valid = #"{"timestamp":"2026-08-01T02:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":10}}}}"#
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((valid + "\n").utf8))
        try handle.close()

        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 10)
    }

    func testParsesTokenCountWithValidJSONWhitespace() throws {
        let start = ISO8601DateFormatter().date(from: "2026-07-31T16:00:00Z")!
        let interval = DateInterval(start: start, duration: 86_400)
        let line = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type" : "token_count","info":{"last_token_usage":{"total_tokens":10}}}}"#

        let event = try XCTUnwrap(DailyTokenLogParser.parse(line: line, inside: interval))

        XCTAssertEqual(event.usage.totalTokens, 10)
    }

    func testParsesUnicodeEscapedTokenCountType() throws {
        let start = ISO8601DateFormatter().date(from: "2026-07-31T16:00:00Z")!
        let interval = DateInterval(start: start, duration: 86_400)
        let line = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_\u0063ount","info":{"last_token_usage":{"total_tokens":20}}}}"#

        let event = try XCTUnwrap(DailyTokenLogParser.parse(line: line, inside: interval))

        XCTAssertEqual(event.usage.totalTokens, 20)
    }

    func testJSONTokenDecodersReuseSharedTimestampParserIdentity() {
        let first = JSONDailyTokenEventDecoder()
        let second = JSONDailyTokenEventDecoder()

        XCTAssertEqual(
            ObjectIdentifier(first.timestampParser as AnyObject),
            ObjectIdentifier(second.timestampParser as AnyObject)
        )
    }

    func testJSONTokenDecoderUsesInjectedTimestampParser() throws {
        let expectedDate = Date(timeIntervalSince1970: 123)
        let timestampParser = RecordingDailyTokenTimestampParser(result: expectedDate)
        let decoder = JSONDailyTokenEventDecoder(timestampParser: timestampParser)
        let line = #"{"timestamp":"injected-date","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":20}}}}"#

        let event = try XCTUnwrap(decoder.decodeTokenEvent(from: Data(line.utf8)))

        XCTAssertEqual(event.timestamp, expectedDate)
        XCTAssertEqual(timestampParser.parsedValues, ["injected-date"])
    }

    func testRejectsNonTokenEventAndEventOutsideToday() {
        let start = ISO8601DateFormatter().date(from: "2026-07-31T16:00:00Z")!
        let interval = DateInterval(start: start, duration: 86_400)
        let wrongType = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"message","info":{}}}"#
        let yesterday = #"{"timestamp":"2026-07-31T15:59:59Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":10}}}}"#

        XCTAssertNil(DailyTokenLogParser.parse(line: wrongType, inside: interval))
        XCTAssertNil(DailyTokenLogParser.parse(line: yesterday, inside: interval))
    }

    func testPrivateNonTokenPayloadIsRejectedBeforeTypedDecoding() {
        let start = ISO8601DateFormatter().date(from: "2026-07-31T16:00:00Z")!
        let interval = DateInterval(start: start, duration: 86_400)
        let privateText = String(repeating: "private prompt and reply content ", count: 2_000)
        let line = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"message","content":"\#(privateText)","metadata":{"private_metric":999999}}}"#
        let decoder = CountingDailyTokenEventDecoder()

        XCTAssertNil(DailyTokenLogParser.parse(line: line, inside: interval, decoder: decoder))
        XCTAssertEqual(decoder.decodeCount, 0)
    }

    func testRealisticColdParseFixtureDecodesOnlyTokenEventsWithinBudget() throws {
        let start = ISO8601DateFormatter().date(from: "2026-07-31T16:00:00Z")!
        let interval = DateInterval(start: start, duration: 86_400)
        let privateText = String(repeating: "unrelated private payload ", count: 80)
        let unrelated = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"message","content":"\#(privateText)"}}"#
        let token = #"{"timestamp":"2026-08-01T02:00:00.123Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":4,"output_tokens":2,"reasoning_output_tokens":1,"total_tokens":12}}}}"#
        let decoder = CountingDailyTokenEventDecoder()
        let startedAt = Date()
        var usage = DailyTokenUsage.zero

        for _ in 0..<10_000 {
            XCTAssertNil(DailyTokenLogParser.parse(line: unrelated, inside: interval, decoder: decoder))
        }
        for _ in 0..<2_000 {
            let event = try XCTUnwrap(
                DailyTokenLogParser.parse(line: token, inside: interval, decoder: decoder)
            )
            usage = usage + event.usage
        }

        XCTAssertEqual(decoder.decodeCount, 2_000)
        XCTAssertEqual(usage.totalTokens, 24_000)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2.0)
    }

    func testBatchParserDecodesOnlyCompleteTokenLinesFromLargeBuffer() {
        let start = ISO8601DateFormatter().date(from: "2026-07-31T16:00:00Z")!
        let interval = DateInterval(start: start, duration: 86_400)
        let privateText = String(repeating: "private message payload ", count: 80)
        let unrelated = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"message","content":"\#(privateText)"}}"#
        let token = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":12}}}}"#
        let buffer = Data(
            ((Array(repeating: unrelated, count: 10_000) + [token, token]).joined(separator: "\n")
                + "\n" + token).utf8
        )
        let decoder = CountingDailyTokenEventDecoder()
        let startedAt = Date()

        let events = DailyTokenLogParser.parseCompleteLines(
            in: buffer,
            inside: interval,
            decoder: decoder
        )

        XCTAssertEqual(decoder.decodeCount, 2)
        XCTAssertEqual(events.reduce(0) { $0 + $1.usage.totalTokens }, 24)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
    }

    func testBatchParserStructurallyRejectsPromptCandidatesAndKeepsPartialBoundary() {
        let start = ISO8601DateFormatter().date(from: "2026-07-31T16:00:00Z")!
        let interval = DateInterval(start: start, duration: 86_400)
        let whitespaceToken = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type" : "token_count","info":{"last_token_usage":{"total_tokens":10}}}}"#
        let escapedToken = #"{"timestamp":"2026-08-01T02:01:00Z","payload":{"type":"token_\u0063ount","info":{"last_token_usage":{"total_tokens":20}}}}"#
        let literalPrompt = #"{"timestamp":"2026-08-01T02:02:00Z","payload":{"type":"message","content":"private prompt says token_count"}}"#
        let escapedPrompt = #"{"timestamp":"2026-08-01T02:03:00Z","payload":{"type":"message","content":"private prompt says token_\u0063ount"}}"#
        let partialToken = #"{"timestamp":"2026-08-01T02:04:00Z","payload":{"type":"token_\u0063ount","info":{"last_token_usage":{"total_tokens":40}}}}"#
        let buffer = Data(
            ([whitespaceToken, escapedToken, literalPrompt, escapedPrompt].joined(separator: "\n")
                + "\n" + partialToken).utf8
        )
        let decoder = CountingDailyTokenEventDecoder()

        let events = DailyTokenLogParser.parseCompleteLines(
            in: buffer,
            inside: interval,
            decoder: decoder
        )

        XCTAssertEqual(events.map(\.usage.totalTokens), [10, 20])
        XCTAssertEqual(decoder.decodeCount, 4)
    }

    func testNonTokenPayloadWithTokenMarkersAndUsageMetricsCountsZero() {
        let start = ISO8601DateFormatter().date(from: "2026-07-31T16:00:00Z")!
        let interval = DateInterval(start: start, duration: 86_400)
        let line = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"message","content":"literal token_count and escaped token_\u0063ount","info":{"last_token_usage":{"input_tokens":900,"cached_input_tokens":800,"output_tokens":100,"reasoning_output_tokens":20,"total_tokens":1000}}}}"#

        let events = DailyTokenLogParser.parseCompleteLines(
            in: Data((line + "\n").utf8),
            inside: interval
        )

        XCTAssertEqual(events.reduce(0) { $0 + $1.usage.totalTokens }, 0)
    }

    func testBatchSemanticCandidateScanStaysLinearAtScale() {
        let start = ISO8601DateFormatter().date(from: "2026-07-31T16:00:00Z")!
        let interval = DateInterval(start: start, duration: 86_400)
        let privateText = String(repeating: "unrelated private payload ", count: 400)
        let unrelated = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"message","content":"\#(privateText)"}}"#
        let token = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1}}}}"#
        let group = token + "\n" + unrelated + "\n"
        let buffer = Data(String(repeating: group, count: 500).utf8)
        let startedAt = Date()

        let events = DailyTokenLogParser.parseCompleteLines(in: buffer, inside: interval)

        XCTAssertEqual(events.count, 500)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.25)
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

    func testCompositionFractionsUseTotalWithoutReasoningDuplication() {
        let usage = DailyTokenUsage(
            totalTokens: 1_000,
            cachedInputTokens: 700,
            nonCachedInputTokens: 200,
            outputTokens: 100,
            reasoningOutputTokens: 40,
            latestEventAt: nil
        )

        XCTAssertEqual(usage.cachedFraction, 0.7, accuracy: 0.0001)
        XCTAssertEqual(usage.nonCachedFraction, 0.2, accuracy: 0.0001)
        XCTAssertEqual(usage.outputFraction, 0.1, accuracy: 0.0001)
        XCTAssertEqual(usage.cachedFraction + usage.nonCachedFraction + usage.outputFraction, 1, accuracy: 0.0001)
    }

    func testCompositionFractionsNormalizeInconsistentComponentTotals() {
        let usage = DailyTokenUsage(
            totalTokens: 100,
            cachedInputTokens: 100,
            nonCachedInputTokens: 50,
            outputTokens: 50,
            reasoningOutputTokens: 25,
            latestEventAt: nil
        )

        XCTAssertEqual(usage.cachedFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(usage.nonCachedFraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(usage.outputFraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(usage.cachedFraction + usage.nonCachedFraction + usage.outputFraction, 1, accuracy: 0.0001)
    }

    func testExactFormattingMakesOneTokenDifferenceVisible() {
        XCTAssertEqual(TokenCountFormatter.exact(520_778_892), "520,778,892")
        XCTAssertEqual(TokenCountFormatter.exact(520_778_893), "520,778,893")
    }

    func testCompactChineseFormattingUsesUsefulPrecision() {
        XCTAssertEqual(TokenCountFormatter.compact(9_999), "9,999")
        XCTAssertEqual(TokenCountFormatter.compact(10_000), "1.00万")
        XCTAssertEqual(TokenCountFormatter.compact(7_986_313), "798.63万")
        XCTAssertEqual(TokenCountFormatter.compact(100_000_000), "1.000亿")
        XCTAssertEqual(TokenCountFormatter.compact(520_778_892), "5.208亿")
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

    func testConcurrentCurrentUsageCallsSerializeTheFullProviderTransition() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let line = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        try (line + "\n").write(
            to: root.appendingPathComponent("rollout-concurrent.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let reader = BlockingCountingDailyTokenFileReader()
        let provider = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            fileReader: reader
        )
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        let results = LockedDailyTokenResults()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "daily-token-concurrency", attributes: .concurrent)

        group.enter()
        queue.async {
            results.record { try provider.currentUsage(now: now) }
            group.leave()
        }
        XCTAssertTrue(reader.waitForReadCount(1, timeout: 2))

        let secondCallStarted = DispatchSemaphore(value: 0)
        group.enter()
        queue.async {
            secondCallStarted.signal()
            results.record { try provider.currentUsage(now: now) }
            group.leave()
        }
        XCTAssertEqual(secondCallStarted.wait(timeout: .now() + 2), .success)
        let secondReadEnteredBeforeRelease = reader.waitForReadCount(2, timeout: 0.5)
        reader.releaseFirstRead()
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)

        XCTAssertFalse(secondReadEnteredBeforeRelease)
        XCTAssertEqual(reader.maxActiveReads, 1)
        XCTAssertEqual(reader.totalReadCount, 1)
        XCTAssertEqual(results.snapshot.failures, 0)
        XCTAssertEqual(results.snapshot.usages.map(\.totalTokens).sorted(), [100, 100])
    }

    func testRestartedProviderUsesPersistentAggregateWithoutReadingUnchangedBytes() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("sessions")
        let cache = base.appendingPathComponent("cache/daily-tokens.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = root.appendingPathComponent("rollout-cached.jsonl")
        let line = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":90,"cached_input_tokens":80,"output_tokens":10,"reasoning_output_tokens":2,"total_tokens":100}}}}"#
        try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
        let reader = RecordingDailyTokenFileReader()
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!

        let first = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            fileReader: reader,
            cacheURL: cache
        )
        XCTAssertEqual(try first.currentUsage(now: now).totalTokens, 100)
        XCTAssertGreaterThan(reader.totalBytesRead, 0)

        reader.reset()
        let restarted = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            fileReader: reader,
            cacheURL: cache
        )

        XCTAssertEqual(try restarted.currentUsage(now: now).totalTokens, 100)
        XCTAssertEqual(reader.totalBytesRead, 0)
        XCTAssertTrue(reader.offsets.isEmpty)
        XCTAssertEqual(reader.boundaryBytesRead, 1)
        XCTAssertEqual(reader.boundaryByteOffsets, [UInt64(Data((line + "\n").utf8).count - 1)])
    }

    func testRestartedProviderRereadsUnterminatedTailFromCompleteLineBoundary() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("sessions")
        let cache = base.appendingPathComponent("cache/daily-tokens.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = root.appendingPathComponent("rollout-partial.jsonl")
        let first = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        let sentinel = "PRIVATE_TAIL_SENTINEL"
        let partial = #"{"content":"\#(sentinel)","timestamp":"2026-08-01T02:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":200}}}}"#
        let sentinelRange = try XCTUnwrap(partial.range(of: sentinel))
        let split = partial.index(sentinelRange.upperBound, offsetBy: 1)
        XCTAssertTrue(String(partial[..<split]).contains(sentinel))
        let completePrefix = Data((first + "\n").utf8)
        try (completePrefix + Data(partial[..<split].utf8)).write(to: file)
        let reader = RecordingDailyTokenFileReader()
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!

        let firstProvider = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            fileReader: reader,
            cacheURL: cache
        )
        XCTAssertEqual(try firstProvider.currentUsage(now: now).totalTokens, 100)
        XCTAssertFalse(
            String(decoding: try Data(contentsOf: cache), as: UTF8.self)
                .contains(sentinel)
        )

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(partial[split...]) + "\n").utf8))
        try handle.close()
        reader.reset()

        let restarted = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            fileReader: reader,
            cacheURL: cache
        )

        XCTAssertEqual(try restarted.currentUsage(now: now).totalTokens, 300)
        XCTAssertEqual(reader.offsets, [UInt64(completePrefix.count)])
        XCTAssertEqual(reader.totalBytesRead, Data((partial + "\n").utf8).count)
        XCTAssertEqual(reader.boundaryBytesRead, 1)
        XCTAssertEqual(reader.boundaryByteOffsets, [UInt64(completePrefix.count - 1)])
    }

    func testRestartedProviderReadsOnlyBytesAppendedAfterCachedBoundary() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("sessions")
        let cache = base.appendingPathComponent("cache/daily-tokens.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = root.appendingPathComponent("rollout-appended.jsonl")
        let first = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        let appended = #"{"timestamp":"2026-08-01T02:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":200}}}}"#
        let firstData = Data((first + "\n").utf8)
        let appendedData = Data((appended + "\n").utf8)
        try firstData.write(to: file)
        let reader = RecordingDailyTokenFileReader()
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        let seed = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            fileReader: reader,
            cacheURL: cache
        )
        XCTAssertEqual(try seed.currentUsage(now: now).totalTokens, 100)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: appendedData)
        try handle.close()
        reader.reset()
        let restarted = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            fileReader: reader,
            cacheURL: cache
        )

        XCTAssertEqual(try restarted.currentUsage(now: now).totalTokens, 300)
        XCTAssertEqual(reader.offsets, [UInt64(firstData.count)])
        XCTAssertEqual(reader.totalBytesRead, appendedData.count)
        XCTAssertEqual(reader.boundaryBytesRead, 1)
        XCTAssertEqual(reader.boundaryByteOffsets, [UInt64(firstData.count - 1)])
        reader.reset()
        XCTAssertEqual(try restarted.currentUsage(now: now).totalTokens, 300)
        XCTAssertEqual(reader.totalBytesRead, 0)
        XCTAssertEqual(reader.boundaryBytesRead, 0)
    }

    func testRestartedProviderRebuildsNearLimitCachedCursorWhenValidAppendWouldOverflow() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("sessions")
        let cache = base.appendingPathComponent("cache/daily-tokens.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = root.appendingPathComponent("rollout-near-limit-cache.jsonl")
        let first = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        let appended = #"{"timestamp":"2026-08-01T02:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":200}}}}"#
        let firstData = Data((first + "\n").utf8)
        let appendedData = Data((appended + "\n").utf8)
        try firstData.write(to: file)
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        let seed = DailyTokenUsageProvider(roots: [root], calendar: calendar, cacheURL: cache)
        XCTAssertEqual(try seed.currentUsage(now: now).totalTokens, 100)
        try mutateJSONCache(at: cache) { object in
            var cursors = try XCTUnwrap(object["cursors"] as? [[String: Any]])
            var usage = try XCTUnwrap(cursors[0]["usage"] as? [String: Any])
            usage["totalTokens"] = Int64.max - 100
            cursors[0]["usage"] = usage
            object["cursors"] = cursors
        }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: appendedData)
        try handle.close()
        let reader = RecordingDailyTokenFileReader()
        let restarted = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            fileReader: reader,
            cacheURL: cache
        )

        XCTAssertEqual(try restarted.currentUsage(now: now).totalTokens, 300)
        XCTAssertEqual(reader.offsets, [UInt64(firstData.count), 0])
        XCTAssertEqual(reader.totalBytesRead, appendedData.count + firstData.count + appendedData.count)
        XCTAssertEqual(reader.boundaryBytesRead, 1)
        XCTAssertEqual(reader.boundaryByteOffsets, [UInt64(firstData.count - 1)])
    }

    func testProviderThrowsInsteadOfTrappingWhenOneFileAggregateOverflows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":9223372036854775806}}}}"#
        let second = #"{"timestamp":"2026-08-01T02:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":2}}}}"#
        try (first + "\n" + second + "\n").write(
            to: root.appendingPathComponent("rollout-file-overflow.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let provider = DailyTokenUsageProvider(roots: [root], calendar: calendar)
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!

        XCTAssertThrowsError(try provider.currentUsage(now: now)) { error in
            XCTAssertEqual(error as? DailyTokenUsageProviderError, .aggregateOverflow)
        }
    }

    func testProviderRejectsOneFileAggregateThatEqualsInt64Max() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":9223372036854775797}}}}"#
        let second = #"{"timestamp":"2026-08-01T02:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":10}}}}"#
        try (first + "\n" + second + "\n").write(
            to: root.appendingPathComponent("rollout-file-exact-limit.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let provider = DailyTokenUsageProvider(roots: [root], calendar: calendar)
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!

        XCTAssertThrowsError(try provider.currentUsage(now: now)) { error in
            XCTAssertEqual(error as? DailyTokenUsageProviderError, .aggregateOverflow)
        }
    }

    func testProviderThrowsInsteadOfTrappingWhenPostUpdateCrossFileAggregateOverflows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let line = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":4611686018427387904}}}}"#
        for name in ["a", "b"] {
            try (line + "\n").write(
                to: root.appendingPathComponent("rollout-cross-file-overflow-\(name).jsonl"),
                atomically: true,
                encoding: .utf8
            )
        }
        let provider = DailyTokenUsageProvider(roots: [root], calendar: calendar)
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!

        XCTAssertThrowsError(try provider.currentUsage(now: now)) { error in
            XCTAssertEqual(error as? DailyTokenUsageProviderError, .aggregateOverflow)
        }
    }

    func testSerializedCacheDoesNotContainPrivateSourceSentinel() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("sessions")
        let cache = base.appendingPathComponent("cache/daily-tokens.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let sentinel = "PRIVATE_PROMPT_REPLY_AUTH_SENTINEL"
        let line = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}},"content":"\#(sentinel)"}}"#
        try (line + "\n").write(
            to: root.appendingPathComponent("rollout-private.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        let provider = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            cacheURL: cache
        )

        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 100)
        let serialized = try Data(contentsOf: cache)
        XCTAssertFalse(String(decoding: serialized, as: UTF8.self).contains(sentinel))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: serialized) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            ["schemaVersion", "dayStart", "rootsFingerprint", "cursors"]
        )
        let cursors = try XCTUnwrap(object["cursors"] as? [[String: Any]])
        let cursor = try XCTUnwrap(cursors.first)
        XCTAssertEqual(
            Set(cursor.keys),
            ["path", "basename", "identity", "completeLineOffset", "usage"]
        )
        let identity = try XCTUnwrap(cursor["identity"] as? [String: Any])
        XCTAssertEqual(Set(identity.keys), ["systemNumber", "fileNumber"])
        let usage = try XCTUnwrap(cursor["usage"] as? [String: Any])
        XCTAssertEqual(
            Set(usage.keys),
            [
                "totalTokens",
                "cachedInputTokens",
                "nonCachedInputTokens",
                "outputTokens",
                "reasoningOutputTokens",
                "latestEventAt"
            ]
        )
    }

    func testRestartedProviderRejectsCacheFromWrongLocalDay() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("sessions")
        let cache = base.appendingPathComponent("cache/daily-tokens.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = root.appendingPathComponent("rollout-day.jsonl")
        let previous = #"{"timestamp":"2026-07-31T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        let today = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":200}}}}"#
        try (previous + "\n").write(to: file, atomically: false, encoding: .utf8)
        let previousNow = ISO8601DateFormatter().date(from: "2026-07-31T03:00:00Z")!
        let todayNow = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        let seed = DailyTokenUsageProvider(roots: [root], calendar: calendar, cacheURL: cache)
        XCTAssertEqual(try seed.currentUsage(now: previousNow).totalTokens, 100)

        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((today + "\n").utf8))
        try handle.close()
        let reader = RecordingDailyTokenFileReader()
        let restarted = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            fileReader: reader,
            cacheURL: cache
        )

        XCTAssertEqual(try restarted.currentUsage(now: todayNow).totalTokens, 200)
        XCTAssertGreaterThan(reader.totalBytesRead, 0)
    }

    func testRestartedProviderRebuildsFromLogsWhenCacheIsCorrupt() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("sessions")
        let cache = base.appendingPathComponent("cache/daily-tokens.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let line = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        try (line + "\n").write(
            to: root.appendingPathComponent("rollout-corrupt.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        let seed = DailyTokenUsageProvider(roots: [root], calendar: calendar, cacheURL: cache)
        XCTAssertEqual(try seed.currentUsage(now: now).totalTokens, 100)
        try Data("not valid cache data".utf8).write(to: cache)
        let reader = RecordingDailyTokenFileReader()
        let restarted = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            fileReader: reader,
            cacheURL: cache
        )

        XCTAssertEqual(try restarted.currentUsage(now: now).totalTokens, 100)
        XCTAssertGreaterThan(reader.totalBytesRead, 0)
    }

    func testRestartedProviderRejectsCachedReasoningGreaterThanOutput() throws {
        let result = try restartedUsageAfterMutatingCachedUsage { usage in
            usage["reasoningOutputTokens"] = 21
        }

        XCTAssertEqual(result.usage.totalTokens, 120)
        XCTAssertEqual(result.usage.reasoningOutputTokens, 5)
        XCTAssertEqual(result.readOffsets, [0])
    }

    func testRestartedProviderRejectsCachedComponentsExceedingTotal() throws {
        let result = try restartedUsageAfterMutatingCachedUsage { usage in
            usage["cachedInputTokens"] = 80
        }

        XCTAssertEqual(result.usage.totalTokens, 120)
        XCTAssertEqual(result.usage.cachedInputTokens, 40)
        XCTAssertEqual(result.readOffsets, [0])
    }

    func testRestartedProviderRejectsPositiveCachedUsageWithoutLatestEvent() throws {
        let result = try restartedUsageAfterMutatingCachedUsage { usage in
            usage["latestEventAt"] = NSNull()
        }

        XCTAssertEqual(result.usage.totalTokens, 120)
        XCTAssertNotNil(result.usage.latestEventAt)
        XCTAssertEqual(result.readOffsets, [0])
    }

    func testRestartedProviderRejectsExtremeCachedAggregate() throws {
        let result = try restartedUsageAfterMutatingCachedUsage { usage in
            usage["totalTokens"] = Int64.max
        }

        XCTAssertEqual(result.usage.totalTokens, 120)
        XCTAssertEqual(result.readOffsets, [0])
    }

    func testRestartedProviderRejectsCachedAggregateThatOverflowsAcrossFiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("sessions")
        let cache = base.appendingPathComponent("cache/daily-tokens.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let first = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        let second = #"{"timestamp":"2026-08-01T02:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":200}}}}"#
        try (first + "\n").write(
            to: root.appendingPathComponent("rollout-overflow-a.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try (second + "\n").write(
            to: root.appendingPathComponent("rollout-overflow-b.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        let seed = DailyTokenUsageProvider(roots: [root], calendar: calendar, cacheURL: cache)
        XCTAssertEqual(try seed.currentUsage(now: now).totalTokens, 300)
        try mutateJSONCache(at: cache) { object in
            var cursors = try XCTUnwrap(object["cursors"] as? [[String: Any]])
            for index in cursors.indices {
                var usage = try XCTUnwrap(cursors[index]["usage"] as? [String: Any])
                usage["totalTokens"] = Int64.max / 2 + 1
                cursors[index]["usage"] = usage
            }
            object["cursors"] = cursors
        }
        let reader = RecordingDailyTokenFileReader()
        let restarted = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            fileReader: reader,
            cacheURL: cache
        )

        XCTAssertEqual(try restarted.currentUsage(now: now).totalTokens, 300)
        XCTAssertEqual(reader.offsets.sorted(), [0, 0])
    }

    func testRestartedProviderRejectsCachedAggregateThatEqualsInt64MaxAcrossFiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("sessions")
        let cache = base.appendingPathComponent("cache/daily-tokens.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let first = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        let second = #"{"timestamp":"2026-08-01T02:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":200}}}}"#
        try (first + "\n").write(
            to: root.appendingPathComponent("rollout-exact-limit-a.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try (second + "\n").write(
            to: root.appendingPathComponent("rollout-exact-limit-b.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        let seed = DailyTokenUsageProvider(roots: [root], calendar: calendar, cacheURL: cache)
        XCTAssertEqual(try seed.currentUsage(now: now).totalTokens, 300)
        try mutateJSONCache(at: cache) { object in
            var cursors = try XCTUnwrap(object["cursors"] as? [[String: Any]])
            var firstUsage = try XCTUnwrap(cursors[0]["usage"] as? [String: Any])
            var secondUsage = try XCTUnwrap(cursors[1]["usage"] as? [String: Any])
            firstUsage["totalTokens"] = Int64.max / 2
            secondUsage["totalTokens"] = Int64.max - Int64.max / 2
            cursors[0]["usage"] = firstUsage
            cursors[1]["usage"] = secondUsage
            object["cursors"] = cursors
        }
        let reader = RecordingDailyTokenFileReader()
        let restarted = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            fileReader: reader,
            cacheURL: cache
        )

        XCTAssertEqual(try restarted.currentUsage(now: now).totalTokens, 300)
        XCTAssertEqual(reader.offsets.sorted(), [0, 0])
    }

    func testRestartedProviderRejectsNegativeCachedAggregateComponent() throws {
        let result = try restartedUsageAfterMutatingCachedUsage { usage in
            usage["cachedInputTokens"] = -1
        }

        XCTAssertEqual(result.usage.cachedInputTokens, 40)
        XCTAssertEqual(result.readOffsets, [0])
    }

    func testRestartedProviderRejectsCachedLatestEventOutsideLocalDay() throws {
        let outsideDay = ISO8601DateFormatter().date(from: "2026-07-31T15:59:59Z")!
        let result = try restartedUsageAfterMutatingCachedUsage { usage in
            usage["latestEventAt"] = outsideDay.timeIntervalSinceReferenceDate
        }

        XCTAssertEqual(
            result.usage.latestEventAt,
            ISO8601DateFormatter().date(from: "2026-08-01T02:00:00Z")
        )
        XCTAssertEqual(result.readOffsets, [0])
    }

    func testRestartedProviderRejectsOverflowingCachedComponentSum() throws {
        let result = try restartedUsageAfterMutatingCachedUsage { usage in
            usage["cachedInputTokens"] = Int64.max - 5
            usage["nonCachedInputTokens"] = 10
            usage["outputTokens"] = 0
            usage["reasoningOutputTokens"] = 0
            usage["totalTokens"] = Int64.max - 1
        }

        XCTAssertEqual(result.usage.totalTokens, 120)
        XCTAssertEqual(result.readOffsets, [0])
    }

    func testRestartedProviderRejectsCacheForDifferentRoots() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nestedRoot = base.appendingPathComponent("sessions")
        let cache = base.appendingPathComponent("cache/daily-tokens.json")
        try FileManager.default.createDirectory(at: nestedRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let line = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        try (line + "\n").write(
            to: nestedRoot.appendingPathComponent("rollout-roots.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        let seed = DailyTokenUsageProvider(roots: [base], calendar: calendar, cacheURL: cache)
        XCTAssertEqual(try seed.currentUsage(now: now).totalTokens, 100)
        let reader = RecordingDailyTokenFileReader()
        let restarted = DailyTokenUsageProvider(
            roots: [nestedRoot],
            calendar: calendar,
            fileReader: reader,
            cacheURL: cache
        )

        XCTAssertEqual(try restarted.currentUsage(now: now).totalTokens, 100)
        XCTAssertGreaterThan(reader.totalBytesRead, 0)
    }

    func testRestartedProviderRejectsUnknownCacheSchema() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("sessions")
        let cache = base.appendingPathComponent("cache/daily-tokens.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let line = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        try (line + "\n").write(
            to: root.appendingPathComponent("rollout-schema.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        let seed = DailyTokenUsageProvider(roots: [root], calendar: calendar, cacheURL: cache)
        XCTAssertEqual(try seed.currentUsage(now: now).totalTokens, 100)
        try mutateJSONCache(at: cache) { $0["schemaVersion"] = 999 }
        let reader = RecordingDailyTokenFileReader()
        let restarted = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            fileReader: reader,
            cacheURL: cache
        )

        XCTAssertEqual(try restarted.currentUsage(now: now).totalTokens, 100)
        XCTAssertGreaterThan(reader.totalBytesRead, 0)
    }

    func testRestartedProviderRebuildsCursorWithImpossibleCachedOffset() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("sessions")
        let cache = base.appendingPathComponent("cache/daily-tokens.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let line = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        try (line + "\n").write(
            to: root.appendingPathComponent("rollout-offset.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        let seed = DailyTokenUsageProvider(roots: [root], calendar: calendar, cacheURL: cache)
        XCTAssertEqual(try seed.currentUsage(now: now).totalTokens, 100)
        try mutateJSONCache(at: cache) { object in
            var cursors = try XCTUnwrap(object["cursors"] as? [[String: Any]])
            cursors[0]["completeLineOffset"] = 9_999_999
            object["cursors"] = cursors
        }
        let reader = RecordingDailyTokenFileReader()
        let restarted = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            fileReader: reader,
            cacheURL: cache
        )

        XCTAssertEqual(try restarted.currentUsage(now: now).totalTokens, 100)
        XCTAssertEqual(reader.offsets, [0])
    }

    func testRestartedProviderRebuildsCursorWithInRangeMidLineCachedOffset() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("sessions")
        let cache = base.appendingPathComponent("cache/daily-tokens.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = root.appendingPathComponent("rollout-mid-line-offset.jsonl")
        let first = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        let second = #"{"timestamp":"2026-08-01T02:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":200}}}}"#
        let firstData = Data((first + "\n").utf8)
        try (first + "\n" + second + "\n").write(to: file, atomically: false, encoding: .utf8)
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        let seed = DailyTokenUsageProvider(roots: [root], calendar: calendar, cacheURL: cache)
        XCTAssertEqual(try seed.currentUsage(now: now).totalTokens, 300)
        let midLineOffset = firstData.count + 10
        try mutateJSONCache(at: cache) { object in
            var cursors = try XCTUnwrap(object["cursors"] as? [[String: Any]])
            cursors[0]["completeLineOffset"] = midLineOffset
            var usage = try XCTUnwrap(cursors[0]["usage"] as? [String: Any])
            usage["totalTokens"] = 100
            cursors[0]["usage"] = usage
            object["cursors"] = cursors
        }
        let reader = RecordingDailyTokenFileReader()
        let restarted = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            fileReader: reader,
            cacheURL: cache
        )

        XCTAssertEqual(try restarted.currentUsage(now: now).totalTokens, 300)
        XCTAssertEqual(reader.offsets, [0])
        XCTAssertEqual(reader.boundaryBytesRead, 1)
        XCTAssertEqual(reader.boundaryByteOffsets, [UInt64(midLineOffset - 1)])
    }

    func testRestartedProviderRebuildsWhenCachedPathHasNewFilesystemIdentity() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("sessions")
        let cache = base.appendingPathComponent("cache/daily-tokens.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = root.appendingPathComponent("rollout-identity.jsonl")
        let replacement = base.appendingPathComponent("replacement.jsonl")
        let first = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        let second = #"{"timestamp":"2026-08-01T02:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":225,"cached_input_tokens":25,"output_tokens":25,"total_tokens":250}}}}"#
        try (first + "\n").write(to: file, atomically: true, encoding: .utf8)
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        let seed = DailyTokenUsageProvider(roots: [root], calendar: calendar, cacheURL: cache)
        XCTAssertEqual(try seed.currentUsage(now: now).totalTokens, 100)
        try (second + "\n").write(to: replacement, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: replacement, to: file)
        let reader = RecordingDailyTokenFileReader()
        let restarted = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            fileReader: reader,
            cacheURL: cache
        )

        XCTAssertEqual(try restarted.currentUsage(now: now).totalTokens, 250)
        XCTAssertEqual(reader.offsets, [0])
    }

    func testRestartedProviderRebuildsWhenCachedFileWasTruncated() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("sessions")
        let cache = base.appendingPathComponent("cache/daily-tokens.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = root.appendingPathComponent("rollout-truncated-cache.jsonl")
        let first = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        let second = #"{"timestamp":"2026-08-01T02:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":200}}}}"#
        let replacement = #"{"timestamp":"2026-08-01T02:10:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":400}}}}"#
        try (first + "\n" + second + "\n").write(to: file, atomically: false, encoding: .utf8)
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        let seed = DailyTokenUsageProvider(roots: [root], calendar: calendar, cacheURL: cache)
        XCTAssertEqual(try seed.currentUsage(now: now).totalTokens, 300)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((replacement + "\n").utf8))
        try handle.close()
        let reader = RecordingDailyTokenFileReader()
        let restarted = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            fileReader: reader,
            cacheURL: cache
        )

        XCTAssertEqual(try restarted.currentUsage(now: now).totalTokens, 400)
        XCTAssertEqual(reader.offsets, [0])
    }

    func testRestartedProviderPrunesDisappearedCursorAndCountsNewFile() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("sessions")
        let cache = base.appendingPathComponent("cache/daily-tokens.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let original = root.appendingPathComponent("rollout-disappeared.jsonl")
        let newFile = root.appendingPathComponent("rollout-new.jsonl")
        let first = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        let second = #"{"timestamp":"2026-08-01T02:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":200}}}}"#
        try (first + "\n").write(to: original, atomically: true, encoding: .utf8)
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        let seed = DailyTokenUsageProvider(roots: [root], calendar: calendar, cacheURL: cache)
        XCTAssertEqual(try seed.currentUsage(now: now).totalTokens, 100)
        try FileManager.default.removeItem(at: original)
        try (second + "\n").write(to: newFile, atomically: true, encoding: .utf8)
        let restarted = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            cacheURL: cache
        )

        XCTAssertEqual(try restarted.currentUsage(now: now).totalTokens, 200)
        XCTAssertEqual(try restarted.currentUsage(now: now).totalTokens, 200)
    }

    func testCacheWriteFailureDoesNotDiscardComputedLiveUsage() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("sessions")
        let blockedParent = base.appendingPathComponent("not-a-directory")
        let cache = blockedParent.appendingPathComponent("daily-tokens.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("blocking file".utf8).write(to: blockedParent)
        defer { try? FileManager.default.removeItem(at: base) }
        let line = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        try (line + "\n").write(
            to: root.appendingPathComponent("rollout-write-failure.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        let provider = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            cacheURL: cache
        )

        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 100)
        XCTAssertEqual(try Data(contentsOf: blockedParent), Data("blocking file".utf8))
    }

    func testCustomRootsDoNotUseProductionCacheByDefault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let line = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        try (line + "\n").write(
            to: root.appendingPathComponent("rollout-custom-root.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        let first = DailyTokenUsageProvider(roots: [root], calendar: calendar)
        XCTAssertEqual(try first.currentUsage(now: now).totalTokens, 100)
        let reader = RecordingDailyTokenFileReader()
        let restarted = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            fileReader: reader
        )

        XCTAssertEqual(try restarted.currentUsage(now: now).totalTokens, 100)
        XCTAssertGreaterThan(reader.totalBytesRead, 0)
    }

    func testProviderTreatsMissingRootAsLegitimateEmptyFirstRun() throws {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let provider = DailyTokenUsageProvider(roots: [missingRoot], calendar: calendar)
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!

        XCTAssertEqual(try provider.currentUsage(now: now), .zero)
    }

    func testProviderThrowsWhenExistingRootTraversalCannotStart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = DailyTokenUsageProvider(roots: [root], calendar: calendar)
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!

        XCTAssertThrowsError(try provider.currentUsage(now: now))
    }

    func testProviderThrowsWhenTraversalReportsReadError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("inaccessible".utf8).write(to: root.appendingPathComponent("rollout.jsonl"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let provider = DailyTokenUsageProvider(roots: [root], calendar: calendar)
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!

        XCTAssertThrowsError(try provider.currentUsage(now: now))
    }

    func testProviderDoesNotTreatRootMetadataAccessFailureAsMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = RootMetadataErrorFileManager(targetRoot: root)
        let provider = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            fileManager: fileManager
        )
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!

        XCTAssertThrowsError(try provider.currentUsage(now: now))
    }

    func testProviderAdvancesCursorByBytesActuallyReadWhenFileGrowsAfterStat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-growing.jsonl")
        let first = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        let appended = #"{"timestamp":"2026-08-01T02:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":200}}}}"#
        try (first + "\n").write(to: file, atomically: true, encoding: .utf8)
        let fileManager = AppendingAfterStatFileManager(
            target: file,
            appendedData: Data((appended + "\n").utf8)
        )
        let provider = DailyTokenUsageProvider(
            roots: [root],
            calendar: calendar,
            fileManager: fileManager
        )
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!

        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 300)
        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 300)
    }

    func testProviderRebuildsUsageWhenFileIsReplacedByLargerFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-replaced.jsonl")
        let replacement = root.appendingPathComponent("replacement.tmp")
        let first = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        let replacementLine = #"{"timestamp":"2026-08-01T02:10:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":225,"cached_input_tokens":25,"output_tokens":25,"reasoning_output_tokens":5,"total_tokens":250}}}}"#
        try (first + "\n").write(to: file, atomically: true, encoding: .utf8)
        let provider = DailyTokenUsageProvider(roots: [root], calendar: calendar)
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 100)

        try (replacementLine + "\n").write(to: replacement, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: replacement, to: file)

        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 250)
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
        let beforeMidnight = ISO8601DateFormatter().date(from: "2026-07-31T15:59:59Z")!
        let afterMidnight = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!

        XCTAssertEqual(try provider.currentUsage(now: beforeMidnight).totalTokens, 100)
        XCTAssertEqual(try provider.currentUsage(now: afterMidnight).totalTokens, 200)
    }

    func testProviderRebuildsUsageAfterSameFileIsTruncated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-truncated.jsonl")
        let first = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        let second = #"{"timestamp":"2026-08-01T02:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":200}}}}"#
        let replacement = #"{"timestamp":"2026-08-01T02:10:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":400}}}}"#
        try (first + "\n" + second + "\n").write(to: file, atomically: true, encoding: .utf8)
        let provider = DailyTokenUsageProvider(roots: [root], calendar: calendar)
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 300)

        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((replacement + "\n").utf8))
        try handle.close()

        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 400)
    }

    func testProviderPreservesCursorWhenRolloutMovesFromActiveToArchive() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let active = base.appendingPathComponent("sessions")
        let archived = base.appendingPathComponent("archived")
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let activeFile = active.appendingPathComponent("rollout-moved.jsonl")
        let archivedFile = archived.appendingPathComponent("rollout-moved.jsonl")
        let first = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        let appended = #"{"timestamp":"2026-08-01T02:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":200}}}}"#
        try (first + "\n").write(to: activeFile, atomically: true, encoding: .utf8)
        let provider = DailyTokenUsageProvider(roots: [active, archived], calendar: calendar)
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 100)

        try FileManager.default.moveItem(at: activeFile, to: archivedFile)
        let handle = try FileHandle(forWritingTo: archivedFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((appended + "\n").utf8))
        try handle.close()

        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 300)
        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 300)
    }

    func testProviderPreservesCursorWhenSameFileMovesToDifferentBasename() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let active = base.appendingPathComponent("sessions")
        let archived = base.appendingPathComponent("archived")
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let activeFile = active.appendingPathComponent("rollout-original.jsonl")
        let archivedFile = archived.appendingPathComponent("renamed-archive.jsonl")
        let first = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        let appended = #"{"timestamp":"2026-08-01T02:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":200}}}}"#
        try (first + "\n").write(to: activeFile, atomically: true, encoding: .utf8)
        let provider = DailyTokenUsageProvider(roots: [active, archived], calendar: calendar)
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 100)

        try FileManager.default.moveItem(at: activeFile, to: archivedFile)
        let handle = try FileHandle(forWritingTo: archivedFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((appended + "\n").utf8))
        try handle.close()

        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 300)
        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 300)
    }

    func testProviderDropsDisappearedCursorAndRebuildsCopyReplacementOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("rollout-original.jsonl")
        let replacement = root.appendingPathComponent("rollout-copy.jsonl")
        let first = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        let appended = #"{"timestamp":"2026-08-01T02:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":200}}}}"#
        try (first + "\n").write(to: original, atomically: true, encoding: .utf8)
        let provider = DailyTokenUsageProvider(roots: [root], calendar: calendar)
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 100)

        try FileManager.default.copyItem(at: original, to: replacement)
        let handle = try FileHandle(forWritingTo: replacement)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((appended + "\n").utf8))
        try handle.close()
        try FileManager.default.removeItem(at: original)

        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 300)
        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 300)
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

    func testProviderIncludesPreviousLocalDayCrossMidnightFiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = base.appendingPathComponent("sessions")
        let archived = base.appendingPathComponent("archived_sessions")
        let previousDaySessions = sessions.appendingPathComponent("2026/07/31")
        try FileManager.default.createDirectory(at: previousDaySessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let sessionEvent = #"{"timestamp":"2026-07-31T16:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        let archivedEvent = #"{"timestamp":"2026-07-31T16:10:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":200}}}}"#
        try (sessionEvent + "\n").write(
            to: previousDaySessions.appendingPathComponent("rollout-2026-07-31T23-00-session.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try (archivedEvent + "\n").write(
            to: archived.appendingPathComponent("rollout-2026-07-31T23-30-archive.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let provider = DailyTokenUsageProvider(
            roots: [sessions, archived],
            calendar: calendar
        )
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!

        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 300)
    }

    func testProviderIncludesTodaysEventFromOlderStartedFiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = base.appendingPathComponent("sessions")
        let archived = base.appendingPathComponent("archived_sessions")
        let olderSessions = sessions.appendingPathComponent("2026/07/30")
        try FileManager.default.createDirectory(at: olderSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let currentDayEvent = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
        try (currentDayEvent + "\n").write(
            to: olderSessions.appendingPathComponent("rollout-2026-07-30T23-00-session.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try (currentDayEvent + "\n").write(
            to: archived.appendingPathComponent("rollout-2026-07-30T23-30-archive.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try (currentDayEvent + "\n").write(
            to: olderSessions.appendingPathComponent("rollout-2026-07-30T23-00-session.txt"),
            atomically: true,
            encoding: .utf8
        )
        try (currentDayEvent + "\n").write(
            to: archived.appendingPathComponent("rollout-2026-07-30T23-30-archive.txt"),
            atomically: true,
            encoding: .utf8
        )
        let provider = DailyTokenUsageProvider(
            roots: [sessions, archived],
            calendar: calendar
        )
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!

        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 200)
    }
}
