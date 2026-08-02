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
    private static let eventMessage = Data("event_msg".utf8)
    private static let started = Data("task_started".utf8)
    private static let completed = Data("task_complete".utf8)

    static func isLifecycleEvent(_ data: Data) -> Bool {
        guard data.range(of: eventMessage) != nil else { return false }
        return data.range(of: started) != nil || data.range(of: completed) != nil
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
