import Foundation

@main
struct CodexCleanupChecks {
    static func main() throws {
        let checks = Self()
        try checks.testCleanupPreservesSessionsLoginAndOtherApps()
        try checks.testRunningOrUnverifiableAppPreventsDeletion()
        try checks.testSymlinkCannotRedirectCleanupIntoSessionData()
        checks.testProcessDetectionIncludesHelpersButNotMeterOrCrashReporter()
        print("PASS: cache cleanup, data preservation, running-process guard, symlink guard")
    }
    func testCleanupPreservesSessionsLoginAndOtherApps() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = try write("Library/Caches/Codex/Default/Cache/data", in: home)
        let gpu = try write("Library/Application Support/Codex/Default/GPUCache/data", in: home)
        let protected = try [".codex/sessions/session.jsonl", ".codex/auth.json",
            "Library/Application Support/Codex/Default/Cookies",
            "Library/Application Support/Codex/Default/Local Storage/data",
            "Library/Application Support/Codex/browser-sidebar-page-states.json",
            "Library/Caches/Codex Meter/data"].map { try write($0, in: home) }
        try FileManager.default.createSymbolicLink(
            at: cache.deletingLastPathComponent().appendingPathComponent("session-link"),
            withDestinationURL: protected[0])
        checkEqual(try CodexCacheCleanup.clear(home: home, isAppRunning: { false }), 2)
        checkFalse(FileManager.default.fileExists(atPath: cache.path))
        checkFalse(FileManager.default.fileExists(atPath: gpu.path))
        for file in protected { checkEqual(try String(contentsOf: file, encoding: .utf8), "keep") }
        checkEqual(try CodexCacheCleanup.clear(home: home, isAppRunning: { false }), 0)
    }

    func testRunningOrUnverifiableAppPreventsDeletion() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = try write("Library/Caches/Codex/Default/Cache/data", in: home)
        checkThrows(try CodexCacheCleanup.clear(home: home, isAppRunning: { true }))
        checkThrows(try CodexCacheCleanup.clear(home: home, isAppRunning: {
            throw CocoaError(.fileReadNoPermission)
        }))
        var checks = 0
        checkThrows(try CodexCacheCleanup.clear(home: home, isAppRunning: {
            checks += 1
            return checks > 1
        }))
        checkTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testSymlinkCannotRedirectCleanupIntoSessionData() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = try write(".codex/sessions/session.jsonl", in: home)
        let link = home.appendingPathComponent("Library/Caches/Codex")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file.deletingLastPathComponent())
        checkThrows(try CodexCacheCleanup.clear(home: home, isAppRunning: { false }))
        checkEqual(try String(contentsOf: file, encoding: .utf8), "keep")
    }

    func testProcessDetectionIncludesHelpersButNotMeterOrCrashReporter() {
        let prefix = "/Applications/ChatGPT.app/Contents/"
        checkTrue(CodexCacheCleanup.hasProcesses("  \(prefix)MacOS/ChatGPT\n", appPath: "/Applications/ChatGPT.app"))
        checkTrue(CodexCacheCleanup.hasProcesses("\(prefix)Resources/codex\n", appPath: "/Applications/ChatGPT.app"))
        checkTrue(CodexCacheCleanup.hasProcesses("\(prefix)Frameworks/Codex (Renderer).app/Contents/MacOS/Codex (Renderer)", appPath: "/Applications/ChatGPT.app"))
        checkFalse(CodexCacheCleanup.hasProcesses("\(prefix)Helpers/browser_crashpad_handler\n/Applications/Codex Meter.app/Contents/MacOS/CodexMeter\n/Applications/ChatGPT.app.old/Contents/MacOS/ChatGPT", appPath: "/Applications/ChatGPT.app"))
    }

    private func fixture() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ relative: String, in home: URL) throws -> URL {
        let file = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: file)
        return file
    }
}

private func checkEqual<T: Equatable>(_ actual: T, _ expected: T) { precondition(actual == expected, "Expected \(expected), got \(actual)") }
private func checkTrue(_ value: Bool) { precondition(value) }
private func checkFalse(_ value: Bool) { precondition(!value) }
private func checkThrows<T>(_ body: @autoclosure () throws -> T) {
    do { _ = try body() } catch { return }
    preconditionFailure("Expected operation to refuse cleanup")
}
