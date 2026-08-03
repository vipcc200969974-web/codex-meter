import CoreServices
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
    private let paths: CodexActivityPaths
    private let queue = DispatchQueue(label: "com.codexmeter.activity-watcher", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var isRunning = false

    private static let streamCallback: FSEventStreamCallback = {
        _, info, eventCount, eventPaths, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<CodexActivityWatcher>
            .fromOpaque(info)
            .takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        watcher.handleEventPaths(Array(paths.prefix(eventCount)))
    }

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

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.streamCallback,
            &context,
            [paths.codexRoot.standardizedFileURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamSetDispatchQueue(stream, nil)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    private func handleEventPaths(_ eventPaths: [String]) {
        guard eventPaths.contains(where: shouldRefresh(for:)) else { return }
        onChange()
    }

    private func shouldRefresh(for eventPath: String) -> Bool {
        let eventPath = URL(fileURLWithPath: eventPath).standardizedFileURL.path
        let sessionsPrefix = paths.sessionsRoot.standardizedFileURL.path + "/"
        let archivedPrefix = paths.archivedSessionsRoot.standardizedFileURL.path + "/"
        if eventPath.hasSuffix(".jsonl"),
           eventPath.hasPrefix(sessionsPrefix) || eventPath.hasPrefix(archivedPrefix) {
            return true
        }

        let databasePath = paths.codexRoot
            .appendingPathComponent("logs_2.sqlite")
            .standardizedFileURL.path
        return eventPath == databasePath
            || eventPath == databasePath + "-wal"
            || eventPath == databasePath + "-shm"
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
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamSetDispatchQueue(stream, nil)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
