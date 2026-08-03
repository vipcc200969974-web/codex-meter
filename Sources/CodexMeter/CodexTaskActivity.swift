import CryptoKit
import Foundation

enum CodexTaskLifecycleKind: String, Codable, Sendable {
    case started = "task_started"
    case completed = "task_complete"
    case aborted = "turn_aborted"
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
    private static let aborted = Data("turn_aborted".utf8)

    static func isLifecycleEvent(_ data: Data) -> Bool {
        var scanner = JSONLifecycleScanner(data: data)
        return scanner.isLifecycleEvent()
    }

    static func completeCandidateLineRanges(in data: Data) -> [Range<Data.Index>] {
        var ranges = Set<Range<Data.Index>>()
        for marker in [started, completed, aborted] {
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
                guard parseString() == "event_msg" else { return false }
                isEventMessage = true
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
                guard value == "task_started"
                    || value == "task_complete"
                    || value == "turn_aborted" else {
                    return false
                }
                lifecycleType = true
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
    private static let cacheSchemaVersion = 3
    private static let activityHorizon: TimeInterval = 86_400
    private static let maxCacheBytes: UInt64 = 4 * 1_024 * 1_024
    private static let readChunkBytes = 4 * 1_024 * 1_024
    private static let fingerprintSampleBytes: UInt64 = 4 * 1_024
    private static let legacyCandidateLineLimitBytes = 64 * 1_024
    private static let completedMarker = Data("task_complete".utf8)
    private static let abortedMarker = Data("turn_aborted".utf8)

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
        var turnStates: [String: CodexTaskLifecycleEvent] = [:]
        var generationFingerprint: String?
        var needsBoundaryValidation = false
    }

    private struct Candidate {
        let url: URL
        let modifiedAt: Date
        let byteCount: UInt64
        let identity: FileIdentity?
        let isArchived: Bool

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
        let generationFingerprint: String
        let turnStates: [PersistentTurnState]
    }

    private struct PersistentTurnState: Codable {
        let turnID: String
        let kind: CodexTaskLifecycleKind
        let timestamp: Date
    }

    private struct LegacyPersistentCache: Codable {
        let schemaVersion: Int
        let rootsFingerprint: String
        let savedAt: Date
        let cursors: [LegacyPersistentCursor]
    }

    private struct LegacyPersistentCursor: Codable {
        let path: String
        let basename: String
        let identity: FileIdentity?
        let completeLineOffset: UInt64
        let generationFingerprint: String
        let activeTurns: [LegacyPersistentActiveTurn]
    }

    private struct LegacyPersistentActiveTurn: Codable {
        let turnID: String
        let startedAt: Date
    }

    private struct BoundedRead {
        let data: Data
        let hasMoreBytes: Bool
    }

    private let roots: [URL]
    private let archivedRootPaths: Set<String>
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
        maxBytesPerFile: UInt64 = 256 * 1_024 * 1_024,
        maxTotalBytes: UInt64 = 512 * 1_024 * 1_024
    ) {
        let defaultRoots = [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/archived_sessions")
        ]
        let resolvedRoots = roots ?? defaultRoots
        self.roots = resolvedRoots
        self.archivedRootPaths = Set(
            resolvedRoots
                .filter { $0.lastPathComponent == "archived_sessions" }
                .map { $0.standardizedFileURL.path }
        )
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

        var discoveredKeys = Set<CursorKey>()
        var unreadAggregate: UInt64 = 0
        for candidate in candidates {
            let key = candidate.key
            guard refreshed[key] != nil || !candidate.isArchived else {
                continue
            }
            discoveredKeys.insert(key)
            var cursor = refreshed[key] ?? FileCursor(url: candidate.url)
            try prepare(&cursor, for: candidate)
            let unreadByteCount = candidate.byteCount - cursor.offset
            try validateBudget(
                unreadByteCount: unreadByteCount,
                aggregate: &unreadAggregate
            )
            try updatePrepared(&cursor, from: candidate)
            cursor.turnStates = cursor.turnStates.filter { $0.value.timestamp >= lowerBound }
            refreshed[key] = cursor
        }
        refreshed = refreshed.filter { discoveredKeys.contains($0.key) }

        saveCache(refreshed, at: now)
        cursors = refreshed
        didLoadCache = true
        var latestStates: [String: CodexTaskLifecycleEvent] = [:]
        for cursor in refreshed.values {
            for event in cursor.turnStates.values {
                Self.merge(event, into: &latestStates)
            }
        }
        return latestStates.values.contains { $0.kind == .started }
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
              let data = readCacheData(at: cacheURL) else {
            return [:]
        }

        if let cache = try? JSONDecoder().decode(PersistentCache.self, from: data),
           cache.schemaVersion == Self.cacheSchemaVersion,
           isValidCacheHeader(
               rootsFingerprint: cache.rootsFingerprint,
               savedAt: cache.savedAt,
               now: now,
               lowerBound: lowerBound
           ),
           areValid(cache.cursors) {
            return restore(cache.cursors)
        }

        if let legacy = try? JSONDecoder().decode(LegacyPersistentCache.self, from: data),
           legacy.schemaVersion == 2,
           isValidCacheHeader(
               rootsFingerprint: legacy.rootsFingerprint,
               savedAt: legacy.savedAt,
               now: now,
               lowerBound: lowerBound
           ),
           areValid(legacy.cursors) {
            return migrate(legacy.cursors, lowerBound: lowerBound)
        }

        return [:]
    }

