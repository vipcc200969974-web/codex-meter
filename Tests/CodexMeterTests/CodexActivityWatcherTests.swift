import Darwin
import Foundation
import XCTest
@testable import CodexMeter

final class CodexActivityWatcherTests: XCTestCase {
    func testAppendToSessionFileEmitsChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions/2042/08/01")
        let archived = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("rollout-watch.jsonl")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        let changed = expectation(description: "watcher emitted change")
        changed.assertForOverFulfill = false
        let watcher = CodexActivityWatcher(
            paths: CodexActivityPaths(
                codexRoot: root,
                sessionsRoot: root.appendingPathComponent("sessions"),
                archivedSessionsRoot: archived
            ),
            calendar: shanghaiCalendar(),
            now: { self.fixedNow },
            onChange: { changed.fulfill() }
        )
        watcher.start()
        defer { watcher.stop() }

        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()

        wait(for: [changed], timeout: 3)
    }

    func testAppendToOlderSessionFileEmitsChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let olderSessions = root.appendingPathComponent("sessions/2042/07/29")
        let currentSessions = root.appendingPathComponent("sessions/2042/08/01")
        let archived = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: olderSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let file = olderSessions.appendingPathComponent("rollout-old-project.jsonl")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        let changed = expectation(description: "older project emitted change")
        let watcher = CodexActivityWatcher(
            paths: CodexActivityPaths(
                codexRoot: root,
                sessionsRoot: root.appendingPathComponent("sessions"),
                archivedSessionsRoot: archived
            ),
            calendar: shanghaiCalendar(),
            now: { self.fixedNow },
            onChange: { changed.fulfill() }
        )
        watcher.start()
        defer { watcher.stop() }

        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()

        wait(for: [changed], timeout: 3)
    }

    func testUnrelatedCodexFileDoesNotEmitChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions/2042/08/01")
        let archived = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let changed = expectation(description: "unrelated file stayed ignored")
        changed.isInverted = true
        let watcher = CodexActivityWatcher(
            paths: CodexActivityPaths(
                codexRoot: root,
                sessionsRoot: root.appendingPathComponent("sessions"),
                archivedSessionsRoot: archived
            ),
            calendar: shanghaiCalendar(),
            now: { self.fixedNow },
            onChange: { changed.fulfill() }
        )
        watcher.start()
        defer { watcher.stop() }

        try Data("unrelated\n".utf8).write(to: root.appendingPathComponent("config.toml"))

        wait(for: [changed], timeout: 0.8)
    }

    func testCallbackCanStopWatcherWithoutDeadlock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions/2042/08/01")
        let archived = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("rollout-stop.jsonl")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        let stopped = expectation(description: "callback stop returned")
        let reference = WatcherReference()
        let watcher = CodexActivityWatcher(
            paths: CodexActivityPaths(
                codexRoot: root,
                sessionsRoot: root.appendingPathComponent("sessions"),
                archivedSessionsRoot: archived
            ),
            calendar: shanghaiCalendar(),
            now: { self.fixedNow },
            onChange: {
                reference.watcher?.stop()
                stopped.fulfill()
            }
        )
        reference.watcher = watcher
        watcher.start()
        defer { watcher.stop() }

        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()

        wait(for: [stopped], timeout: 3)
    }

    func testRepeatedStartAndStopCanRestartWatching() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions/2042/08/01")
        let archived = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("rollout-restart.jsonl")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        let changed = expectation(description: "restarted watcher emitted change")
        changed.assertForOverFulfill = false
        let watcher = CodexActivityWatcher(
            paths: CodexActivityPaths(
                codexRoot: root,
                sessionsRoot: root.appendingPathComponent("sessions"),
                archivedSessionsRoot: archived
            ),
            calendar: shanghaiCalendar(),
            now: { self.fixedNow },
            onChange: { changed.fulfill() }
        )
        watcher.start()
        defer { watcher.stop() }

        watcher.start()
        watcher.stop()
        watcher.stop()
        watcher.start()

        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()

        wait(for: [changed], timeout: 3)
    }

    func testRebindRecoversWhenCodexRootAppears() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionsRoot = root.appendingPathComponent("sessions")
        let archived = root.appendingPathComponent("archived_sessions")
        defer { try? FileManager.default.removeItem(at: root) }
        let appended = expectation(description: "rebound session file emitted change")
        let watcher = CodexActivityWatcher(
            paths: CodexActivityPaths(
                codexRoot: root,
                sessionsRoot: sessionsRoot,
                archivedSessionsRoot: archived
            ),
            calendar: shanghaiCalendar(),
            now: { self.fixedNow },
            onChange: { appended.fulfill() }
        )
        watcher.start()
        defer { watcher.stop() }

        let sessions = sessionsRoot.appendingPathComponent("2042/08/01")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("rollout-appeared.jsonl")
        try Data().write(to: file)

        watcher.rebind()
        watcher.waitUntilIdleForTesting()
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()

        wait(for: [appended], timeout: 3)
    }

    func testAutomaticRecoveryAfterActiveFileIsReplaced() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions/2042/08/01")
        let archived = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("rollout-replaced.jsonl")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        let replacement = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("replacement\n".utf8).write(to: replacement)
        defer { try? FileManager.default.removeItem(at: replacement) }
        let replaced = expectation(description: "replacement emitted change")
        let appended = expectation(description: "replacement append emitted change")
        let changes = ChangeRecorder(next: replaced)
        let watcher = CodexActivityWatcher(
            paths: CodexActivityPaths(
                codexRoot: root,
                sessionsRoot: root.appendingPathComponent("sessions"),
                archivedSessionsRoot: archived
            ),
            calendar: shanghaiCalendar(),
            now: { self.fixedNow },
            onChange: { changes.record() }
        )
        watcher.start()
        defer { watcher.stop() }

        XCTAssertEqual(Darwin.rename(replacement.path, file.path), 0)
        wait(for: [replaced], timeout: 3)

        // The first barrier lets the active event handler return; the second
        // drains the automatic recovery it enqueues after `onChange`.
        watcher.waitUntilIdleForTesting()
        watcher.waitUntilIdleForTesting()
        changes.setNext(appended)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()

        wait(for: [appended], timeout: 3)
    }

    private var fixedNow: Date {
        ISO8601DateFormatter().date(from: "2042-07-31T17:00:00Z")!
    }

    private func shanghaiCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        return calendar
    }
}

private final class WatcherReference: @unchecked Sendable {
    weak var watcher: CodexActivityWatcher?
}

private final class ChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var next: XCTestExpectation?

    init(next: XCTestExpectation) {
        self.next = next
    }

    func setNext(_ expectation: XCTestExpectation) {
        lock.lock()
        next = expectation
        lock.unlock()
    }

    func record() {
        lock.lock()
        let expectation = next
        next = nil
        lock.unlock()
        expectation?.fulfill()
    }
}
