import Foundation

struct DailyTokenUsage: Codable, Equatable, Sendable {
    var totalTokens: Int64
    var cachedInputTokens: Int64
    var nonCachedInputTokens: Int64
    var outputTokens: Int64
    var reasoningOutputTokens: Int64
    var latestEventAt: Date?

    static let zero = DailyTokenUsage(
        totalTokens: 0,
        cachedInputTokens: 0,
        nonCachedInputTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        latestEventAt: nil
    )

    var hasValidMetrics: Bool {
        let values = [
            totalTokens,
            cachedInputTokens,
            nonCachedInputTokens,
            outputTokens,
            reasoningOutputTokens
        ]
        guard values.allSatisfy({ $0 >= 0 && $0 < Int64.max }) else { return false }
        guard reasoningOutputTokens <= outputTokens else { return false }
        let (inputTokens, inputOverflow) = cachedInputTokens.addingReportingOverflow(
            nonCachedInputTokens
        )
        let (components, componentOverflow) = inputTokens.addingReportingOverflow(outputTokens)
        return !inputOverflow && !componentOverflow && components <= totalTokens
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            totalTokens: lhs.totalTokens + rhs.totalTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            nonCachedInputTokens: lhs.nonCachedInputTokens + rhs.nonCachedInputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            reasoningOutputTokens: lhs.reasoningOutputTokens + rhs.reasoningOutputTokens,
            latestEventAt: [lhs.latestEventAt, rhs.latestEventAt].compactMap { $0 }.max()
        )
    }

    var cachedFraction: Double { fraction(cachedInputTokens) }
    var nonCachedFraction: Double { fraction(nonCachedInputTokens) }
    var outputFraction: Double { fraction(outputTokens) }

    private func fraction(_ value: Int64) -> Double {
        guard compositionDenominator > 0 else { return 0 }
        return min(max(Double(value), 0) / compositionDenominator, 1)
    }

    private var compositionDenominator: Double {
        guard totalTokens > 0 else { return 0 }
        // Normal records use totalTokens. If nonnegative visible components
        // exceed it, normalize by their sum so segment widths remain finite;
        // reasoning is already a subset of output and is intentionally excluded.
        let components = [cachedInputTokens, nonCachedInputTokens, outputTokens]
            .reduce(0.0) { $0 + max(Double($1), 0) }
        return max(Double(totalTokens), components)
    }
}

struct DailyTokenEvent: Equatable, Sendable {
    let timestamp: Date
    let usage: DailyTokenUsage
}

protocol DailyTokenEventDecoding {
    func decodeTokenEvent(from data: Data) -> DailyTokenEvent?
}

protocol DailyTokenTimestampParsing: AnyObject, Sendable {
    func parse(_ value: String) -> Date?
}

final class CachedDailyTokenTimestampParser: DailyTokenTimestampParsing, @unchecked Sendable {
    static let shared = CachedDailyTokenTimestampParser()

    private let lock = NSLock()
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let wholeSeconds = ISO8601DateFormatter()

    func parse(_ value: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: value) ?? wholeSeconds.date(from: value)
    }
}

struct JSONDailyTokenEventDecoder: DailyTokenEventDecoding, Sendable {
    let timestampParser: any DailyTokenTimestampParsing

    init(timestampParser: any DailyTokenTimestampParsing = CachedDailyTokenTimestampParser.shared) {
        self.timestampParser = timestampParser
    }

    private struct Envelope: Decodable {
        let timestamp: String
        let payload: Payload
    }

    private struct Payload: Decodable {
        let type: String
        let info: Info?
    }

    private struct Info: Decodable {
        let lastTokenUsage: LastTokenUsage?

        private enum CodingKeys: String, CodingKey {
            case lastTokenUsage = "last_token_usage"
        }
    }

    private struct LastTokenUsage: Decodable {
        let inputTokens: Int64
        let cachedInputTokens: Int64
        let outputTokens: Int64
        let reasoningOutputTokens: Int64
        let totalTokens: Int64

        private enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case cachedInputTokens = "cached_input_tokens"
            case outputTokens = "output_tokens"
            case reasoningOutputTokens = "reasoning_output_tokens"
            case totalTokens = "total_tokens"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            inputTokens = try Self.metric(.inputTokens, from: values)
            cachedInputTokens = try Self.metric(.cachedInputTokens, from: values)
            outputTokens = try Self.metric(.outputTokens, from: values)
            reasoningOutputTokens = try Self.metric(.reasoningOutputTokens, from: values)
            totalTokens = try Self.metric(.totalTokens, from: values)
        }

