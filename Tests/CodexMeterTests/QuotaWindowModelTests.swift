import Foundation
import XCTest
@testable import CodexMeter

final class QuotaWindowModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testClassifiesReversedSupportedWindowsByDuration() {
        let weekly = RateLimitWindow(usedPercent: 35, resetsAt: 2_000, windowMinutes: 10_080)
        let fiveHour = RateLimitWindow(usedPercent: 20, resetsAt: 1_500, windowMinutes: 300)

        let result = RateLimitWindowSet(windows: [weekly, fiveHour], now: now)

        XCTAssertEqual(result.fiveHour?.usedPercent, 20)
        XCTAssertEqual(result.weekly?.usedPercent, 35)
    }

    func testKeepsWeeklyWindowWhenFiveHourWindowIsMissing() {
        let weekly = RateLimitWindow(usedPercent: 35, resetsAt: 2_000, windowMinutes: 10_080)

        let result = RateLimitWindowSet(windows: [weekly], now: now)

        XCTAssertNil(result.fiveHour)
        XCTAssertEqual(result.weekly?.usedPercent, 35)
    }

    func testDropsExpiredAndUnsupportedWindowsIndividually() {
        let expiredFiveHour = RateLimitWindow(usedPercent: 20, resetsAt: 900, windowMinutes: 300)
        let weekly = RateLimitWindow(usedPercent: 35, resetsAt: 2_000, windowMinutes: 10_080)
        let unknown = RateLimitWindow(usedPercent: 10, resetsAt: 2_000, windowMinutes: 60)

        let result = RateLimitWindowSet(windows: [expiredFiveHour, weekly, unknown], now: now)

        XCTAssertNil(result.fiveHour)
        XCTAssertEqual(result.weekly?.usedPercent, 35)
    }
}
