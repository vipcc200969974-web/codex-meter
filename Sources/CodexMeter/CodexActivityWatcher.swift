import Foundation

struct CodexActivityPaths: Sendable {
    let codexRoot: URL
    let sessionsRoot: URL
    let archivedSessionsRoot: URL

    static let live = CodexActivityPaths(
        codexRoot: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
        sessionsRoot: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
        archivedSessionsRoot: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/archived_sessions")
    )
}

protocol CodexActivityWatching: AnyObject {
    func start()
    func rebind()
    func stop()
}

final class CodexActivityWatcher: CodexActivityWatching, @unchecked Sendable {
    private struct FileStamp: Equatable {
        let path: String
        let size: Int64
        let modifiedAt: TimeInterval
    }

    private let paths: CodexActivityPaths
    private let queue = DispatchQueue(label: "com.codexmeter.activity-watcher", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let onChange: () -> Void
    private var pollTimer: DispatchSourceTimer?
    private var lastSignature: [FileStamp] = []
    private var isRunning = false

    /// Creates a watcher whose `onChange` callback runs synchronously on the
    /// watcher's private serial queue. Lifecycle methods are callback-safe.
    init(
        paths: CodexActivityPaths = .live,
        calendar _: Calendar = .autoupdatingCurrent,
        now _: @escaping () -> Date = Date.init,
        onChange: @escaping () -> Void
    ) {
        self.paths = paths
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: 1)
    }

    /// Performs the initial binding before returning.
    func start() {
        synchronouslyOnQueue {
            isRunning = true
            bindAll()
        }
    }

    func rebind() {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.bindAll()
        }
    }

    func stop() {
        synchronouslyOnQueue {
            isRunning = false
            tearDown()
        }
    }

    /// Internal synchronization seam for deterministic filesystem watcher tests.
    func waitUntilIdleForTesting() {
        synchronouslyOnQueue {}
    }

    private func bindAll() {
        tearDown()
        guard directoryExists(at: paths.codexRoot) else { return }

        lastSignature = currentSignature()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .milliseconds(250),
            repeating: .milliseconds(250),
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            self?.pollForChanges()
        }
        timer.resume()
        pollTimer = timer
    }

    private func pollForChanges() {
        let signature = currentSignature()
        guard signature != lastSignature else { return }
        lastSignature = signature
        onChange()
    }

    private func currentSignature() -> [FileStamp] {
        var stamps: [FileStamp] = []
        let roots = [paths.sessionsRoot, paths.archivedSessionsRoot]
        for root in roots where directoryExists(at: root) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                appendStamp(for: url, to: &stamps)
            }
        }

        let database = paths.codexRoot.appendingPathComponent("logs_2.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            let url = suffix.isEmpty
                ? database
                : URL(fileURLWithPath: database.path + suffix)
            appendStamp(for: url, to: &stamps)
        }
        return stamps.sorted { $0.path < $1.path }
    }

    private func appendStamp(for url: URL, to stamps: inout [FileStamp]) {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        ), values.isRegularFile == true else { return }
        stamps.append(
            FileStamp(
                path: url.standardizedFileURL.path,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            )
        )
    }

    private func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func synchronouslyOnQueue(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            operation()
        } else {
            queue.sync(execute: operation)
        }
    }

    private func tearDown() {
        pollTimer?.setEventHandler {}
        pollTimer?.cancel()
        pollTimer = nil
        lastSignature = []
    }
}
