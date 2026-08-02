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
        XCTAssertEqual(result.observedAt, newerZero.observedAt)
    }

    func testResetDriftWithinSixtySecondsUsesNewestTruthfulQuota() throws {
        let older = ObservedRateLimitWindow(
            window: RateLimitWindow(usedPercent: 36, resetsAt: 1_986, windowMinutes: 10_080),
            observedAt: Date(timeIntervalSince1970: 1_100),
            sourceName: "Codex 日志"
        )
        let newer = ObservedRateLimitWindow(
            window: RateLimitWindow(usedPercent: 43, resetsAt: 1_971, windowMinutes: 10_080),
            observedAt: Date(timeIntervalSince1970: 1_200),
            sourceName: "Codex 日志"
        )

        let result = try XCTUnwrap(CompositeQuotaProvider.merge([older, newer], now: now))

        XCTAssertEqual(result.windowSet.weekly?.usedPercent, 43)
        XCTAssertEqual(result.windowSet.weekly?.resetsAt, 1_971)
        XCTAssertEqual(result.observedAt, newer.observedAt)
    }

    func testResetDriftBeyondSixtySecondsKeepsCyclesSeparate() throws {
        let laterReset = ObservedRateLimitWindow(
            window: RateLimitWindow(usedPercent: 36, resetsAt: 2_061, windowMinutes: 10_080),
            observedAt: Date(timeIntervalSince1970: 1_100),
            sourceName: "Codex 日志"
        )
        let newerObservationForEarlierReset = ObservedRateLimitWindow(
            window: RateLimitWindow(usedPercent: 43, resetsAt: 2_000, windowMinutes: 10_080),
            observedAt: Date(timeIntervalSince1970: 1_200),
            sourceName: "Codex 日志"
        )

        let result = try XCTUnwrap(CompositeQuotaProvider.merge(
            [laterReset, newerObservationForEarlierReset],
            now: now
        ))

        XCTAssertEqual(result.windowSet.weekly?.usedPercent, 36)
        XCTAssertEqual(result.windowSet.weekly?.resetsAt, 2_061)
        XCTAssertEqual(result.observedAt, laterReset.observedAt)
    }

    func testLaterArrivalWithStaleResetCannotReplaceNewerReset() throws {
        let newerReset = ObservedRateLimitWindow(
            window: RateLimitWindow(usedPercent: 7, resetsAt: 2_000, windowMinutes: 300),
            observedAt: Date(timeIntervalSince1970: 1_100),
            sourceName: "Codex 日志"
        )
        let laterStaleArrival = ObservedRateLimitWindow(
            window: RateLimitWindow(usedPercent: 91, resetsAt: 1_500, windowMinutes: 300),
            observedAt: Date(timeIntervalSince1970: 1_200),
            sourceName: "Codex 会话"
        )

        let result = try XCTUnwrap(CompositeQuotaProvider.merge(
            [newerReset, laterStaleArrival],
            now: now
        ))

        XCTAssertEqual(result.windowSet.fiveHour?.resetsAt, 2_000)
        XCTAssertEqual(result.windowSet.fiveHour?.usedPercent, 7)
        XCTAssertEqual(result.observedAt, newerReset.observedAt)
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

    func testEqualTimestampChoosesLaterResetEpochRegardlessOfInputOrder() throws {
        let observedAt = Date(timeIntervalSince1970: 1_200)
        let earlierReset = ObservedRateLimitWindow(
            window: RateLimitWindow(usedPercent: 80, resetsAt: 1_500, windowMinutes: 300),
            observedAt: observedAt,
            sourceName: "Codex 日志"
        )
        let laterReset = ObservedRateLimitWindow(
            window: RateLimitWindow(usedPercent: 5, resetsAt: 2_000, windowMinutes: 300),
            observedAt: observedAt,
            sourceName: "Codex 会话"
        )

        for candidates in [[earlierReset, laterReset], [laterReset, earlierReset]] {
            let result = try XCTUnwrap(CompositeQuotaProvider.merge(candidates, now: now))

            XCTAssertEqual(result.windowSet.fiveHour?.resetsAt, 2_000)
            XCTAssertEqual(result.windowSet.fiveHour?.usedPercent, 5)
        }
    }

    func testEqualTimestampAndResetUsesStableSourcePriorityRegardlessOfInputOrder() throws {
        let observedAt = Date(timeIntervalSince1970: 1_200)
        let session = ObservedRateLimitWindow(
            window: RateLimitWindow(usedPercent: 20, resetsAt: 2_000, windowMinutes: 300),
            observedAt: observedAt,
            sourceName: "Codex 会话"
        )
        let log = ObservedRateLimitWindow(
            window: RateLimitWindow(usedPercent: 20, resetsAt: 2_000, windowMinutes: 300),
            observedAt: observedAt,
            sourceName: "Codex 日志"
        )

        for candidates in [[session, log], [log, session]] {
            let result = try XCTUnwrap(CompositeQuotaProvider.merge(candidates, now: now))

            XCTAssertEqual(result.sourceName, "Codex 日志")
        }
    }

    func testSessionEqualTimestampChoosesLaterResetEpoch() throws {
        let observedAt = Date(timeIntervalSince1970: 1_200)
        let earlierReset = RateLimitRecord(
            timestamp: observedAt,
            fileModifiedAt: observedAt,
            windowSet: RateLimitWindowSet(windows: [
                RateLimitWindow(usedPercent: 80, resetsAt: 1_500, windowMinutes: 300)
            ], now: now)
        )
        let laterReset = RateLimitRecord(
            timestamp: observedAt,
            fileModifiedAt: observedAt,
            windowSet: RateLimitWindowSet(windows: [
                RateLimitWindow(usedPercent: 5, resetsAt: 2_000, windowMinutes: 300)
            ], now: now)
        )

        for records in [[earlierReset, laterReset], [laterReset, earlierReset]] {
            let result = try XCTUnwrap(CodexSessionQuotaProvider.bestRateLimitRecord(
                from: records,
                now: now
            ))

            XCTAssertEqual(result.windowSet.fiveHour?.resetsAt, 2_000)
            XCTAssertEqual(result.windowSet.fiveHour?.usedPercent, 5)
        }
    }
}
