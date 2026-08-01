import Foundation
import XCTest
@testable import CodexMeter

final class CodexActivityWatcherTests: XCTestCase {
    func testAppendToSessionFileEmitsChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions/2026/08/01")
        let archived = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("rollout-watch.jsonl")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let fixedNow = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        let changed = expectation(description: "watcher emitted change")
        changed.assertForOverFulfill = false
        let watcher = CodexActivityWatcher(
            paths: CodexActivityPaths(
                codexRoot: root,
                sessionsRoot: root.appendingPathComponent("sessions"),
                archivedSessionsRoot: archived
            ),
            calendar: calendar,
            now: { fixedNow },
            onChange: { changed.fulfill() }
        )
        watcher.start()

        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()

        wait(for: [changed], timeout: 3)
        watcher.stop()
    }
}
