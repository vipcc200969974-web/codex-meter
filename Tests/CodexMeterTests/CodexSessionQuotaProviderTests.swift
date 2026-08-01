import Foundation
import XCTest
@testable import CodexMeter

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
}
