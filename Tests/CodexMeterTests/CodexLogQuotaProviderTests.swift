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

    func testReadsLatestQuotaFromLargeSQLiteResult() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-meter-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let header = #"{"x-codex-primary-used-percent": "35", "x-codex-primary-window-minutes": "10080", "x-codex-primary-reset-at": "4102444800"}"#
            + String(repeating: "x", count: 4_096)
        let inserts = (0..<40).map { index in
            "insert into logs (ts, ts_nanos, target, feedback_log_body) "
                + "values (\(2_000 + index), 0, 'codex_http_client::client', '\(header)')"
        }.joined(separator: ";")
        try runSQLite(
            databaseURL: databaseURL,
            query: """
            create table logs (
                id integer primary key autoincrement,
                ts integer not null,
                ts_nanos integer not null,
                target text not null,
                feedback_log_body text
            );
            \(inserts);
            """
        )

        let snapshot = CodexLogQuotaProvider(databaseURL: databaseURL).currentSnapshot()

        XCTAssertEqual(snapshot?.mainQuotaLabel, "7 天剩余")
        XCTAssertEqual(snapshot?.remainingPercent, 65)
    }

    private func runSQLite(databaseURL: URL, query: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databaseURL.path, query]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
