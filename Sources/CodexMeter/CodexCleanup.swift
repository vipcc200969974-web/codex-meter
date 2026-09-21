import Foundation

enum CodexCacheCleanup {
    // Only disposable Chromium caches; never the profile, cookies, or ~/.codex.
    private static let paths = [
        "Library/Caches/Codex",
        "Library/Application Support/Codex/Default/GPUCache",
        "Library/Application Support/Codex/Default/DawnGraphiteCache",
        "Library/Application Support/Codex/Default/DawnWebGPUCache",
        "Library/Application Support/Codex/GraphiteDawnCache",
        "Library/Application Support/Codex/GPUPersistentCache"
    ]

    static func clear(home: URL, isAppRunning: () throws -> Bool) throws -> Int {
        guard try !isAppRunning() else { throw failure("Codex 仍在运行，未清理缓存。") }
        let fm = FileManager.default
        let root = home.resolvingSymlinksInPath()
        let targets = try paths.compactMap { relative -> URL? in
            let url = root.appendingPathComponent(relative)
            guard fm.fileExists(atPath: url.path) else { return nil }
            guard url.resolvingSymlinksInPath().path == url.path,
                  try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw failure("缓存路径异常，已停止清理：\(relative)")
            }
            return url
        }
        for target in targets {
            guard try !isAppRunning() else { throw failure("Codex 已重新启动，已停止清理。") }
            guard target.resolvingSymlinksInPath().path == target.path else {
                throw failure("缓存路径发生变化，已停止清理。")
            }
            try fm.removeItem(at: target)
        }
        return targets.count
    }

    static func hasProcesses(_ output: String, appPath: String) -> Bool {
        output.split(separator: "\n").contains { line in
            let path = line.trimmingCharacters(in: .whitespaces)
            return path.hasPrefix(appPath + "/Contents/")
                && !path.hasSuffix("/browser_crashpad_handler")
                && !path.hasSuffix("/chrome_crashpad_handler")
        }
    }

    static func isAppRunning(at appURL: URL) throws -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "comm="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw failure("无法确认 Codex 是否已经退出，未清理缓存。")
        }
        return hasProcesses(text, appPath: appURL.path)
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "CodexMeter.Cleanup", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
