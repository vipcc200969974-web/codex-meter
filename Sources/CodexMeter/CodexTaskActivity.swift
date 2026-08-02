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
