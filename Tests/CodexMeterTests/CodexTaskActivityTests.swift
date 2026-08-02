import Foundation
import XCTest
@testable import CodexMeter

private final class CountingCodexTaskLifecycleDecoder: CodexTaskLifecycleDecoding, @unchecked Sendable {
    private let base: any CodexTaskLifecycleDecoding
    private(set) var decodeCount = 0

    init(base: any CodexTaskLifecycleDecoding = JSONCodexTaskLifecycleDecoder()) {
        self.base = base
    }

    func decode(from data: Data) -> CodexTaskLifecycleEvent? {
        decodeCount += 1
        return base.decode(from: data)
    }
}

final class CodexTaskActivityTests: XCTestCase {
    func testParsesStartedAndCompletedLifecycleEvents() throws {
        let started = #"{"timestamp":"2026-08-02T02:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a","started_at":"2026-08-02T02:00:00Z"}}"#
        let completed = #"{"timestamp":"2026-08-02T02:01:00Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-a","completed_at":"2026-08-02T02:01:00Z","last_agent_message":"private"}}"#

        XCTAssertEqual(try XCTUnwrap(CodexTaskLifecycleParser.parse(line: started)).kind, .started)
        XCTAssertEqual(try XCTUnwrap(CodexTaskLifecycleParser.parse(line: completed)).kind, .completed)
    }

    func testRejectsUnrelatedPrivateAndMalformedCandidates() {
        let message = #"{"timestamp":"2026-08-02T02:00:00Z","type":"response_item","payload":{"type":"message","content":"private"}}"#
        let missingTurn = #"{"timestamp":"2026-08-02T02:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#
        let missingTimestamp = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a"}}"#

        XCTAssertNil(CodexTaskLifecycleParser.parse(line: message))
        XCTAssertNil(CodexTaskLifecycleParser.parse(line: missingTurn))
        XCTAssertNil(CodexTaskLifecycleParser.parse(line: missingTimestamp))
    }

    func testRawDiscriminatorSkipsLargePrivatePayloadBeforeTypedDecoding() {
        let decoder = CountingCodexTaskLifecycleDecoder()
        let privateContent = String(repeating: "private task_started task_complete ", count: 100_000)
        let line = #"{"timestamp":"2026-08-02T02:00:00Z","type":"response_item","payload":{"type":"message","content":"\#(privateContent)"}}"#

        XCTAssertNil(CodexTaskLifecycleParser.parse(line: line, decoder: decoder))
        XCTAssertEqual(decoder.decodeCount, 0)
    }

    func testParsesOnlyCompleteLifecycleLines() throws {
        let started = #"{"timestamp":"2026-08-02T02:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a"}}"#
        let incomplete = #"{"timestamp":"2026-08-02T02:01:00Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-a"}}"#
        let events = CodexTaskLifecycleParser.parseCompleteLines(in: Data((started + "\n" + incomplete).utf8))

        XCTAssertEqual(events.map(\.kind), [.started])
    }
}