        private static func metric(
            _ key: CodingKeys,
            from values: KeyedDecodingContainer<CodingKeys>
        ) throws -> Int64 {
            guard values.contains(key), (try? values.decodeNil(forKey: key)) != true else {
                return 0
            }
            if let value = try? values.decode(Int64.self, forKey: key) {
                guard value >= 0, value < Int64.max else {
                    throw invalidMetric(key, in: values)
                }
                return value
            }
            if let value = try? values.decode(Double.self, forKey: key) {
                guard value.isFinite,
                      let integer = Int64(exactly: value),
                      integer >= 0,
                      integer < Int64.max else {
                    throw invalidMetric(key, in: values)
                }
                return integer
            }
            if let value = try? values.decode(String.self, forKey: key) {
                guard let integer = Int64(value), integer >= 0, integer < Int64.max else {
                    throw invalidMetric(key, in: values)
                }
                return integer
            }
            throw invalidMetric(key, in: values)
        }

        private static func invalidMetric(
            _ key: CodingKeys,
            in values: KeyedDecodingContainer<CodingKeys>
        ) -> DecodingError {
            DecodingError.dataCorruptedError(
                forKey: key,
                in: values,
                debugDescription: "Token metric must be a nonnegative representable Int64"
            )
        }
    }

    func decodeTokenEvent(from data: Data) -> DailyTokenEvent? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.payload.type == "token_count",
              let last = envelope.payload.info?.lastTokenUsage,
              last.totalTokens > 0,
              last.cachedInputTokens <= last.inputTokens,
              let timestamp = timestampParser.parse(envelope.timestamp) else {
            return nil
        }

        let usage = DailyTokenUsage(
            totalTokens: last.totalTokens,
            cachedInputTokens: last.cachedInputTokens,
            nonCachedInputTokens: last.inputTokens - last.cachedInputTokens,
            outputTokens: last.outputTokens,
            reasoningOutputTokens: last.reasoningOutputTokens,
            latestEventAt: timestamp
        )
        guard usage.hasValidMetrics else { return nil }
        return DailyTokenEvent(timestamp: timestamp, usage: usage)
    }
}

enum DailyTokenLogParser {
    private static let decoder = JSONDailyTokenEventDecoder()

    static func parse(line: String, inside interval: DateInterval) -> DailyTokenEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        return parse(data: data, inside: interval, decoder: decoder)
    }

    static func parse(
        line: String,
        inside interval: DateInterval,
        decoder: any DailyTokenEventDecoding
    ) -> DailyTokenEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        return parse(data: data, inside: interval, decoder: decoder)
    }

    static func parse(data: Data, inside interval: DateInterval) -> DailyTokenEvent? {
        parse(data: data, inside: interval, decoder: decoder)
    }

    static func parseCompleteLines(in data: Data, inside interval: DateInterval) -> [DailyTokenEvent] {
        parseCompleteLines(in: data, inside: interval, decoder: decoder)
    }

    static func parseCompleteLines(
        in data: Data,
        inside interval: DateInterval,
        decoder: any DailyTokenEventDecoding
    ) -> [DailyTokenEvent] {
        var events: [DailyTokenEvent] = []
        for lineRange in DailyTokenLineDiscriminator.completeCandidateLineRanges(in: data) {
            let line = data.subdata(in: lineRange)
            if let event = decodeCandidate(data: line, inside: interval, decoder: decoder) {
                events.append(event)
            }
        }

        return events
    }

    private static func parse(
        data: Data,
        inside interval: DateInterval,
        decoder: any DailyTokenEventDecoding
    ) -> DailyTokenEvent? {
        guard DailyTokenLineDiscriminator.isTokenCount(data) else { return nil }
        return decodeCandidate(data: data, inside: interval, decoder: decoder)
    }

    private static func decodeCandidate(
        data: Data,
        inside interval: DateInterval,
        decoder: any DailyTokenEventDecoding
    ) -> DailyTokenEvent? {
        guard let event = decoder.decodeTokenEvent(from: data),
              event.timestamp >= interval.start,
              event.timestamp < interval.end else {
            return nil
        }
        return event
    }
}