    private func isValidCacheHeader(
        rootsFingerprint: String,
        savedAt: Date,
        now: Date,
        lowerBound: Date
    ) -> Bool {
        rootsFingerprint == self.rootsFingerprint
            && savedAt.timeIntervalSinceReferenceDate.isFinite
            && savedAt >= lowerBound
            && savedAt <= now
    }

    private func restore(_ persistedCursors: [PersistentCursor]) -> [CursorKey: FileCursor] {
        var loaded: [CursorKey: FileCursor] = [:]
        for persisted in persistedCursors {
            let key = persisted.identity.map(CursorKey.identity) ?? .basename(persisted.basename)
            guard loaded[key] == nil else { return [:] }

            var turnStates: [String: CodexTaskLifecycleEvent] = [:]
            for state in persisted.turnStates {
                guard turnStates[state.turnID] == nil else { return [:] }
                turnStates[state.turnID] = CodexTaskLifecycleEvent(
                    kind: state.kind,
                    turnID: state.turnID,
                    timestamp: state.timestamp
                )
            }
            loaded[key] = FileCursor(
                url: URL(fileURLWithPath: persisted.path),
                offset: persisted.completeLineOffset,
                turnStates: turnStates,
                generationFingerprint: persisted.generationFingerprint,
                needsBoundaryValidation: true
            )
        }
        return loaded
    }

    private func migrate(
        _ persistedCursors: [LegacyPersistentCursor],
        lowerBound: Date
    ) -> [CursorKey: FileCursor] {
        var loaded: [CursorKey: FileCursor] = [:]
        var activeTurnIDs = Set<String>()
        for persisted in persistedCursors {
            let key = persisted.identity.map(CursorKey.identity) ?? .basename(persisted.basename)
            guard loaded[key] == nil else { return [:] }

            var turnStates: [String: CodexTaskLifecycleEvent] = [:]
            for activeTurn in persisted.activeTurns where activeTurn.startedAt >= lowerBound {
                let event = CodexTaskLifecycleEvent(
                    kind: .started,
                    turnID: activeTurn.turnID,
                    timestamp: activeTurn.startedAt
                )
                turnStates[activeTurn.turnID] = event
                activeTurnIDs.insert(activeTurn.turnID)
            }
            loaded[key] = FileCursor(
                url: URL(fileURLWithPath: persisted.path),
                offset: persisted.completeLineOffset,
                turnStates: turnStates,
                generationFingerprint: persisted.generationFingerprint,
                needsBoundaryValidation: true
            )
        }

        guard !activeTurnIDs.isEmpty else { return loaded }
        for persisted in persistedCursors {
            let key = persisted.identity.map(CursorKey.identity) ?? .basename(persisted.basename)
            guard var cursor = loaded[key],
                  let recovered = try? recoverLegacyTerminalEvents(
                      from: URL(fileURLWithPath: persisted.path),
                      through: persisted.completeLineOffset,
                      matching: activeTurnIDs
                  ) else {
                continue
            }
            for event in recovered.values {
                Self.merge(event, into: &cursor.turnStates)
            }
            loaded[key] = cursor
        }
        return loaded
    }

