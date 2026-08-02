import Foundation

enum CodexTaskLifecycleKind: String, Codable, Sendable {
    case started = "task_started"
    case completed = "task_complete"
}

struct CodexTaskLifecycleEvent: Equatable, Sendable {
    let kind: CodexTaskLifecycleKind
    let turnID: String
    let timestamp: Date
}

protocol CodexTaskLifecycleDecoding: Sendable {
    func decode(from data: Data) -> CodexTaskLifecycleEvent?
}

struct JSONCodexTaskLifecycleDecoder: CodexTaskLifecycleDecoding, Sendable {
    let timestampParser: any DailyTokenTimestampParsing

    init(timestampParser: any DailyTokenTimestampParsing = CachedDailyTokenTimestampParser.shared) {
        self.timestampParser = timestampParser
    }

    private struct Envelope: Decodable {
        let timestamp: String
        let type: String
        let payload: Payload
    }

    private struct Payload: Decodable {
        let type: String
        let turnID: String

        private enum CodingKeys: String, CodingKey {
            case type
            case turnID = "turn_id"
        }
    }

    func decode(from data: Data) -> CodexTaskLifecycleEvent? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.type == "event_msg",
              let kind = CodexTaskLifecycleKind(rawValue: envelope.payload.type),
              !envelope.payload.turnID.isEmpty,
              let timestamp = timestampParser.parse(envelope.timestamp) else {
            return nil
        }
        return CodexTaskLifecycleEvent(
            kind: kind,
            turnID: envelope.payload.turnID,
            timestamp: timestamp
        )
    }
}

enum CodexTaskLifecycleParser {
    private static let decoder = JSONCodexTaskLifecycleDecoder()

    static func parse(line: String) -> CodexTaskLifecycleEvent? {
        parse(line: line, decoder: decoder)
    }

    static func parse(
        line: String,
        decoder: any CodexTaskLifecycleDecoding
    ) -> CodexTaskLifecycleEvent? {
        guard let data = line.data(using: .utf8),
              CodexTaskLifecycleLineDiscriminator.isLifecycleEvent(data) else {
            return nil
        }
        return decoder.decode(from: data)
    }

    static func parseCompleteLines(in data: Data) -> [CodexTaskLifecycleEvent] {
        parseCompleteLines(in: data, decoder: decoder)
    }

    static func parseCompleteLines(
        in data: Data,
        decoder: any CodexTaskLifecycleDecoding
    ) -> [CodexTaskLifecycleEvent] {
        var events: [CodexTaskLifecycleEvent] = []
        for lineRange in CodexTaskLifecycleLineDiscriminator.completeCandidateLineRanges(in: data) {
            if let event = decoder.decode(from: data.subdata(in: lineRange)) {
                events.append(event)
            }
        }
        return events
    }
}

private enum CodexTaskLifecycleLineDiscriminator {
    private static let started = Data("task_started".utf8)
    private static let completed = Data("task_complete".utf8)

    static func isLifecycleEvent(_ data: Data) -> Bool {
        var scanner = JSONLifecycleScanner(data: data)
        return scanner.isLifecycleEvent()
    }

    static func completeCandidateLineRanges(in data: Data) -> [Range<Data.Index>] {
        var ranges = Set<Range<Data.Index>>()
        for marker in [started, completed] {
            var searchStart = data.startIndex
            while searchStart < data.endIndex,
                  let match = data.range(of: marker, options: [], in: searchStart..<data.endIndex),
                  let lineEnd = data[match.upperBound...].firstIndex(of: 0x0A) {
                let lineStart = data[..<match.lowerBound].lastIndex(of: 0x0A)
                    .map { data.index(after: $0) } ?? data.startIndex
                let range = lineStart..<lineEnd
                if isLifecycleEvent(data.subdata(in: range)) {
                    ranges.insert(range)
                }
                searchStart = data.index(after: lineEnd)
            }
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }
}

private struct JSONLifecycleScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func isLifecycleEvent() -> Bool {
        guard consume(0x7B) else { return false }