private enum DailyTokenLineDiscriminator {
    private static let rawTokenCount = Data("token_count".utf8)
    private static let unicodeEscape = Data(#"\u"#.utf8)

    static func isTokenCount(_ data: Data) -> Bool {
        data.range(of: rawTokenCount) != nil || data.range(of: unicodeEscape) != nil
    }

    static func completeCandidateLineRanges(in data: Data) -> [Range<Data.Index>] {
        var lineRanges = Set<Range<Data.Index>>()
        for needle in [rawTokenCount, unicodeEscape] {
            var searchStart = data.startIndex
            while searchStart < data.endIndex,
                  let match = data.range(
                    of: needle,
                    options: [],
                    in: searchStart..<data.endIndex
                  ),
                  let lineEnd = data[match.upperBound...].firstIndex(of: 0x0A) {
                let lineStart = data[..<match.lowerBound].lastIndex(of: 0x0A)
                    .map { data.index(after: $0) } ?? data.startIndex
                lineRanges.insert(lineStart..<lineEnd)
                searchStart = data.index(after: lineEnd)
            }
        }
        return lineRanges.sorted { $0.lowerBound < $1.lowerBound }
    }
}

enum TokenCountFormatter {
    static func compact(_ value: Int64) -> String {
        if value >= 100_000_000 {
            return String(format: "%.1f亿", Double(value) / 100_000_000)
        }
        if value >= 10_000 {
            return String(format: "%.1f万", Double(value) / 10_000)
        }
        return value.formatted(.number.grouping(.automatic))
    }
}

protocol DailyTokenUsageProviding: AnyObject, Sendable {
    func currentUsage(now: Date) throws -> DailyTokenUsage
}

protocol DailyTokenFileReading: Sendable {
    func read(from url: URL, offset: UInt64) throws -> Data
    func readByte(from url: URL, offset: UInt64) throws -> UInt8?
}

struct FileHandleDailyTokenFileReader: DailyTokenFileReading {
    func read(from url: URL, offset: UInt64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.readToEnd() ?? Data()
    }

    func readByte(from url: URL, offset: UInt64) throws -> UInt8? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: 1)?.first
    }
}

enum DailyTokenUsageProviderError: Error, Equatable {
    case aggregateOverflow
}

final class DailyTokenUsageProvider: DailyTokenUsageProviding, @unchecked Sendable {
    private static let cacheSchemaVersion = 1

    private enum DiscoveryError: Error {
        case rootIsNotDirectory(URL)
        case cannotEnumerateRoot(URL)
    }

    private struct FileIdentity: Codable, Hashable {
        let systemNumber: UInt64
        let fileNumber: UInt64

