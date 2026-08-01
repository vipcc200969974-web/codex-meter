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
        XCTAssertEqual(result?.sortDate, older.sortDate)
    }
}
