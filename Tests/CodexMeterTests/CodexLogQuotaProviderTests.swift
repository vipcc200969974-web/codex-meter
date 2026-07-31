import Foundation
import XCTest
@testable import CodexMeter

final class CodexLogQuotaProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testParsesWeeklyOnlyHeaderSet() {
        let text = #"{"x-codex-primary-used-percent": "35", "x-codex-primary-window-minutes": "10080", "x-codex-primary-reset-at": "2000", "x-codex-secondary-used-percent": "0", "x-codex-secondary-window-minutes": "0", "x-codex-secondary-reset-at": ""}"#

        let record = CodexLogQuotaProvider.parseHeaderRecord(
            timestamp: 1_100,
            text: text,
            now: now
        )

        XCTAssertNil(record?.windowSet.fiveHour)
        XCTAssertEqual(record?.windowSet.weekly?.usedPercent, 35)
    }

    func testRejectsDiagnosticTextThatOnlyMentionsHeaderName() {
        let text = #"query contains x-codex-primary-used-percent but has no header values"#

        XCTAssertNil(CodexLogQuotaProvider.parseHeaderRecord(
            timestamp: 1_100,
            text: text,
            now: now
        ))
    }
}
