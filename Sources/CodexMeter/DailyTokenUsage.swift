import Foundation

struct DailyTokenUsage: Equatable, Sendable {
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
        guard totalTokens > 0 else { return 0 }
        return min(max(Double(value) / Double(totalTokens), 0), 1)
    }
}

struct DailyTokenEvent: Equatable, Sendable {
    let timestamp: Date
    let usage: DailyTokenUsage
}

enum DailyTokenLogParser {
    static func parse(line: String, inside interval: DateInterval) -> DailyTokenEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestampText = object["timestamp"] as? String,
              let timestamp = parseDate(timestampText),
              timestamp >= interval.start,
              timestamp < interval.end,
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any] else {
            return nil
        }

        let input = int64(last["input_tokens"])
        let cached = int64(last["cached_input_tokens"])
        let output = int64(last["output_tokens"])
        let total = int64(last["total_tokens"])
        let reasoning = int64(last["reasoning_output_tokens"])
        guard total > 0 else { return nil }

        return DailyTokenEvent(
            timestamp: timestamp,
            usage: DailyTokenUsage(
                totalTokens: total,
                cachedInputTokens: cached,
                nonCachedInputTokens: max(input - cached, 0),
                outputTokens: output,
                reasoningOutputTokens: reasoning,
                latestEventAt: timestamp
            )
        )
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let value = value as? Int64 { return max(value, 0) }
        if let value = value as? Int { return Int64(max(value, 0)) }
        if let value = value as? Double { return Int64(max(value, 0)) }
        if let value = value as? String, let number = Int64(value) { return max(number, 0) }
        return 0
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
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

final class DailyTokenUsageProvider: DailyTokenUsageProviding, @unchecked Sendable {
    private struct FileIdentity: Equatable {
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
        var identity: FileIdentity?
        var offset: UInt64 = 0
        var partial = Data()
        var usage = DailyTokenUsage.zero
    }

    private let roots: [URL]
    private var calendar: Calendar
    private let fileManager: FileManager
    private var dayInterval: DateInterval?
    private var cursors: [String: FileCursor] = [:]

    init(
        roots: [URL] = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/archived_sessions")
        ],
        calendar: Calendar = .autoupdatingCurrent,
        fileManager: FileManager = .default
    ) {
        self.roots = roots
        self.calendar = calendar
        self.fileManager = fileManager
    }

    func currentUsage(now: Date) throws -> DailyTokenUsage {
        let interval = localDay(containing: now)
        if dayInterval != interval {
            dayInterval = interval
            cursors.removeAll()
        }

        for url in try discoverCandidateFiles(since: interval.start) {
            try updateCursor(for: url, interval: interval)
        }
        return cursors.values.reduce(.zero) { $0 + $1.usage }
    }

    private func localDay(containing date: Date) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return DateInterval(start: start, end: end)
    }

    private func discoverCandidateFiles(since start: Date) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        var candidates: [(url: URL, modifiedAt: Date)] = []

        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: []
            ) else {
                continue
            }

            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true,
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt >= start else {
                    continue
                }
                candidates.append((url, modifiedAt))
            }
        }

        candidates.sort { $0.modifiedAt > $1.modifiedAt }
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            seen.insert(candidate.url.lastPathComponent).inserted ? candidate.url : nil
        }
    }

    private func updateCursor(for url: URL, interval: DateInterval) throws {
        let key = url.lastPathComponent
        var cursor = cursors[key] ?? FileCursor(url: url)
        cursor.url = url

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let identity = FileIdentity(attributes: attributes)
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let wasReplaced = cursor.identity != nil && identity != nil && cursor.identity != identity
        if wasReplaced || fileSize < cursor.offset {
            cursor.offset = 0
            cursor.partial = Data()
            cursor.usage = .zero
        }
        cursor.identity = identity

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let readStart = cursor.offset
        try handle.seek(toOffset: readStart)
        let newData = try handle.readToEnd() ?? Data()

        var combined = cursor.partial
        combined.append(newData)
        let chunks = combined.split(separator: 0x0A, omittingEmptySubsequences: false)
        let endsWithNewline = combined.last == 0x0A
        let complete = chunks.dropLast()
        cursor.partial = endsWithNewline ? Data() : (chunks.last.map { Data($0) } ?? Data())
        for bytes in complete where !bytes.isEmpty {
            let line = String(decoding: bytes, as: UTF8.self)
            if let event = DailyTokenLogParser.parse(line: line, inside: interval) {
                cursor.usage = cursor.usage + event.usage
            }
        }
        cursor.offset = readStart + UInt64(newData.count)
        cursors[key] = cursor
    }
}