        var isEventMessage = false
        var lifecycleType = false
        while true {
            skipWhitespace()
            if consume(0x7D) {
                return isEventMessage && lifecycleType
            }
            guard let key = parseString(), consume(0x3A) else { return false }

            switch key {
            case "type":
                isEventMessage = parseString() == "event_msg"
            case "payload":
                lifecycleType = parsePayloadLifecycleType()
            default:
                guard skipValue() else { return false }
            }

            skipWhitespace()
            if consume(0x7D) {
                return isEventMessage && lifecycleType
            }
            guard consume(0x2C) else { return false }
        }
    }

    private mutating func parsePayloadLifecycleType() -> Bool {
        guard consume(0x7B) else { return false }

        var lifecycleType = false
        while true {
            skipWhitespace()
            if consume(0x7D) { return lifecycleType }
            guard let key = parseString(), consume(0x3A) else { return false }

            if key == "type" {
                let value = parseString()
                lifecycleType = value == "task_started" || value == "task_complete"
            } else if !skipValue() {
                return false
            }

            skipWhitespace()
            if consume(0x7D) { return lifecycleType }
            guard consume(0x2C) else { return false }
        }
    }

    private mutating func skipValue() -> Bool {
        skipWhitespace()
        guard index < bytes.count else { return false }

        switch bytes[index] {
        case 0x22:
            return skipString()
        case 0x7B:
            index += 1
            return skipObject()
        case 0x5B:
            index += 1
            return skipArray()
        default:
            let start = index
            while index < bytes.count,
                  ![0x2C, 0x5D, 0x7D, 0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
            return index > start
        }
    }

    private mutating func skipObject() -> Bool {
        skipWhitespace()
        if consume(0x7D) { return true }
        while true {
            guard parseString() != nil, consume(0x3A), skipValue() else { return false }
            skipWhitespace()
            if consume(0x7D) { return true }
            guard consume(0x2C) else { return false }
        }
    }

    private mutating func skipArray() -> Bool {
        skipWhitespace()
        if consume(0x5D) { return true }
        while true {
            guard skipValue() else { return false }
            skipWhitespace()
            if consume(0x5D) { return true }
            guard consume(0x2C) else { return false }
        }
    }

    private mutating func parseString() -> String? {
        skipWhitespace()
        guard consume(0x22) else { return nil }
        let start = index
        var escaped = false

        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                return String(bytes: bytes[start..<(index - 1)], encoding: .utf8)
            }
        }
        return nil
    }

    private mutating func skipString() -> Bool {
        skipWhitespace()
        guard consume(0x22) else { return false }
        var escaped = false

        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                return true
            }
        }
        return false
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        skipWhitespace()
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            index += 1
        }
    }
}

protocol CodexTaskActivityProviding: AnyObject, Sendable {
    func currentActivity(now: Date) throws -> Bool
}

enum CodexTaskActivityProviderError: Error, Equatable {
    case rootIsNotDirectory
    case cannotEnumerateRoot
    case fileTooLarge
    case aggregateTooLarge
    case readFailed
}

final class CodexTaskActivityProvider: CodexTaskActivityProviding, @unchecked Sendable {
    private static let cacheSchemaVersion = 1
    private static let activityHorizon: TimeInterval = 86_400

    private struct FileIdentity: Codable, Hashable {
        let device: UInt64
        let inode: UInt64

