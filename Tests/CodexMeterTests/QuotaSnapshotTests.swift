import Foundation
import XCTest
@testable import CodexMeter

final class QuotaSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testWeeklyOnlySnapshotPromotesWeeklyQuotaWithoutDuplicateRow() {
        let record = RateLimitRecord(
            timestamp: now,
            fileModifiedAt: now,
            windowSet: RateLimitWindowSet(windows: [
                RateLimitWindow(usedPercent: 35, resetsAt: 2_000, windowMinutes: 10_080)
            ], now: now)
        )

        let snapshot = QuotaSnapshot(record: record, sourceName: "Codex 会话", lastUpdated: now)

        XCTAssertEqual(snapshot.remainingPercent, 65)
        XCTAssertEqual(snapshot.mainQuotaLabel, "7 天剩余")
        XCTAssertEqual(snapshot.mainQuotaSpokenName, "七天额度")
        XCTAssertFalse(snapshot.showsWeeklySecondary)
    }

    func testDualWindowSnapshotKeepsFiveHourMainAndWeeklySecondary() {
        let record = RateLimitRecord(
            timestamp: now,
            fileModifiedAt: now,
            windowSet: RateLimitWindowSet(windows: [
                RateLimitWindow(usedPercent: 20, resetsAt: 1_500, windowMinutes: 300),
                RateLimitWindow(usedPercent: 35, resetsAt: 2_000, windowMinutes: 10_080)
            ], now: now)
        )

        let snapshot = QuotaSnapshot(record: record, sourceName: "Codex 会话", lastUpdated: now)

        XCTAssertEqual(snapshot.remainingPercent, 80)
        XCTAssertEqual(snapshot.mainQuotaLabel, "5 小时剩余")
        XCTAssertTrue(snapshot.showsWeeklySecondary)
        XCTAssertEqual(snapshot.weeklyPercentText, "65%")
    }

    func testSnapshotRejectsNonFiniteAndOutOfRangeUsageBeforeRounding() {
        XCTAssertNil(QuotaWindowSnapshot(window: RateLimitWindow(
            usedPercent: .nan,
            resetsAt: 2_000,
            windowMinutes: 300
        )))
        XCTAssertNil(QuotaWindowSnapshot(window: RateLimitWindow(
            usedPercent: .infinity,
            resetsAt: 2_000,
            windowMinutes: 300
        )))
        XCTAssertNil(QuotaWindowSnapshot(window: RateLimitWindow(
            usedPercent: 101,
            resetsAt: 2_000,
            windowMinutes: 300
        )))
    }
}
