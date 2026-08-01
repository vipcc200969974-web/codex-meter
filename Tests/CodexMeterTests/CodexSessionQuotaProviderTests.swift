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
            lines: [
                #"{"timestamp":"1970-01-01T00:18:20Z","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":42,"window_minutes":300,"resets_at":2000}}}}"#,
                #"{"timestamp":"1970-01-01T00:20:00Z","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":0,"window_minutes":300,"resets_at":2000}}}}"#
            ]
        )
        try writeSessionFile(
            under: archivedRoot,
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

    private func writeSessionFile(under root: URL, lines: [String]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try XCTUnwrap(lines.joined(separator: "\n").data(using: .utf8))
        try data.write(to: root.appendingPathComponent("rollout.jsonl"))
    }
}