        init?(attributes: [FileAttributeKey: Any]) {
            guard let systemNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
                  let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
                return nil
            }
            self.systemNumber = systemNumber
            self.fileNumber = fileNumber
        }
    }

    private struct FileCursor {
        var url: URL
        var offset: UInt64 = 0
        var partial = Data()
        var usage = DailyTokenUsage.zero
        var needsBoundaryValidation = false
        var loadedFromCache = false
    }

    private enum CursorKey: Hashable {
        case identity(FileIdentity)
        case basename(String)
    }

    private struct Candidate {
        let url: URL
        let modifiedAt: Date
    }

    private struct PersistentCache: Codable {
        let schemaVersion: Int
        let dayStart: Date
        let rootsFingerprint: String
        let cursors: [PersistentCursor]
    }

    private struct PersistentCursor: Codable {
        let path: String
        let basename: String
        let identity: FileIdentity?
        let completeLineOffset: UInt64
        let usage: DailyTokenUsage
    }

    private let roots: [URL]
    private var calendar: Calendar
    private let fileManager: FileManager
    private let fileReader: any DailyTokenFileReading
    private let cacheURL: URL?
    private let rootsFingerprint: String
    private let stateLock = NSLock()
    private var dayInterval: DateInterval?
    private var cursors: [CursorKey: FileCursor] = [:]

    init(
        roots: [URL]? = nil,
        calendar: Calendar = .autoupdatingCurrent,
        fileManager: FileManager = .default,
        fileReader: any DailyTokenFileReading = FileHandleDailyTokenFileReader(),
        cacheURL: URL? = nil
    ) {
        let defaultRoots = [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/archived_sessions")
        ]
        let resolvedRoots = roots ?? defaultRoots
        self.roots = resolvedRoots
        self.calendar = calendar
        self.fileManager = fileManager
        self.fileReader = fileReader
        self.cacheURL = cacheURL ?? (roots == nil ? Self.defaultCacheURL(fileManager: fileManager) : nil)
        self.rootsFingerprint = Self.fingerprint(for: resolvedRoots)
    }

    func currentUsage(now: Date) throws -> DailyTokenUsage {
        stateLock.lock()
        defer { stateLock.unlock() }

        let interval = localDay(containing: now)
        if dayInterval != interval {
            dayInterval = interval
            cursors.removeAll()
            loadCache(for: interval)
        }

        var discoveredKeys = Set<CursorKey>()
        for url in try discoverCandidateFiles(since: interval.start) {
            discoveredKeys.insert(try updateCursor(for: url, interval: interval))
        }
        cursors = cursors.filter { discoveredKeys.contains($0.key) }
        var usage = DailyTokenUsage.zero
        for cursor in cursors.values {
            usage = try Self.adding(usage, cursor.usage)
        }
        saveCache(for: interval)
        return usage
    }

    private static func defaultCacheURL(fileManager: FileManager) -> URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Codex Meter", isDirectory: true)
            .appendingPathComponent("daily-token-cursors.json")
    }

    private static func fingerprint(for roots: [URL]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in roots.map({ $0.standardizedFileURL.path }).joined(separator: "\0").utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private func loadCache(for interval: DateInterval) {
        guard let cacheURL,
              let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(PersistentCache.self, from: data),
              cache.schemaVersion == Self.cacheSchemaVersion,
              cache.dayStart == interval.start,
              cache.rootsFingerprint == rootsFingerprint,
              Self.areValid(cache.cursors, inside: interval) else {
            return
        }

        var loaded: [CursorKey: FileCursor] = [:]
        for persisted in cache.cursors {
            let key = persisted.identity.map(CursorKey.identity) ?? .basename(persisted.basename)
            guard loaded[key] == nil else {
                cursors.removeAll()
                return
            }
            loaded[key] = FileCursor(
                url: URL(fileURLWithPath: persisted.path),
                offset: persisted.completeLineOffset,
                usage: persisted.usage,
                needsBoundaryValidation: true,
                loadedFromCache: true
            )
        }
        cursors = loaded
    }

    private static func areValid(
        _ cursors: [PersistentCursor],
        inside interval: DateInterval
    ) -> Bool {
        var aggregateValues = [Int64](repeating: 0, count: 5)
        for cursor in cursors {
            let usage = cursor.usage
            guard isValid(usage, inside: interval) else { return false }
            let values = [
                usage.totalTokens,
                usage.cachedInputTokens,
                usage.nonCachedInputTokens,
                usage.outputTokens,
                usage.reasoningOutputTokens
            ]
            for index in values.indices {
                let (sum, overflow) = aggregateValues[index].addingReportingOverflow(values[index])
                guard !overflow, sum < Int64.max else { return false }
                aggregateValues[index] = sum
            }
        }
        return true
    }

    private static func isValid(_ usage: DailyTokenUsage, inside interval: DateInterval) -> Bool {
        guard usage.hasValidMetrics else { return false }
        if usage.totalTokens == 0 {
            return usage.latestEventAt == nil
        }
        guard let latest = usage.latestEventAt else { return false }
        return latest >= interval.start && latest < interval.end
    }

    private static func adding(_ lhs: DailyTokenUsage, _ rhs: DailyTokenUsage) throws
        -> DailyTokenUsage {
        DailyTokenUsage(
            totalTokens: try adding(lhs.totalTokens, rhs.totalTokens),
            cachedInputTokens: try adding(lhs.cachedInputTokens, rhs.cachedInputTokens),
            nonCachedInputTokens: try adding(
                lhs.nonCachedInputTokens,
                rhs.nonCachedInputTokens
            ),
            outputTokens: try adding(lhs.outputTokens, rhs.outputTokens),
            reasoningOutputTokens: try adding(
                lhs.reasoningOutputTokens,
                rhs.reasoningOutputTokens
            ),
            latestEventAt: [lhs.latestEventAt, rhs.latestEventAt].compactMap { $0 }.max()
        )
    }

    private static func adding(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, sum < Int64.max else {
            throw DailyTokenUsageProviderError.aggregateOverflow
        }
        return sum
    }

    private func saveCache(for interval: DateInterval) {
        guard let cacheURL else { return }
        let persisted = cursors.map { key, cursor in
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
            return PersistentCursor(
                path: cursor.url.path,
                basename: basename,
                identity: identity,
                completeLineOffset: cursor.offset - UInt64(cursor.partial.count),
                usage: cursor.usage
            )
        }
        let cache = PersistentCache(
            schemaVersion: Self.cacheSchemaVersion,
            dayStart: interval.start,
            rootsFingerprint: rootsFingerprint,
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
            // Persistence is an optimization; live usage remains authoritative.
        }
    }

    private func localDay(containing date: Date) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return DateInterval(start: start, end: end)
    }

    private func discoverCandidateFiles(since start: Date) throws -> [URL] {
        var candidates: [Candidate] = []
        for root in roots {
            try appendRecursiveCandidates(from: root, since: start, to: &candidates)
        }

        candidates.sort { $0.modifiedAt > $1.modifiedAt }
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            seen.insert(candidate.url.lastPathComponent).inserted ? candidate.url : nil
        }
    }

    private func appendRecursiveCandidates(
        from root: URL,
        since start: Date,
        to candidates: inout [Candidate]
    ) throws {
        guard try directoryExists(at: root) else { return }
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]

        var traversalError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                traversalError = error
                return false
            }
        ) else {
            throw DiscoveryError.cannotEnumerateRoot(root)
        }

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            try appendCandidate(url, since: start, keys: keys, to: &candidates)
        }
        if let traversalError {
            throw traversalError
        }
    }

    private func appendCandidate(
        _ url: URL,
        since start: Date,
        keys: [URLResourceKey],
        to candidates: inout [Candidate]
    ) throws {
        let values = try url.resourceValues(forKeys: Set(keys))
        guard values.isRegularFile == true,
              let modifiedAt = values.contentModificationDate,
              modifiedAt >= start else {
            return
        }
        candidates.append(Candidate(url: url, modifiedAt: modifiedAt))
    }

    private func directoryExists(at url: URL) throws -> Bool {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            let cocoaError = error as NSError
            if cocoaError.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(cocoaError.code) {
                return false
            }
            throw error
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw DiscoveryError.rootIsNotDirectory(url)
        }
        return true
    }

    private func updateCursor(for url: URL, interval: DateInterval) throws -> CursorKey {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let identity = FileIdentity(attributes: attributes)
        let key = identity.map(CursorKey.identity) ?? .basename(url.lastPathComponent)
        var cursor = cursors[key] ?? FileCursor(url: url)
        cursor.url = url
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        if fileSize < cursor.offset || (
            cursor.needsBoundaryValidation
                && !isCompleteLineBoundary(cursor.offset, in: url, fileSize: fileSize)
        ) {
            cursor.offset = 0
            cursor.partial = Data()
            cursor.usage = .zero
            cursor.loadedFromCache = false
        }
        cursor.needsBoundaryValidation = false

        do {
            try refreshCursor(&cursor, from: url, fileSize: fileSize, interval: interval)
        } catch DailyTokenUsageProviderError.aggregateOverflow where cursor.loadedFromCache {
            cursor = FileCursor(url: url)
            try refreshCursor(&cursor, from: url, fileSize: fileSize, interval: interval)
        }
        cursor.loadedFromCache = false
        cursors[key] = cursor
        return key
    }

    private func refreshCursor(
        _ cursor: inout FileCursor,
        from url: URL,
        fileSize: UInt64,
        interval: DateInterval
    ) throws {
        let readStart = cursor.offset
        let newData: Data
        if fileSize == readStart, cursor.partial.isEmpty {
            newData = Data()
        } else {
            newData = try fileReader.read(from: url, offset: readStart)
        }

        var combined = cursor.partial
        combined.append(newData)
        if let finalNewline = combined.lastIndex(of: 0x0A) {
            let partialStart = combined.index(after: finalNewline)
            cursor.partial = Data(combined[partialStart...])
        } else {
            cursor.partial = combined
        }
        for event in DailyTokenLogParser.parseCompleteLines(in: combined, inside: interval) {
            cursor.usage = try Self.adding(cursor.usage, event.usage)
        }
        cursor.offset = readStart + UInt64(newData.count)
    }

    private func isCompleteLineBoundary(
        _ offset: UInt64,
        in url: URL,
        fileSize: UInt64
    ) -> Bool {
        guard offset > 0 else { return true }
        guard offset <= fileSize else { return false }
        do {
            return try fileReader.readByte(from: url, offset: offset - 1) == 0x0A
        } catch {
            return false
        }
    }
}
