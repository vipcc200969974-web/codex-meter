import Foundation
import XCTest
@testable import CodexMeter

final class QuotaObservationSelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testNewerSourceWinsWhenResetWindowChanges() throws {
        let old = ObservedRateLimitWindow(
            window: RateLimitWindow(usedPercent: 80, resetsAt: 1_500, windowMinutes: 300),
            observedAt: Date(timeIntervalSince1970: 1_100),
            sourceName: "SQLite"
        )
        let fresh = ObservedRateLimitWindow(
            window: RateLimitWindow(usedPercent: 5, resetsAt: 2_000, windowMinutes: 300),
            observedAt: Date(timeIntervalSince1970: 1_200),
            sourceName: "JSONL"
        )

        let result = try XCTUnwrap(CompositeQuotaProvider.merge([old, fresh], now: now))

        XCTAssertEqual(result.windowSet.fiveHour?.usedPercent, 5)
        XCTAssertEqual(result.observedAt, fresh.observedAt)
    }

    func testHighestUsageWinsInsideSameResetWindow() throws {
        let olderHigh = ObservedRateLimitWindow(
            window: RateLimitWindow(usedPercent: 42, resetsAt: 2_000, windowMinutes: 300),
            observedAt: Date(timeIntervalSince1970: 1_100),
            sourceName: "SQLite"
        )
        let newerZero = ObservedRateLimitWindow(
            window: RateLimitWindow(usedPercent: 0, resetsAt: 2_000, windowMinutes: 300),
            observedAt: Date(timeIntervalSince1970: 1_200),
            sourceName: "JSONL"
        )

        let result = try XCTUnwrap(CompositeQuotaProvider.merge([olderHigh, newerZero], now: now))

        XCTAssertEqual(result.windowSet.fiveHour?.usedPercent, 42)
        XCTAssertEqual(result.observedAt, olderHigh.observedAt)
    }

    func testSnapshotUsesSourceObservationTime() throws {
        let observedAt = Date(timeIntervalSince1970: 1_200)
        let observation = try XCTUnwrap(CompositeQuotaProvider.merge([
            ObservedRateLimitWindow(
                window: RateLimitWindow(usedPercent: 39, resetsAt: 2_000, windowMinutes: 10_080),
                observedAt: observedAt,
                sourceName: "JSONL"
            )
        ], now: now))

        XCTAssertEqual(QuotaSnapshot(observation: observation).lastUpdated, observedAt)
    }
}