    private func readCacheData(at url: URL) -> Data? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value >= 0,
              fileSize.uint64Value <= Self.maxCacheBytes else {
            return nil
        }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let result = try Self.readExactly(
                from: handle,
                byteCount: fileSize.uint64Value
            )
            guard UInt64(result.data.count) == fileSize.uint64Value,
                  !result.hasMoreBytes else {
                return nil
            }
            return result.data
        } catch {
            return nil
        }
    }

    private func areValid(_ persisted: [PersistentCursor]) -> Bool {
        for cursor in persisted {
            guard !cursor.path.isEmpty,
                  !cursor.basename.isEmpty,
                  cursor.generationFingerprint.count == 64,
                  cursor.generationFingerprint.allSatisfy({ $0.isHexDigit }) else {
                return false
            }

            var turnIDs = Set<String>()
            for state in cursor.turnStates {
                guard !state.turnID.isEmpty,
                      turnIDs.insert(state.turnID).inserted,
                      state.timestamp.timeIntervalSinceReferenceDate.isFinite else {
                    return false
                }
            }
        }
        return true
    }

    private func areValid(_ persisted: [LegacyPersistentCursor]) -> Bool {
        for cursor in persisted {
            guard !cursor.path.isEmpty,
                  !cursor.basename.isEmpty,
                  cursor.generationFingerprint.count == 64,
                  cursor.generationFingerprint.allSatisfy({ $0.isHexDigit }) else {
                return false
            }

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
            let turnStates = cursor.turnStates.values
                .map {
                    PersistentTurnState(
                        turnID: $0.turnID,
                        kind: $0.kind,
                        timestamp: $0.timestamp
                    )
                }
                .sorted { $0.turnID < $1.turnID }
            return PersistentCursor(
                path: cursor.url.path,
                basename: basename,
                identity: identity,
                completeLineOffset: completeOffset,
                generationFingerprint: cursor.generationFingerprint ?? "",
                turnStates: turnStates
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
            try appendCandidates(
                from: root,
                isArchived: archivedRootPaths.contains(root.standardizedFileURL.path),
                modifiedAtOrAfter: lowerBound,
                to: &candidates
            )
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
        isArchived: Bool,
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
                identity: FileIdentity(attributes: attributes),
                isArchived: isArchived
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

    private func validateBudget(
        unreadByteCount: UInt64,
        aggregate: inout UInt64
    ) throws {
        guard unreadByteCount <= maxBytesPerFile else {
            throw CodexTaskActivityProviderError.fileTooLarge
        }
        guard aggregate <= maxTotalBytes,
              unreadByteCount <= maxTotalBytes - aggregate else {
            throw CodexTaskActivityProviderError.aggregateTooLarge
        }
        aggregate += unreadByteCount
    }

    private func prepare(_ cursor: inout FileCursor, for candidate: Candidate) throws {
        cursor.url = candidate.url
        let completeOffset = cursor.offset - UInt64(cursor.partial.count)
        let invalidBoundary = cursor.needsBoundaryValidation
            && !isCompleteLineBoundary(
                completeOffset,
                in: candidate.url,
                fileSize: candidate.byteCount
            )
        let invalidGeneration: Bool
        if let expectedFingerprint = cursor.generationFingerprint,
           completeOffset <= candidate.byteCount {
            invalidGeneration = try generationFingerprint(
                of: candidate.url,
                through: completeOffset
            ) != expectedFingerprint
        } else {
            invalidGeneration = cursor.generationFingerprint != nil
        }

        if candidate.byteCount < cursor.offset || invalidBoundary || invalidGeneration {
            cursor = FileCursor(url: candidate.url)
        }
        cursor.needsBoundaryValidation = false
    }

    private func updatePrepared(_ cursor: inout FileCursor, from candidate: Candidate) throws {
        let readStart = cursor.offset
        let approvedByteCount = candidate.byteCount - readStart
        do {
            let handle = try FileHandle(forReadingFrom: candidate.url)
            defer { try? handle.close() }
            try handle.seek(toOffset: readStart)

            var remaining = approvedByteCount
            while remaining > 0 {
                let requested = Int(min(UInt64(Self.readChunkBytes), remaining))
                guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty else {
                    throw CodexTaskActivityProviderError.readFailed
                }
                consume(chunk, into: &cursor)
                remaining -= UInt64(chunk.count)
            }

        } catch let error as CodexTaskActivityProviderError {
            throw error
        } catch {
            throw CodexTaskActivityProviderError.readFailed
        }

        cursor.offset = readStart + approvedByteCount
        let completeOffset = cursor.offset - UInt64(cursor.partial.count)
        cursor.generationFingerprint = try generationFingerprint(
            of: candidate.url,
            through: completeOffset
        )
    }

    private func consume(_ newData: Data, into cursor: inout FileCursor) {
        cursor.partial.append(newData)
        guard let finalNewline = cursor.partial.lastIndex(of: 0x0A) else { return }
        let partialStart = cursor.partial.index(after: finalNewline)
        let completeData = cursor.partial.subdata(in: cursor.partial.startIndex..<partialStart)
        cursor.partial = Data(cursor.partial[partialStart...])

        for event in CodexTaskLifecycleParser.parseCompleteLines(in: completeData) {
            Self.merge(event, into: &cursor.turnStates)
        }
    }

    private static func merge(
        _ candidate: CodexTaskLifecycleEvent,
        into states: inout [String: CodexTaskLifecycleEvent]
    ) {
        guard let current = states[candidate.turnID] else {
            states[candidate.turnID] = candidate
            return
        }
        if candidate.timestamp > current.timestamp
            || (candidate.timestamp == current.timestamp
                && current.kind == .started
                && candidate.kind != .started) {
            states[candidate.turnID] = candidate
        }
    }

    private func recoverLegacyTerminalEvents(
        from url: URL,
        through completeLineOffset: UInt64,
        matching turnIDs: Set<String>
    ) throws -> [String: CodexTaskLifecycleEvent] {
        guard completeLineOffset > 0, !turnIDs.isEmpty else { return [:] }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var remaining = completeLineOffset
            var pendingLine = Data()
            var discardingOversizedLine = false
            var recovered: [String: CodexTaskLifecycleEvent] = [:]
            while remaining > 0 {
                let requested = Int(min(UInt64(Self.readChunkBytes), remaining))
                guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty else {
                    throw CodexTaskActivityProviderError.readFailed
                }
                remaining -= UInt64(chunk.count)

                var segmentStart = chunk.startIndex
                while segmentStart < chunk.endIndex {
                    if let newline = chunk[segmentStart...].firstIndex(of: 0x0A) {
                        consumeLegacyLineSegment(
                            chunk[segmentStart..<newline],
                            endsLine: true,
                            pendingLine: &pendingLine,
                            discardingOversizedLine: &discardingOversizedLine,
                            matching: turnIDs,
                            recovered: &recovered
                        )
                        segmentStart = chunk.index(after: newline)
                    } else {
                        consumeLegacyLineSegment(
                            chunk[segmentStart..<chunk.endIndex],
                            endsLine: false,
                            pendingLine: &pendingLine,
                            discardingOversizedLine: &discardingOversizedLine,
                            matching: turnIDs,
                            recovered: &recovered
                        )
                        break
                    }
                }
            }
            return recovered
        } catch let error as CodexTaskActivityProviderError {
            throw error
        } catch {
            throw CodexTaskActivityProviderError.readFailed
        }
    }

    private func consumeLegacyLineSegment(
        _ segment: Data.SubSequence,
        endsLine: Bool,
        pendingLine: inout Data,
        discardingOversizedLine: inout Bool,
        matching turnIDs: Set<String>,
        recovered: inout [String: CodexTaskLifecycleEvent]
    ) {
        if discardingOversizedLine {
            if endsLine {
                discardingOversizedLine = false
            }
            return
        }

        guard pendingLine.count <= Self.legacyCandidateLineLimitBytes,
              segment.count <= Self.legacyCandidateLineLimitBytes - pendingLine.count else {
            pendingLine.removeAll(keepingCapacity: false)
            discardingOversizedLine = !endsLine
            return
        }

        if pendingLine.isEmpty, endsLine {
            guard segment.range(of: Self.completedMarker) != nil
                    || segment.range(of: Self.abortedMarker) != nil else {
                return
            }
            recoverLegacyTerminalEvent(
                from: Data(segment),
                matching: turnIDs,
                into: &recovered
            )
            return
        }

        pendingLine.append(contentsOf: segment)
        guard endsLine else { return }
        recoverLegacyTerminalEvent(
            from: pendingLine,
            matching: turnIDs,
            into: &recovered
        )
        pendingLine.removeAll(keepingCapacity: true)
    }

    private func recoverLegacyTerminalEvent(
        from line: Data,
        matching turnIDs: Set<String>,
        into recovered: inout [String: CodexTaskLifecycleEvent]
    ) {
        guard line.range(of: Self.completedMarker) != nil
                || line.range(of: Self.abortedMarker) != nil,
              let event = CodexTaskLifecycleParser.parseCompleteLines(in: line + Data([0x0A])).first,
              event.kind != .started,
              turnIDs.contains(event.turnID) else {
            return
        }
        Self.merge(event, into: &recovered)
    }

    private static func readExactly(
        from handle: FileHandle,
        byteCount: UInt64
    ) throws -> BoundedRead {
        guard byteCount <= UInt64(Int.max) else {
            throw CodexTaskActivityProviderError.fileTooLarge
        }

        var remaining = Int(byteCount)
        var data = Data()
        data.reserveCapacity(remaining)
        while remaining > 0 {
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
            remaining -= chunk.count
        }
        let hasMoreBytes = try handle.read(upToCount: 1)?.isEmpty == false
        return BoundedRead(data: data, hasMoreBytes: hasMoreBytes)
    }

    private func generationFingerprint(
        of url: URL,
        through offset: UInt64
    ) throws -> String {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var hasher = SHA256()
            var encodedOffset = offset.bigEndian
            withUnsafeBytes(of: &encodedOffset) { bytes in
                hasher.update(data: Data(bytes))
            }

            let prefixCount = min(offset, Self.fingerprintSampleBytes)
            if prefixCount > 0 {
                try handle.seek(toOffset: 0)
                let prefix = try Self.readExactly(from: handle, byteCount: prefixCount)
                guard UInt64(prefix.data.count) == prefixCount else {
                    throw CodexTaskActivityProviderError.readFailed
                }
                hasher.update(data: prefix.data)
            }

            let boundaryStart = offset > Self.fingerprintSampleBytes
                ? offset - Self.fingerprintSampleBytes
                : 0
            if boundaryStart > 0 {
                try handle.seek(toOffset: boundaryStart)
                let boundary = try Self.readExactly(
                    from: handle,
                    byteCount: offset - boundaryStart
                )
                guard UInt64(boundary.data.count) == offset - boundaryStart else {
                    throw CodexTaskActivityProviderError.readFailed
                }
                hasher.update(data: boundary.data)
            }

            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch let error as CodexTaskActivityProviderError {
            throw error
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
