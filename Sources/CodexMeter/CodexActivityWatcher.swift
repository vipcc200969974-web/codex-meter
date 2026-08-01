import Darwin
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
    private var calendar: Calendar
    private let queue = DispatchQueue(label: "com.codexmeter.activity-watcher", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let now: () -> Date
    private let onChange: () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var descriptors: [Int32] = []
    private var isRunning = false

    /// Creates a watcher whose `onChange` callback runs synchronously on the
    /// watcher's private serial queue. Lifecycle methods are callback-safe.
    init(
        paths: CodexActivityPaths = .live,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping () -> Date = Date.init,
        onChange: @escaping () -> Void
    ) {
        self.paths = paths
        self.calendar = calendar
        self.now = now
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

        bind(paths.codexRoot, isDirectory: true)
        bind(paths.codexRoot.appendingPathComponent("logs_2.sqlite-wal"), isDirectory: false)
        bind(paths.sessionsRoot, isDirectory: true)

        let components = calendar.dateComponents([.year, .month, .day], from: now())
        if let year = components.year,
           let month = components.month,
           let day = components.day {
            bindCurrentSessionChain(year: year, month: month, day: day)
        }

        bind(paths.archivedSessionsRoot, isDirectory: true)
    }

    private func bindCurrentSessionChain(year: Int, month: Int, day: Int) {
        let yearDirectory = paths.sessionsRoot.appendingPathComponent(String(format: "%04d", year))
        guard directoryExists(at: yearDirectory) else { return }
        bind(yearDirectory, isDirectory: true)

        let monthDirectory = yearDirectory.appendingPathComponent(String(format: "%02d", month))
        guard directoryExists(at: monthDirectory) else { return }
        bind(monthDirectory, isDirectory: true)

        let dayDirectory = monthDirectory.appendingPathComponent(String(format: "%02d", day))
        guard directoryExists(at: dayDirectory) else { return }
        bind(dayDirectory, isDirectory: true)

        let files = (try? FileManager.default.contentsOfDirectory(
            at: dayDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for file in files.sorted(by: { $0.path < $1.path }) where file.pathExtension == "jsonl" {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            bind(file, isDirectory: false)
        }
    }

    private func bind(_ url: URL, isDirectory: Bool) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            self.onChange()

            let pathBindingChanged = !event.intersection([.rename, .delete, .revoke]).isEmpty
            if pathBindingChanged || (isDirectory && event.contains(.write)) {
                self.queue.async { [weak self] in
                    guard let self, self.isRunning else { return }
                    self.bindAll()
                }
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        sources.append(source)
        descriptors.append(descriptor)
        source.resume()
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
        sources.forEach { $0.cancel() }
        sources.removeAll()
        descriptors.removeAll()
    }
}
