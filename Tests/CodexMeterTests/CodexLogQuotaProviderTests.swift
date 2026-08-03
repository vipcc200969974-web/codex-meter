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

    func testRejectsMalformedQuotaHeaderNumbers() {
        let malformedHeaders = [
            #"{"x-codex-primary-used-percent": "NaN", "x-codex-primary-window-minutes": "10080", "x-codex-primary-reset-at": "2000"}"#,
            #"{"x-codex-primary-used-percent": "inf", "x-codex-primary-window-minutes": "10080", "x-codex-primary-reset-at": "2000"}"#,
            #"{"x-codex-primary-used-percent": "-1", "x-codex-primary-window-minutes": "10080", "x-codex-primary-reset-at": "2000"}"#,
            #"{"x-codex-primary-used-percent": "101", "x-codex-primary-window-minutes": "10080", "x-codex-primary-reset-at": "2000"}"#,
            #"{"x-codex-primary-used-percent": "35", "x-codex-primary-window-minutes": "10080", "x-codex-primary-reset-at": "9007199254740992"}"#,
            #"{"x-codex-primary-used-percent": "35", "x-codex-primary-window-minutes": "-300", "x-codex-primary-reset-at": "2000"}"#,
            #"{"x-codex-primary-used-percent": "35", "x-codex-primary-window-minutes": "9223372036854775808", "x-codex-primary-reset-at": "2000"}"#
        ]

        for header in malformedHeaders {
            XCTAssertNil(
                CodexLogQuotaProvider.parseHeaderRecord(
                    timestamp: 1_100,
                    text: header,
                    now: now
                ),
                "Accepted malformed header: \(header)"
            )
        }
    }

    func testReadsLatestQuotaFromLargeSQLiteResult() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-meter-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let header = #"{"x-codex-primary-used-percent": "35", "x-codex-primary-window-minutes": "10080", "x-codex-primary-reset-at": "4102444800"}"#
            + String(repeating: "x", count: 4_096)
        let firstTimestamp = Int(Date().timeIntervalSince1970) - 39
        let inserts = (0..<40).map { index in
            "insert into logs (ts, ts_nanos, target, feedback_log_body) "
                + "values (\(firstTimestamp + index), 0, 'codex_http_client::client', '\(header)')"
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

        let observation = CompositeQuotaProvider.merge(
            CodexLogQuotaProvider(databaseURL: databaseURL).currentWindowObservations(),
            now: now
        )
        let snapshot = observation.map(QuotaSnapshot.init(observation:))

        XCTAssertEqual(snapshot?.mainQuotaLabel, "7 天剩余")
        XCTAssertEqual(snapshot?.remainingPercent, 65)
    }

    func testScansMoreThanFortySameResetRowsForHighestWeeklyUsageAndLatestObservation() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-meter-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let oldestTimestamp = Int(Date().timeIntervalSince1970) - 64
        let highHeader = #"{"x-codex-primary-used-percent": "61", "x-codex-primary-window-minutes": "10080", "x-codex-primary-reset-at": "4102444800"}"#
        let outOfLookbackHeader = #"{"x-codex-primary-used-percent": "99", "x-codex-primary-window-minutes": "10080", "x-codex-primary-reset-at": "4102444800"}"#
        let transientZeroHeader = #"{"x-codex-primary-used-percent": "0", "x-codex-primary-window-minutes": "10080", "x-codex-primary-reset-at": "4102444800"}"#
        let outOfLookbackRow = "insert into logs (ts, ts_nanos, target, feedback_log_body) "
            + "values (\(oldestTimestamp - 626_401), 0, 'codex_http_client::client', '\(outOfLookbackHeader)')"
        let currentRows = (0..<65).map { index in
            let header = index == 0 ? highHeader : transientZeroHeader
            return "insert into logs (ts, ts_nanos, target, feedback_log_body) "
                + "values (\(oldestTimestamp + index), 0, 'codex_http_client::client', '\(header)')"
        }
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
            \(([outOfLookbackRow] + currentRows).joined(separator: ";"));
            """
        )

        let weekly = try XCTUnwrap(
            CodexLogQuotaProvider(databaseURL: databaseURL)
                .currentWindowObservations()
                .first { $0.window.kind == .weekly }
        )

        XCTAssertEqual(weekly.window.usedPercent, 61)
        XCTAssertEqual(weekly.window.resetsAt, 4_102_444_800)
        XCTAssertEqual(
            weekly.observedAt,
            Date(timeIntervalSince1970: TimeInterval(oldestTimestamp + 64))
        )
    }

    func testReadsSecondaryOnlyQuotaHeaderFromSQLite() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-meter-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let timestamp = Int(Date().timeIntervalSince1970)
        let secondaryHeader = #"{"x-codex-secondary-used-percent": "27", "x-codex-secondary-window-minutes": "10080", "x-codex-secondary-reset-at": "4102444800"}"#
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
            insert into logs (ts, ts_nanos, target, feedback_log_body)
            values (\(timestamp), 0, 'codex_http_client::client', '\(secondaryHeader)');
            """
        )

        let observations = CodexLogQuotaProvider(databaseURL: databaseURL)
            .currentWindowObservations()
        let weekly = try XCTUnwrap(observations.first { $0.window.kind == .weekly })

        XCTAssertEqual(weekly.window.usedPercent, 27)
        XCTAssertEqual(weekly.observedAt, Date(timeIntervalSince1970: TimeInterval(timestamp)))
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
