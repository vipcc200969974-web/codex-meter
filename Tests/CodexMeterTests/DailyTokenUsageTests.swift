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

    func testDefaultLayoutIncludesPreviousLocalDayCrossMidnightFiles() throws {
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
            calendar: calendar,
            discoveryLayout: .codexDefault
        )
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!

        XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 300)
    }

    func testDefaultLayoutExcludesPathsOlderThanPreviousLocalDay() throws {
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
        let provider = DailyTokenUsageProvider(
            roots: [sessions, archived],
            calendar: calendar,
            discoveryLayout: .codexDefault
        )
        let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!

        XCTAssertEqual(try provider.currentUsage(now: now), .zero)
    }
}
