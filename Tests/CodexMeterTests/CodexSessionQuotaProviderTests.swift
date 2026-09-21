import Foundation
import XCTest
@testable import CodexMeter

private final class CandidateMetadataErrorFileManager: FileManager, @unchecked Sendable {
    private let targetFile: URL

    init(targetFile: URL) {
        self.targetFile = targetFile.standardizedFileURL
        super.init()
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if URL(fileURLWithPath: path).standardizedFileURL == targetFile {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: path])
        }
        return try super.attributesOfItem(atPath: path)
    }
}

final class CodexSessionQuotaProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testParsesWeeklyOnlyAggregateCodexRecord() {
        let line = #"{"timestamp":"1970-01-01T00:16:40Z","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":35.0,"window_minutes":10080,"resets_at":2000},"secondary":null}}}"#

        let record = CodexSessionQuotaProvider.parseRecord(
            line: line,
            fileModifiedAt: now,
            now: now
        )

        XCTAssertNil(record?.windowSet.fiveHour)
        XCTAssertEqual(record?.windowSet.weekly?.usedPercent, 35)
    }

    func testRejectsModelSpecificWeeklyRecord() {
        let line = #"{"timestamp":"1970-01-01T00:16:40Z","payload":{"rate_limits":{"limit_id":"codex_bengalfox","primary":{"used_percent":0,"window_minutes":10080,"resets_at":2000}}}}"#

        XCTAssertNil(CodexSessionQuotaProvider.parseRecord(
            line: line,
            fileModifiedAt: now,
            now: now
        ))
    }

    func testRejectsMalformedSessionQuotaNumbers() {
        let malformedWindows = [
            #"{"used_percent":"NaN","window_minutes":10080,"resets_at":2000}"#,
            #"{"used_percent":"inf","window_minutes":10080,"resets_at":2000}"#,
            #"{"used_percent":-1,"window_minutes":10080,"resets_at":2000}"#,
            #"{"used_percent":101,"window_minutes":10080,"resets_at":2000}"#,
            #"{"used_percent":35,"window_minutes":10080,"resets_at":9007199254740992}"#,
            #"{"used_percent":35,"window_minutes":-300,"resets_at":2000}"#,
            #"{"used_percent":35,"window_minutes":"9223372036854775808","resets_at":2000}"#
        ]

        for window in malformedWindows {
            let line = #"{"timestamp":"1970-01-01T00:16:40Z","payload":{"rate_limits":{"limit_id":"codex","primary":\#(window)}}}"#
            XCTAssertNil(
                CodexSessionQuotaProvider.parseRecord(
                    line: line,
                    fileModifiedAt: now,
                    now: now
                ),
                "Accepted malformed session window: \(window)"
            )
        }
    }

    func testRejectsUnrepresentableNumericSessionWindowMinutes() {
        let line = #"{"timestamp":"1970-01-01T00:16:40Z","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":35,"window_minutes":1e20,"resets_at":2000}}}}"#

        XCTAssertNil(CodexSessionQuotaProvider.parseRecord(
            line: line,
            fileModifiedAt: now,
            now: now
        ))
    }

    func testRejectsJSONBooleansForSessionQuotaNumericFields() {
        let booleanWindows = [
            #"{"used_percent":true,"window_minutes":10080,"resets_at":2000}"#,
            #"{"used_percent":35,"window_minutes":true,"resets_at":2000}"#,
            #"{"used_percent":35,"window_minutes":10080,"resets_at":true}"#
        ]
        let beforeBooleanReset = Date(timeIntervalSince1970: 0)

        for window in booleanWindows {
            let line = #"{"timestamp":"1970-01-01T00:00:00Z","payload":{"rate_limits":{"limit_id":"codex","primary":\#(window)}}}"#
            XCTAssertNil(
                CodexSessionQuotaProvider.parseRecord(
                    line: line,
                    fileModifiedAt: beforeBooleanReset,
                    now: beforeBooleanReset
                ),
                "Accepted JSON boolean as quota number: \(window)"
            )
        }
    }

    func testSessionQuotaNumericZeroIsNotMistakenForJSONBoolean() {
        let line = #"{"timestamp":"1970-01-01T00:16:40Z","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":0,"window_minutes":10080,"resets_at":2000}}}}"#

        let record = CodexSessionQuotaProvider.parseRecord(
            line: line,
            fileModifiedAt: now,
            now: now
        )

        XCTAssertEqual(record?.windowSet.weekly?.usedPercent, 0)
    }

    func testRejectsMissingOrMalformedSessionEventTimestamp() {
        let missing = #"{"payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":35,"window_minutes":10080,"resets_at":2000}}}}"#
        let malformed = #"{"timestamp":"not-a-date","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":35,"window_minutes":10080,"resets_at":2000}}}}"#

        for line in [missing, malformed] {
            XCTAssertNil(CodexSessionQuotaProvider.parseRecord(
                line: line,
                fileModifiedAt: Date(timeIntervalSince1970: 1_500),
                now: now
            ))
        }
    }

    func testLaterUnrelatedAppendCannotRefreshTimestampLessQuota() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-meter-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let activeRoot = temporaryRoot.appendingPathComponent("sessions")
        let timestampLessQuota = #"{"payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":35,"window_minutes":10080,"resets_at":2000}}}}"#
        let unrelatedAppend = #"{"timestamp":"1970-01-01T00:25:00Z","payload":{"type":"message","content":"unrelated"}}"#
        try writeSessionFile(
            under: activeRoot,
            filename: "timestamp-less.jsonl",
            lines: [timestampLessQuota, unrelatedAppend],
            modifiedAt: Date(timeIntervalSince1970: 1_500)
        )

        let testNow = now
        XCTAssertTrue(CodexSessionQuotaProvider(
            roots: [activeRoot],
            now: { testNow }
        ).currentWindowObservations().isEmpty)
    }

    func testReadsMonotonicFiveHourAndWeeklyWindowsFromActiveAndArchivedLogs() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-meter-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let activeRoot = temporaryRoot.appendingPathComponent("sessions")
        let archivedRoot = temporaryRoot.appendingPathComponent("archived_sessions")
        try writeSessionFile(
            under: activeRoot,
            filename: "active.jsonl",
            lines: [
                #"{"timestamp":"1970-01-01T00:18:20Z","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":42,"window_minutes":300,"resets_at":2000}}}}"#,
                #"{"timestamp":"1970-01-01T00:20:00Z","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":0,"window_minutes":300,"resets_at":2000}}}}"#
            ]
        )
        try writeSessionFile(
            under: archivedRoot,
            filename: "archived.jsonl",
            lines: [
                #"{"timestamp":"1970-01-01T00:19:10Z","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":61,"window_minutes":10080,"resets_at":2000}}}}"#,
                #"{"timestamp":"1970-01-01T00:20:50Z","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":0,"window_minutes":10080,"resets_at":2000}}}}"#
            ]
        )

        let testNow = now
        let observations = CodexSessionQuotaProvider(
            roots: [activeRoot, archivedRoot],
            now: { testNow }
        ).currentWindowObservations()
        let fiveHour = try XCTUnwrap(observations.first { $0.window.kind == .fiveHour })
        let weekly = try XCTUnwrap(observations.first { $0.window.kind == .weekly })

        XCTAssertEqual(fiveHour.window.usedPercent, 42)
        XCTAssertEqual(fiveHour.observedAt, Date(timeIntervalSince1970: 1_200))
        XCTAssertEqual(weekly.window.usedPercent, 61)
        XCTAssertEqual(weekly.observedAt, Date(timeIntervalSince1970: 1_250))
    }

    func testScansMoreThanFortyWeeklyObservationsInOneLongRunningFile() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-meter-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let activeRoot = temporaryRoot.appendingPathComponent("sessions")
        let outOfLookback = rateLimitLine(
            timestamp: -625_401,
            usedPercent: 99,
            resetsAt: 2_000.0,
            windowMinutes: 10_080,
            paddingBytes: 2_048
        )
        let currentLines = (0..<65).map { index in
            rateLimitLine(
                timestamp: TimeInterval(1_100 + index),
                usedPercent: index == 0 ? 77 : 0,
                resetsAt: 2_000.0,
                windowMinutes: 10_080,
                paddingBytes: 2_048
            )
        }
        try writeSessionFile(
            under: activeRoot,
            filename: "long-running.jsonl",
            lines: [outOfLookback] + currentLines
        )

        let testNow = now
        let weekly = try XCTUnwrap(
            CodexSessionQuotaProvider(roots: [activeRoot], now: { testNow })
                .currentWindowObservations()
                .first { $0.window.kind == .weekly }
        )

        XCTAssertEqual(weekly.window.usedPercent, 77)
        XCTAssertEqual(weekly.observedAt, Date(timeIntervalSince1970: 1_164))
    }

    func testContinuesPastOutOfOrderOldTimestampToEarlierInBoundHigh() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-meter-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let activeRoot = temporaryRoot.appendingPathComponent("sessions")
        try writeSessionFile(
            under: activeRoot,
            filename: "out-of-order.jsonl",
            lines: [
                rateLimitLine(
                    timestamp: 1_100,
                    usedPercent: 79,
                    resetsAt: 2_000,
                    windowMinutes: 10_080
                ),
                rateLimitLine(
                    timestamp: -625_401,
                    usedPercent: 99,
                    resetsAt: 2_000,
                    windowMinutes: 10_080
                ),
                rateLimitLine(
                    timestamp: 1_200,
                    usedPercent: 0,
                    resetsAt: 2_000,
                    windowMinutes: 10_080
                )
            ]
        )

        let testNow = now
        let weekly = try XCTUnwrap(
            CodexSessionQuotaProvider(roots: [activeRoot], now: { testNow })
                .currentWindowObservations()
                .first { $0.window.kind == .weekly }
        )

        XCTAssertEqual(weekly.window.usedPercent, 79)
        XCTAssertEqual(weekly.observedAt, Date(timeIntervalSince1970: 1_200))
    }

    func testOlderOversizedSessionFileDoesNotHideNewerReadableQuota() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-meter-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let activeRoot = temporaryRoot.appendingPathComponent("sessions")
        try writeSessionFile(
            under: activeRoot,
            filename: "over-byte-cap.jsonl",
            lines: [rateLimitLine(
                timestamp: 1_100,
                usedPercent: 36,
                resetsAt: 2_000,
                windowMinutes: 10_080,
                paddingBytes: 512
            )],
            modifiedAt: Date(timeIntervalSince1970: 1_100)
        )
        try writeSessionFile(
            under: activeRoot,
            filename: "newer-readable.jsonl",
            lines: [rateLimitLine(
                timestamp: 1_200,
                usedPercent: 46,
                resetsAt: 2_000,
                windowMinutes: 10_080
            )],
            modifiedAt: Date(timeIntervalSince1970: 1_200)
        )
        XCTAssertGreaterThan(
            try fileSize(at: activeRoot.appendingPathComponent("over-byte-cap.jsonl")),
            256
        )
        XCTAssertLessThanOrEqual(
            try fileSize(at: activeRoot.appendingPathComponent("newer-readable.jsonl")),
            256
        )

        let testNow = now
        let weekly = try XCTUnwrap(
            CodexSessionQuotaProvider(
                roots: [activeRoot],
                maxBytesPerFile: 256,
                now: { testNow }
            ).currentWindowObservations().first { $0.window.kind == .weekly }
        )

        XCTAssertEqual(weekly.window.usedPercent, 46)
        XCTAssertEqual(weekly.observedAt, Date(timeIntervalSince1970: 1_200))
    }

    func testRecentlyModifiedOversizedSessionTailProvidesNewestQuota() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-meter-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let activeRoot = temporaryRoot.appendingPathComponent("sessions")
        let url = activeRoot.appendingPathComponent("large-active.jsonl")
        let padding = Data(repeating: 0x20, count: 16 * 1_024 * 1_024)
        try FileManager.default.createDirectory(at: activeRoot, withIntermediateDirectories: true)
        try padding.write(to: url)
        let newest = rateLimitLine(
            timestamp: 1_200,
            usedPercent: 52,
            resetsAt: 2_000,
            windowMinutes: 10_080
        )
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((newest + "\n").utf8))
        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: url.path
        )

        let testNow = now
        let weekly = try XCTUnwrap(
            CodexSessionQuotaProvider(
                roots: [activeRoot],
                maxBytesPerFile: 1_024,
                maxTotalBytes: 8 * 1_024 * 1_024,
                now: { testNow }
            ).currentWindowObservations().first { $0.window.kind == .weekly }
        )

        XCTAssertEqual(weekly.window.usedPercent, 52)
        XCTAssertEqual(weekly.observedAt, Date(timeIntervalSince1970: 1_200))
    }

    func testAggregateBudgetKeepsNewestFileThatFits() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-meter-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let activeRoot = temporaryRoot.appendingPathComponent("sessions")
        for index in 0..<2 {
            try writeSessionFile(
                under: activeRoot,
                filename: "aggregate-cap-\(index).jsonl",
                lines: [
                    rateLimitLine(
                        timestamp: TimeInterval(1_100 + index),
                        usedPercent: index == 0 ? 67 : 3,
                        resetsAt: 2_000,
                        windowMinutes: 10_080,
                        paddingBytes: 256
                    )
                ],
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(1_100 + index))
            )
        }
        let candidateByteCounts = try (0..<2).map { index in
            try fileSize(at: activeRoot.appendingPathComponent("aggregate-cap-\(index).jsonl"))
        }
        XCTAssertTrue(candidateByteCounts.allSatisfy { $0 <= 700 && $0 <= 1_024 })
        XCTAssertGreaterThan(candidateByteCounts.reduce(0, +), 700)

        let testNow = now
        let weekly = try XCTUnwrap(
            CodexSessionQuotaProvider(
                roots: [activeRoot],
                maxBytesPerFile: 1_024,
                maxTotalBytes: 700,
                now: { testNow }
            ).currentWindowObservations().first { $0.window.kind == .weekly }
        )

        XCTAssertEqual(weekly.window.usedPercent, 3)
        XCTAssertEqual(weekly.observedAt, Date(timeIntervalSince1970: 1_101))
    }

    func testGroupsFractionalEquivalentResetValuesFromSessionLog() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-meter-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let activeRoot = temporaryRoot.appendingPathComponent("sessions")
        try writeSessionFile(
            under: activeRoot,
            filename: "fractional-reset.jsonl",
            lines: [
                rateLimitLine(
                    timestamp: 1_100,
                    usedPercent: 48,
                    resetsAt: 2_000.1,
                    windowMinutes: 10_080
                ),
                rateLimitLine(
                    timestamp: 1_200,
                    usedPercent: 0,
                    resetsAt: 2_000.4,
                    windowMinutes: 10_080
                )
            ]
        )

        let testNow = now
        let weekly = try XCTUnwrap(
            CodexSessionQuotaProvider(roots: [activeRoot], now: { testNow })
                .currentWindowObservations()
                .first { $0.window.kind == .weekly }
        )

        XCTAssertEqual(weekly.window.usedPercent, 48)
        XCTAssertEqual(weekly.window.resetsAt, 2_000)
        XCTAssertEqual(weekly.observedAt, Date(timeIntervalSince1970: 1_200))
    }

    func testScansAllOverlappingSessionFilesBeyondPreviousEightyFileCap() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-meter-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let activeRoot = temporaryRoot.appendingPathComponent("sessions")
        for index in 0...80 {
            try writeSessionFile(
                under: activeRoot,
                filename: "rollout-\(index).jsonl",
                lines: [
                    rateLimitLine(
                        timestamp: TimeInterval(1_100 + index),
                        usedPercent: index == 0 ? 73 : 0,
                        resetsAt: 2_000,
                        windowMinutes: 10_080
                    )
                ],
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(1_100 + index))
            )
        }

        let testNow = now
        let weekly = try XCTUnwrap(
            CodexSessionQuotaProvider(roots: [activeRoot], now: { testNow })
                .currentWindowObservations()
                .first { $0.window.kind == .weekly }
        )

        XCTAssertEqual(weekly.window.usedPercent, 73)
        XCTAssertEqual(weekly.observedAt, Date(timeIntervalSince1970: 1_180))
    }

    func testDeduplicatesMovedSessionByRolloutFilename() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-meter-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let activeRoot = temporaryRoot.appendingPathComponent("sessions")
        let archivedRoot = temporaryRoot.appendingPathComponent("archived_sessions")
        try writeSessionFile(
            under: activeRoot,
            filename: "moved-rollout.jsonl",
            lines: [
                rateLimitLine(
                    timestamp: 1_100,
                    usedPercent: 88,
                    resetsAt: 2_000,
                    windowMinutes: 10_080
                )
            ],
            modifiedAt: Date(timeIntervalSince1970: 1_100)
        )
        try writeSessionFile(
            under: archivedRoot,
            filename: "moved-rollout.jsonl",
            lines: [
                rateLimitLine(
                    timestamp: 1_200,
                    usedPercent: 3,
                    resetsAt: 2_000,
                    windowMinutes: 10_080
                )
            ],
            modifiedAt: Date(timeIntervalSince1970: 1_200)
        )

        let testNow = now
        let weekly = try XCTUnwrap(
            CodexSessionQuotaProvider(
                roots: [activeRoot, archivedRoot],
                now: { testNow }
            ).currentWindowObservations().first { $0.window.kind == .weekly }
        )

        XCTAssertEqual(weekly.window.usedPercent, 3)
        XCTAssertEqual(weekly.observedAt, Date(timeIntervalSince1970: 1_200))
    }

    func testCandidateMetadataFailureInvalidatesReadableSessionQuota() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-meter-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let activeRoot = temporaryRoot.appendingPathComponent("sessions")
        try writeSessionFile(
            under: activeRoot,
            filename: "readable-lower.jsonl",
            lines: [rateLimitLine(
                timestamp: 1_100,
                usedPercent: 12,
                resetsAt: 2_000,
                windowMinutes: 10_080
            )]
        )
        try writeSessionFile(
            under: activeRoot,
            filename: "metadata-failure.jsonl",
            lines: [rateLimitLine(
                timestamp: 1_200,
                usedPercent: 81,
                resetsAt: 2_000,
                windowMinutes: 10_080
            )]
        )
        let failingFile = activeRoot.appendingPathComponent("metadata-failure.jsonl")
        let discovery = LocalSessionFileDiscovery(
            fileManager: CandidateMetadataErrorFileManager(targetFile: failingFile)
        )

        let testNow = now
        let observations = CodexSessionQuotaProvider(
            roots: [activeRoot],
            fileDiscovery: discovery,
            now: { testNow }
        ).currentWindowObservations()

        XCTAssertTrue(observations.isEmpty)
    }

    func testMissingRootIsEmptyWhileReadableRootStillPublishesQuota() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-meter-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let activeRoot = temporaryRoot.appendingPathComponent("sessions")
        let missingRoot = temporaryRoot.appendingPathComponent("never-created")
        try writeSessionFile(
            under: activeRoot,
            filename: "readable.jsonl",
            lines: [rateLimitLine(
                timestamp: 1_100,
                usedPercent: 23,
                resetsAt: 2_000,
                windowMinutes: 10_080
            )]
        )

        let testNow = now
        let weekly = try XCTUnwrap(
            CodexSessionQuotaProvider(
                roots: [activeRoot, missingRoot],
                now: { testNow }
            ).currentWindowObservations().first { $0.window.kind == .weekly }
        )

        XCTAssertEqual(weekly.window.usedPercent, 23)
    }

    func testEnumeratorCreationFailureInvalidatesReadableSessionQuota() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-meter-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let activeRoot = temporaryRoot.appendingPathComponent("sessions")
        let failingRoot = temporaryRoot.appendingPathComponent("cannot-enumerate")
        try writeSessionFile(
            under: activeRoot,
            filename: "readable.jsonl",
            lines: [rateLimitLine(
                timestamp: 1_100,
                usedPercent: 34,
                resetsAt: 2_000,
                windowMinutes: 10_080
            )]
        )
        try FileManager.default.createDirectory(at: failingRoot, withIntermediateDirectories: true)
        let discovery = LocalSessionFileDiscovery(
            enumeratorFactory: { root, keys, errorHandler in
                guard root.standardizedFileURL != failingRoot.standardizedFileURL else {
                    return nil
                }
                return FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles],
                    errorHandler: errorHandler
                )
            }
        )

        let testNow = now
        let observations = CodexSessionQuotaProvider(
            roots: [activeRoot, failingRoot],
            fileDiscovery: discovery,
            now: { testNow }
        ).currentWindowObservations()

        XCTAssertTrue(observations.isEmpty)
    }

    func testEnumeratorTraversalFailureInvalidatesReadableSessionQuota() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-meter-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let activeRoot = temporaryRoot.appendingPathComponent("sessions")
        let failingRoot = temporaryRoot.appendingPathComponent("traversal-failure")
        try writeSessionFile(
            under: activeRoot,
            filename: "readable.jsonl",
            lines: [rateLimitLine(
                timestamp: 1_100,
                usedPercent: 45,
                resetsAt: 2_000,
                windowMinutes: 10_080
            )]
        )
        try FileManager.default.createDirectory(at: failingRoot, withIntermediateDirectories: true)
        let discovery = LocalSessionFileDiscovery(
            enumeratorFactory: { root, keys, errorHandler in
                if root.standardizedFileURL == failingRoot.standardizedFileURL {
                    _ = errorHandler(
                        root,
                        CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: root.path])
                    )
                }
                return FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles],
                    errorHandler: errorHandler
                )
            }
        )

        let testNow = now
        let observations = CodexSessionQuotaProvider(
            roots: [activeRoot, failingRoot],
            fileDiscovery: discovery,
            now: { testNow }
        ).currentWindowObservations()

        XCTAssertTrue(observations.isEmpty)
    }

    func testKeepsHighestUsageWithinCurrentFiveHourWindow() {
        let reset = 2_000.0
        let older = RateLimitRecord(
            timestamp: Date(timeIntervalSince1970: 1_100),
            fileModifiedAt: now,
            windowSet: RateLimitWindowSet(windows: [
                RateLimitWindow(usedPercent: 42, resetsAt: reset, windowMinutes: 300)
            ], now: now)
        )
        let newerTransientZero = RateLimitRecord(
            timestamp: Date(timeIntervalSince1970: 1_200),
            fileModifiedAt: now,
            windowSet: RateLimitWindowSet(windows: [
                RateLimitWindow(usedPercent: 0, resetsAt: reset, windowMinutes: 300)
            ], now: now)
        )

        let result = CodexSessionQuotaProvider.bestRateLimitRecord(
            from: [older, newerTransientZero],
            now: now
        )

        XCTAssertEqual(result?.windowSet.fiveHour?.usedPercent, 42)
        XCTAssertEqual(result?.sortDate, newerTransientZero.sortDate)
    }

    func testKeepsHighestUsageAndLatestObservationWithinCurrentWeeklyWindow() {
        let reset = 2_000.0
        let olderHigh = RateLimitRecord(
            timestamp: Date(timeIntervalSince1970: 1_100),
            fileModifiedAt: now,
            windowSet: RateLimitWindowSet(windows: [
                RateLimitWindow(usedPercent: 61, resetsAt: reset, windowMinutes: 10_080)
            ], now: now)
        )
        let newerTransientZero = RateLimitRecord(
            timestamp: Date(timeIntervalSince1970: 1_200),
            fileModifiedAt: now,
            windowSet: RateLimitWindowSet(windows: [
                RateLimitWindow(usedPercent: 0, resetsAt: reset, windowMinutes: 10_080)
            ], now: now)
        )

        let result = CodexSessionQuotaProvider.bestRateLimitRecord(
            from: [olderHigh, newerTransientZero],
            now: now
        )

        XCTAssertEqual(result?.windowSet.weekly?.usedPercent, 61)
        XCTAssertEqual(result?.sortDate, newerTransientZero.sortDate)
    }

    func testNewerWeeklyResetCanStartAtLowerUsage() {
        let olderHigh = RateLimitRecord(
            timestamp: Date(timeIntervalSince1970: 1_100),
            fileModifiedAt: now,
            windowSet: RateLimitWindowSet(windows: [
                RateLimitWindow(usedPercent: 81, resetsAt: 1_500, windowMinutes: 10_080)
            ], now: now)
        )
        let newerLow = RateLimitRecord(
            timestamp: Date(timeIntervalSince1970: 1_200),
            fileModifiedAt: now,
            windowSet: RateLimitWindowSet(windows: [
                RateLimitWindow(usedPercent: 4, resetsAt: 2_000, windowMinutes: 10_080)
            ], now: now)
        )

        let result = CodexSessionQuotaProvider.bestRateLimitRecord(
            from: [olderHigh, newerLow],
            now: now
        )

        XCTAssertEqual(result?.windowSet.weekly?.usedPercent, 4)
        XCTAssertEqual(result?.windowSet.weekly?.resetsAt, 2_000)
        XCTAssertEqual(result?.sortDate, newerLow.sortDate)
    }

    private func writeSessionFile(
        under root: URL,
        filename: String,
        lines: [String],
        modifiedAt: Date? = nil
    ) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try XCTUnwrap(lines.joined(separator: "\n").data(using: .utf8))
        let url = root.appendingPathComponent(filename)
        try data.write(to: url)
        if let modifiedAt {
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
    }

    private func rateLimitLine(
        timestamp: TimeInterval,
        usedPercent: Double,
        resetsAt: Double,
        windowMinutes: Int,
        paddingBytes: Int = 0
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestampText = formatter.string(from: Date(timeIntervalSince1970: timestamp))
        return "{\"timestamp\":\"\(timestampText)\",\"payload\":{\"rate_limits\":{"
            + "\"limit_id\":\"codex\",\"primary\":{\"used_percent\":\(usedPercent),"
            + "\"window_minutes\":\(windowMinutes),\"resets_at\":\(resetsAt)}}},"
            + "\"padding\":\"\(String(repeating: "x", count: paddingBytes))\"}"
    }

    private func fileSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.size] as? NSNumber).uint64Value
    }
}