        init?(attributes: [FileAttributeKey: Any]) {
            guard let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
                return nil
            }
            self.device = device
            self.inode = inode
        }
    }

    private enum CursorKey: Hashable {
        case identity(FileIdentity)
        case basename(String)
    }

    private struct FileCursor {
        var url: URL
        var offset: UInt64 = 0
        var partial = Data()
        var activeTurns: [String: Date] = [:]
        var needsBoundaryValidation = false
    }

    private struct Candidate {
        let url: URL
        let modifiedAt: Date
        let byteCount: UInt64
        let identity: FileIdentity?

        var key: CursorKey {
            identity.map(CursorKey.identity) ?? .basename(url.lastPathComponent)
        }
    }

    private struct PersistentCache: Codable {
        let schemaVersion: Int
        let rootsFingerprint: String
        let savedAt: Date
        let cursors: [PersistentCursor]
    }

    private struct PersistentCursor: Codable {
        let path: String
        let basename: String
        let identity: FileIdentity?
        let completeLineOffset: UInt64
        let activeTurns: [PersistentActiveTurn]
    }

    private struct PersistentActiveTurn: Codable {
        let turnID: String
        let startedAt: Date
    }

    private let roots: [URL]
    private let fileManager: FileManager
    private let cacheURL: URL?
    private let maxBytesPerFile: UInt64
    private let maxTotalBytes: UInt64
    private let rootsFingerprint: String
    private let stateLock = NSLock()
    private var didLoadCache = false
    private var cursors: [CursorKey: FileCursor] = [:]

    init(
        roots: [URL]? = nil,
        fileManager: FileManager = .default,
        cacheURL: URL? = nil,
        maxBytesPerFile: UInt64 = 64 * 1_024 * 1_024,
        maxTotalBytes: UInt64 = 256 * 1_024 * 1_024
    ) {
        let defaultRoots = [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/archived_sessions")
        ]
        let resolvedRoots = roots ?? defaultRoots
        self.roots = resolvedRoots
        self.fileManager = fileManager
        self.cacheURL = cacheURL ?? (roots == nil ? Self.defaultCacheURL(fileManager: fileManager) : nil)
        self.maxBytesPerFile = maxBytesPerFile
        self.maxTotalBytes = maxTotalBytes
        self.rootsFingerprint = Self.fingerprint(for: resolvedRoots)
    }

    func currentActivity(now: Date) throws -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        let lowerBound = now.addingTimeInterval(-Self.activityHorizon)
        var refreshed = didLoadCache ? cursors : loadCache(now: now, lowerBound: lowerBound)
        let candidates = try discoverCandidates(modifiedAtOrAfter: lowerBound)
        try validateBudget(for: candidates)

        var discoveredKeys = Set<CursorKey>()
        for candidate in candidates {
            let key = candidate.key
            discoveredKeys.insert(key)
            var cursor = refreshed[key] ?? FileCursor(url: candidate.url)
            try update(&cursor, from: candidate)
            cursor.activeTurns = cursor.activeTurns.filter { $0.value >= lowerBound }
            refreshed[key] = cursor
        }
        refreshed = refreshed.filter { discoveredKeys.contains($0.key) }

        saveCache(refreshed, at: now)
        cursors = refreshed
        didLoadCache = true
        return refreshed.values.contains { !$0.activeTurns.isEmpty }
    }

    private static func defaultCacheURL(fileManager: FileManager) -> URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Codex Meter", isDirectory: true)
            .appendingPathComponent("task-activity-cursors.json")
    }

    private static func fingerprint(for roots: [URL]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in roots.map({ $0.standardizedFileURL.path }).joined(separator: "\0").utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private func loadCache(now: Date, lowerBound: Date) -> [CursorKey: FileCursor] {
        guard let cacheURL,
              let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(PersistentCache.self, from: data),
              cache.schemaVersion == Self.cacheSchemaVersion,
              cache.rootsFingerprint == rootsFingerprint,
              cache.savedAt.timeIntervalSinceReferenceDate.isFinite,
              cache.savedAt >= lowerBound,
              cache.savedAt <= now,
              areValid(cache.cursors) else {
            return [:]
        }

        var loaded: [CursorKey: FileCursor] = [:]
        for persisted in cache.cursors {
            let key = persisted.identity.map(CursorKey.identity) ?? .basename(persisted.basename)
            guard loaded[key] == nil else { return [:] }

            var activeTurns: [String: Date] = [:]
            for activeTurn in persisted.activeTurns {
                guard activeTurns[activeTurn.turnID] == nil else { return [:] }
                activeTurns[activeTurn.turnID] = activeTurn.startedAt
            }
            loaded[key] = FileCursor(
                url: URL(fileURLWithPath: persisted.path),
                offset: persisted.completeLineOffset,
                activeTurns: activeTurns,
                needsBoundaryValidation: true
            )
        }
        return loaded
    }

    private func areValid(_ persisted: [PersistentCursor]) -> Bool {
        var aggregate: UInt64 = 0
        for cursor in persisted {
            guard !cursor.path.isEmpty,
                  !cursor.basename.isEmpty,
                  cursor.completeLineOffset <= maxBytesPerFile,
                  aggregate <= maxTotalBytes,
                  cursor.completeLineOffset <= maxTotalBytes - aggregate else {
                return false
            }
            aggregate += cursor.completeLineOffset

            var turnIDs = Set<String>()
            for activeTurn in cursor.activeTurns {
                guard !activeTurn.turnID.isEmpty,
                      turnIDs.insert(activeTurn.turnID).inserted,
                      activeTurn.startedAt.timeIntervalSinceReferenceDate.isFinite else {
                    return false
                }
            }
        }
        return true
    }

    private func saveCache(_ current: [CursorKey: FileCursor], at now: Date) {
        guard let cacheURL else { return }

        let persisted = current.map { key, cursor -> PersistentCursor in
            let identity: FileIdentity?
            let basename: String
            switch key {
            case let .identity(value):
                identity = value
                basename = cursor.url.lastPathComponent
            case let .basename(value):
                identity = nil
                basename = value
            }
            let completeOffset = cursor.offset - UInt64(cursor.partial.count)
            let activeTurns = cursor.activeTurns
                .map { PersistentActiveTurn(turnID: $0.key, startedAt: $0.value) }
                .sorted { $0.turnID < $1.turnID }
            return PersistentCursor(
                path: cursor.url.path,
                basename: basename,
                identity: identity,
                completeLineOffset: completeOffset,
                activeTurns: activeTurns
            )
        }.sorted { $0.path < $1.path }
        let cache = PersistentCache(
            schemaVersion: Self.cacheSchemaVersion,
            rootsFingerprint: rootsFingerprint,
            savedAt: now,
            cursors: persisted
        )

        do {
            try fileManager.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(cache).write(to: cacheURL, options: .atomic)
        } catch {
            // The cache is only an optimization; the in-memory refresh remains authoritative.
        }
    }

    private func discoverCandidates(modifiedAtOrAfter lowerBound: Date) throws -> [Candidate] {
        var candidates: [Candidate] = []
        for root in roots {
            try appendCandidates(from: root, modifiedAtOrAfter: lowerBound, to: &candidates)
        }

        candidates.sort { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.url.path < rhs.url.path
        }

        var seenBasenames = Set<String>()
        var seenIdentities = Set<FileIdentity>()
        return candidates.filter { candidate in
            if let identity = candidate.identity {
                guard !seenIdentities.contains(identity) else { return false }
            }
            let basename = candidate.url.lastPathComponent
            guard !seenBasenames.contains(basename) else { return false }
            seenBasenames.insert(basename)
            if let identity = candidate.identity {
                seenIdentities.insert(identity)
            }
            return true
        }
    }

    private func appendCandidates(
        from root: URL,
        modifiedAtOrAfter lowerBound: Date,
        to candidates: inout [Candidate]
    ) throws {
        guard try rootExistsAsDirectory(root) else { return }

        var traversalFailed = false
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .contentModificationDateKey,
                .fileSizeKey
            ],
            options: [],
            errorHandler: { _, _ in
                traversalFailed = true
                return false
            }
        ) else {
            throw CodexTaskActivityProviderError.cannotEnumerateRoot
        }

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(atPath: url.path)
            } catch {
                throw CodexTaskActivityProviderError.readFailed
            }
            guard let fileType = attributes[.type] as? FileAttributeType else {
                throw CodexTaskActivityProviderError.readFailed
            }
            guard fileType == .typeRegular else { continue }
            guard let modifiedAt = attributes[.modificationDate] as? Date,
                  let fileSize = attributes[.size] as? NSNumber,
                  fileSize.int64Value >= 0 else {
                throw CodexTaskActivityProviderError.readFailed
            }
            guard modifiedAt >= lowerBound else { continue }
            candidates.append(Candidate(
                url: url,
                modifiedAt: modifiedAt,
                byteCount: fileSize.uint64Value,
                identity: FileIdentity(attributes: attributes)
            ))
        }
        if traversalFailed {
            throw CodexTaskActivityProviderError.cannotEnumerateRoot
        }
    }

    private func rootExistsAsDirectory(_ root: URL) throws -> Bool {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: root.path)
        } catch {
            let cocoaError = error as NSError
            if cocoaError.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(cocoaError.code) {
                return false
            }
            throw CodexTaskActivityProviderError.cannotEnumerateRoot
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw CodexTaskActivityProviderError.rootIsNotDirectory
        }
        return true
    }

    private func validateBudget(for candidates: [Candidate]) throws {
        var aggregate: UInt64 = 0
        for candidate in candidates {
            guard candidate.byteCount <= maxBytesPerFile else {
                throw CodexTaskActivityProviderError.fileTooLarge
            }
            guard aggregate <= maxTotalBytes,
                  candidate.byteCount <= maxTotalBytes - aggregate else {
                throw CodexTaskActivityProviderError.aggregateTooLarge
            }
            aggregate += candidate.byteCount
        }
    }

    private func update(_ cursor: inout FileCursor, from candidate: Candidate) throws {
        cursor.url = candidate.url
        if candidate.byteCount < cursor.offset || (
            cursor.needsBoundaryValidation
                && !isCompleteLineBoundary(
                    cursor.offset,
                    in: candidate.url,
                    fileSize: candidate.byteCount
                )
        ) {
            cursor = FileCursor(url: candidate.url)
        }
        cursor.needsBoundaryValidation = false

        let readStart = cursor.offset
        let newData: Data
        if candidate.byteCount == readStart {
            newData = Data()
        } else {
            newData = try read(from: candidate.url, offset: readStart)
            let (actualEnd, overflow) = readStart.addingReportingOverflow(UInt64(newData.count))
            guard !overflow, actualEnd == candidate.byteCount else {
                throw CodexTaskActivityProviderError.readFailed
            }
        }

        var completeAndPartial = cursor.partial
        completeAndPartial.append(newData)
        if let finalNewline = completeAndPartial.lastIndex(of: 0x0A) {
            let partialStart = completeAndPartial.index(after: finalNewline)
            cursor.partial = Data(completeAndPartial[partialStart...])
        } else {
            cursor.partial = completeAndPartial
        }

        for event in CodexTaskLifecycleParser.parseCompleteLines(in: completeAndPartial) {
            switch event.kind {
            case .started:
                cursor.activeTurns[event.turnID] = event.timestamp
            case .completed:
                cursor.activeTurns.removeValue(forKey: event.turnID)
            }
        }
        cursor.offset = readStart + UInt64(newData.count)
    }

    private func read(from url: URL, offset: UInt64) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            return try handle.readToEnd() ?? Data()
        } catch {
            throw CodexTaskActivityProviderError.readFailed
        }
    }

    private func isCompleteLineBoundary(
        _ offset: UInt64,
        in url: URL,
        fileSize: UInt64
    ) -> Bool {
        guard offset > 0 else { return true }
        guard offset <= fileSize else { return false }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset - 1)
            return try handle.read(upToCount: 1)?.first == 0x0A
        } catch {
            return false
        }
    }
}
