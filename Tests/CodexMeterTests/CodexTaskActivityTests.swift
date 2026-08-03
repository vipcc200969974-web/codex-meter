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

private final class RemovingAfterTaskMetadataFileManager: FileManager, @unchecked Sendable {
    private let target: URL
    private var didRemove = false

    init(target: URL) {
        self.target = target.standardizedFileURL
        super.init()
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        let attributes = try super.attributesOfItem(atPath: path)
        if URL(fileURLWithPath: path).standardizedFileURL == target, !didRemove {
            try super.removeItem(at: target)
            didRemove = true
        }
        return attributes
    }
}

private final class RemovingAfterRootMetadataFileManager: FileManager, @unchecked Sendable {
    private let target: URL
    private var didRemove = false

    init(target: URL) {
        self.target = target.standardizedFileURL
        super.init()
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        let attributes = try super.attributesOfItem(atPath: path)
        if URL(fileURLWithPath: path).standardizedFileURL == target, !didRemove {
            try super.removeItem(at: target)
            didRemove = true
        }
        return attributes
    }
}

private final class GrowingAfterTaskMetadataFileManager: FileManager, @unchecked Sendable {
    private let target: URL
    private let appendedData: Data
    private var didGrow = false

    init(target: URL, appendedData: Data) {
        self.target = target.standardizedFileURL
        self.appendedData = appendedData
        super.init()
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        let attributes = try super.attributesOfItem(atPath: path)
        if URL(fileURLWithPath: path).standardizedFileURL == target, !didGrow {
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: appendedData)
            didGrow = true
        }
        return attributes
    }
}

final class CodexTaskActivityTests: XCTestCase {
    private var base: URL!
    private var activeRoot: URL!
    private var archivedRoot: URL!
    private var activeFile: URL!
    private var otherFile: URL!
    private var cacheURL: URL!
    private var now: Date!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        activeRoot = base.appendingPathComponent("sessions")
        archivedRoot = base.appendingPathComponent("archived_sessions")
        activeFile = activeRoot.appendingPathComponent("rollout-active.jsonl")
        otherFile = archivedRoot.appendingPathComponent("rollout-other.jsonl")
        cacheURL = base.appendingPathComponent("cache/task-activity.json")
        now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        try FileManager.default.createDirectory(at: activeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base {
            try? FileManager.default.removeItem(at: base)
        }
        try super.tearDownWithError()
    }

    func testParsesStartedAndCompletedLifecycleEvents() throws {
        let started = #"{"timestamp":"2026-08-02T02:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a","started_at":"2026-08-02T02:00:00Z"}}"#
        let completed = #"{"timestamp":"2026-08-02T02:01:00Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-a","completed_at":"2026-08-02T02:01:00Z","last_agent_message":"private"}}"#

        XCTAssertEqual(try XCTUnwrap(CodexTaskLifecycleParser.parse(line: started)).kind, .started)
        XCTAssertEqual(try XCTUnwrap(CodexTaskLifecycleParser.parse(line: completed)).kind, .completed)
    }

    func testParsesAbortedLifecycleEvent() throws {
        let aborted = #"{"timestamp":"2026-08-02T02:01:00Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-a","reason":"interrupted"}}"#

        XCTAssertEqual(try XCTUnwrap(CodexTaskLifecycleParser.parse(line: aborted)).kind, .aborted)
    }

    func testRejectsUnrelatedPrivateAndMalformedCandidates() {
        let message = #"{"timestamp":"2026-08-02T02:00:00Z","type":"response_item","payload":{"type":"message","content":"private"}}"#
        let missingTurn = #"{"timestamp":"2026-08-02T02:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#
        let missingTimestamp = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a"}}"#

        XCTAssertNil(CodexTaskLifecycleParser.parse(line: message))
        XCTAssertNil(CodexTaskLifecycleParser.parse(line: missingTurn))
        XCTAssertNil(CodexTaskLifecycleParser.parse(line: missingTimestamp))
    }

    func testRawDiscriminatorSkipsLargePrivatePayloadWithAllMarkersBeforeTypedDecoding() {
        let privateContent = String(
            repeating: "private event_msg task_started task_complete turn_aborted ",
            count: 100_000
        )
        let line = #"{"timestamp":"2026-08-02T02:00:00Z","type":"response_item","payload":{"type":"message","content":"\#(privateContent)"}}"#

        let lineDecoder = CountingCodexTaskLifecycleDecoder()
        XCTAssertNil(CodexTaskLifecycleParser.parse(line: line, decoder: lineDecoder))
        XCTAssertEqual(lineDecoder.decodeCount, 0)

        let batchDecoder = CountingCodexTaskLifecycleDecoder()
        XCTAssertEqual(
            CodexTaskLifecycleParser.parseCompleteLines(
                in: Data((line + "\n").utf8),
                decoder: batchDecoder
            ),
            []
        )
        XCTAssertEqual(batchDecoder.decodeCount, 0)
    }

    func testParsesOnlyCompleteLifecycleLines() throws {
        let started = #"{"timestamp":"2026-08-02T02:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a"}}"#
        let incomplete = #"{"timestamp":"2026-08-02T02:01:00Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-a"}}"#
        let events = CodexTaskLifecycleParser.parseCompleteLines(in: Data((started + "\n" + incomplete).utf8))

        XCTAssertEqual(events.map(\.kind), [.started])
    }

    func testAnyUncompletedTurnMakesGlobalActivityActive() throws {
        try writeLifecycle(.started, turnID: "a", to: activeFile, at: now.addingTimeInterval(-10))
        let secondActiveFile = activeRoot.appendingPathComponent("rollout-second.jsonl")
        try writeLifecycle(.started, turnID: "b", to: secondActiveFile, at: now.addingTimeInterval(-9))
        try appendLifecycle(.completed, turnID: "a", to: activeFile, at: now.addingTimeInterval(-5))

        XCTAssertTrue(try makeProvider().currentActivity(now: now))

        try appendLifecycle(.completed, turnID: "b", to: secondActiveFile, at: now)
        XCTAssertFalse(try makeProvider().currentActivity(now: now))
    }

    func testAbortedTurnStopsActivity() throws {
        try writeLifecycle(.started, turnID: "stopped", to: activeFile, at: now.addingTimeInterval(-10))
        try appendLifecycle(.aborted, turnID: "stopped", to: activeFile, at: now)

        XCTAssertFalse(try makeProvider().currentActivity(now: now))
    }

    func testNewerCompletionInOneFileOverridesCopiedStartInAnother() throws {
        let copiedFile = activeRoot.appendingPathComponent("rollout-copy.jsonl")
        try writeLifecycle(.started, turnID: "copied", to: activeFile, at: now.addingTimeInterval(-10))
        try writeLifecycle(.started, turnID: "copied", to: copiedFile, at: now.addingTimeInterval(-10))
        try appendLifecycle(.completed, turnID: "copied", to: activeFile, at: now.addingTimeInterval(-5))

        XCTAssertFalse(try makeProvider().currentActivity(now: now))
    }

    func testNewerStartRemainsActiveAfterOlderTerminalState() throws {
        let restartedFile = activeRoot.appendingPathComponent("rollout-restarted.jsonl")
        try writeLifecycle(.completed, turnID: "ordered", to: activeFile, at: now.addingTimeInterval(-10))
        try writeLifecycle(.started, turnID: "ordered", to: restartedFile, at: now.addingTimeInterval(-5))

        XCTAssertTrue(try makeProvider().currentActivity(now: now))
    }

    func testTerminalStateWinsWhenDuplicateEventsHaveEqualTimestamps() throws {
        let copiedFile = activeRoot.appendingPathComponent("rollout-equal.jsonl")
        try writeLifecycle(.started, turnID: "equal", to: activeFile, at: now)
        try writeLifecycle(.completed, turnID: "equal", to: copiedFile, at: now)

        XCTAssertFalse(try makeProvider().currentActivity(now: now))
    }

    func testCompletionForDifferentTurnDoesNotStopActiveTurn() throws {
        try writeLifecycle(.started, turnID: "a", to: activeFile, at: now.addingTimeInterval(-10))
        try appendLifecycle(.completed, turnID: "b", to: activeFile, at: now.addingTimeInterval(-5))

        XCTAssertTrue(try makeProvider().currentActivity(now: now))
    }

    func testTwentyFourHourBoundaryIsActiveButOlderStartIsStale() throws {
        try writeLifecycle(
            .started,
            turnID: "boundary",
            to: activeFile,
            at: now.addingTimeInterval(-86_400)
        )
        XCTAssertTrue(try makeProvider().currentActivity(now: now))

        try writeLifecycle(
            .started,
            turnID: "stale",
            to: otherFile,
            at: now.addingTimeInterval(-86_401)
        )
        XCTAssertFalse(
            try makeProvider(roots: [otherFile.deletingLastPathComponent()])
                .currentActivity(now: now)
        )
    }

    func testIncrementalAppendDoesNotReapplyCoveredLifecycleEvents() throws {
        try writeLifecycle(.started, turnID: "a", to: activeFile, at: now.addingTimeInterval(-10))
        let provider = makeProvider()

        XCTAssertTrue(try provider.currentActivity(now: now))
        try appendLifecycle(.completed, turnID: "a", to: activeFile, at: now)
        XCTAssertFalse(try provider.currentActivity(now: now))
        XCTAssertFalse(try provider.currentActivity(now: now))
    }

    func testIncompleteTrailingLifecycleLineAppliesOnlyAfterNewlineArrives() throws {
        let line = lifecycleLine(.started, turnID: "partial", at: now)
        try Data(line.utf8).write(to: activeFile)
        let provider = makeProvider()

        XCTAssertFalse(try provider.currentActivity(now: now))
        try append(Data("\n".utf8), to: activeFile)
        XCTAssertTrue(try provider.currentActivity(now: now))
    }

    func testOversizedLifecycleLineIsDiscarded() throws {
        let oversized = lifecycleLine(
            .started,
            turnID: "oversized",
            at: now,
            sentinel: String(repeating: "x", count: 70 * 1_024)
        )
        try Data((oversized + "\n").utf8).write(to: activeFile)

        XCTAssertFalse(try makeProvider().currentActivity(now: now))
    }

    func testNormalLifecycleAfterOversizedPrivateLineStillApplies() throws {
        let privateLine = #"{"timestamp":"2026-08-02T02:00:00Z","type":"response_item","payload":{"type":"message","content":""#
            + String(repeating: "task_started private ", count: 5_000)
            + #""}}"#
        try Data((privateLine + "\n").utf8).write(to: activeFile)
        let provider = makeProvider()
        XCTAssertFalse(try provider.currentActivity(now: now))

        try appendLifecycle(.started, turnID: "normal", to: activeFile, at: now)
        XCTAssertTrue(try provider.currentActivity(now: now))
    }

    func testTruncationRebuildsLifecycleState() throws {
        try writeLifecycle(.started, turnID: "old", to: activeFile, at: now.addingTimeInterval(-10))
        try appendLifecycle(.started, turnID: "padding", to: activeFile, at: now.addingTimeInterval(-9))
        let provider = makeProvider()
        XCTAssertTrue(try provider.currentActivity(now: now))

        try overwriteLifecycle(.completed, turnID: "old", in: activeFile, at: now)

        XCTAssertFalse(try provider.currentActivity(now: now))
    }

    func testLargerPathReplacementRebuildsOnNewIdentity() throws {
        try writeLifecycle(.started, turnID: "old", to: activeFile, at: now.addingTimeInterval(-10))
        let provider = makeProvider()
        XCTAssertTrue(try provider.currentActivity(now: now))

        let replacement = base.appendingPathComponent("replacement.tmp")
        let completed = lifecycleLine(.completed, turnID: "old", at: now)
        try Data((completed + String(repeating: " ", count: 2_048) + "\n").utf8)
            .write(to: replacement)
        try FileManager.default.removeItem(at: activeFile)
        try FileManager.default.moveItem(at: replacement, to: activeFile)

        XCTAssertFalse(try provider.currentActivity(now: now))
    }

    func testRestartPreservesCursorWhenSameIdentityMovesAndChangesBasename() throws {
        try writeLifecycle(.started, turnID: "moving", to: activeFile, at: now.addingTimeInterval(-10))
        let seed = makeProvider(cacheURL: cacheURL)
        XCTAssertTrue(try seed.currentActivity(now: now))

        let moved = archivedRoot.appendingPathComponent("renamed-archive.jsonl")
        try FileManager.default.moveItem(at: activeFile, to: moved)
        try appendLifecycle(.completed, turnID: "moving", to: moved, at: now)

        XCTAssertFalse(try makeProvider(cacheURL: cacheURL).currentActivity(now: now))
    }

    func testRestartPreservesAbortedTerminalState() throws {
        try writeLifecycle(.started, turnID: "stopped", to: activeFile, at: now.addingTimeInterval(-10))
        try appendLifecycle(.aborted, turnID: "stopped", to: activeFile, at: now)
        XCTAssertFalse(try makeProvider(cacheURL: cacheURL).currentActivity(now: now))
        let cache = try String(decoding: Data(contentsOf: cacheURL), as: UTF8.self)
        XCTAssertTrue(cache.contains("turn_aborted"))

        XCTAssertFalse(try makeProvider(cacheURL: cacheURL).currentActivity(now: now))
    }

    func testVersionTwoCacheMigratesCoveredAbortWithoutRebuildingSource() throws {
        let startedAt = now.addingTimeInterval(-10)
        try writeLifecycle(.started, turnID: "legacy-stopped", to: activeFile, at: startedAt)
        let oversizedPrivateLine = #"{"timestamp":"2026-08-02T02:00:00Z","type":"response_item","payload":{"type":"message","content":""#
            + String(repeating: "turn_aborted private ", count: 5_000)
            + #""}}"#
        try append(Data((oversizedPrivateLine + "\n").utf8), to: activeFile)
        try appendLifecycle(.aborted, turnID: "legacy-stopped", to: activeFile, at: now)
        XCTAssertFalse(try makeProvider(cacheURL: cacheURL).currentActivity(now: now))
        try mutateCache { object in
            object["schemaVersion"] = 2
            var cursors = try XCTUnwrap(object["cursors"] as? [[String: Any]])
            cursors[0]["activeTurns"] = [[
                "turnID": "legacy-stopped",
                "startedAt": startedAt.timeIntervalSinceReferenceDate
            ]]
            cursors[0].removeValue(forKey: "turnStates")
            object["cursors"] = cursors
        }

        XCTAssertFalse(
            try makeProvider(
                cacheURL: cacheURL,
                maxBytesPerFile: 0,
                maxTotalBytes: 0
            ).currentActivity(now: now)
        )
        let migrated = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
        )
        XCTAssertEqual(migrated["schemaVersion"] as? Int, 3)
    }

    func testVersionTwoCacheMigrationPreservesActiveTurnWithoutRebuildingSource() throws {
        let startedAt = now.addingTimeInterval(-10)
        try writeLifecycle(.started, turnID: "legacy-active", to: activeFile, at: startedAt)
        XCTAssertTrue(try makeProvider(cacheURL: cacheURL).currentActivity(now: now))
        try mutateCache { object in
            object["schemaVersion"] = 2
            var cursors = try XCTUnwrap(object["cursors"] as? [[String: Any]])
            cursors[0]["activeTurns"] = [[
                "turnID": "legacy-active",
                "startedAt": startedAt.timeIntervalSinceReferenceDate
            ]]
            cursors[0].removeValue(forKey: "turnStates")
            object["cursors"] = cursors
        }

        XCTAssertTrue(
            try makeProvider(
                cacheURL: cacheURL,
                maxBytesPerFile: 0,
                maxTotalBytes: 0
            ).currentActivity(now: now)
        )
    }

    func testVersionTwoCacheMigrationRecoversCompletionFromAnotherFile() throws {
        let startedAt = now.addingTimeInterval(-10)
        let copiedFile = activeRoot.appendingPathComponent("rollout-legacy-copy.jsonl")
        try writeLifecycle(.started, turnID: "legacy-copy", to: activeFile, at: startedAt)
        try appendLifecycle(.completed, turnID: "legacy-copy", to: activeFile, at: now.addingTimeInterval(-5))
        try writeLifecycle(.started, turnID: "legacy-copy", to: copiedFile, at: startedAt)
        XCTAssertFalse(try makeProvider(cacheURL: cacheURL).currentActivity(now: now))
        try mutateCache { object in
            object["schemaVersion"] = 2
            var cursors = try XCTUnwrap(object["cursors"] as? [[String: Any]])
            for index in cursors.indices {
                let path = try XCTUnwrap(cursors[index]["path"] as? String)
                cursors[index]["activeTurns"] = path == copiedFile.path ? [[
                    "turnID": "legacy-copy",
                    "startedAt": startedAt.timeIntervalSinceReferenceDate
                ]] : []
                cursors[index].removeValue(forKey: "turnStates")
            }
            object["cursors"] = cursors
        }

        XCTAssertFalse(
            try makeProvider(
                cacheURL: cacheURL,
                maxBytesPerFile: 0,
                maxTotalBytes: 0
            ).currentActivity(now: now)
        )
    }

    func testActiveAndArchiveCopiesWithSameBasenameAreDeduplicated() throws {
        let archivedCopy = archivedRoot.appendingPathComponent(activeFile.lastPathComponent)
        try writeLifecycle(.started, turnID: "copied", to: activeFile, at: now.addingTimeInterval(-10))
        try FileManager.default.copyItem(at: activeFile, to: archivedCopy)
        try appendLifecycle(.completed, turnID: "copied", to: archivedCopy, at: now)

        XCTAssertFalse(try makeProvider().currentActivity(now: now))
    }

    func testCachedFileMayGrowPastAbsolutePerFileCapWhenOnlyAppendIsWithinBudget() throws {
        let padding = String(repeating: " ", count: 2_048)
        try Data((lifecycleLine(.started, turnID: "cached", at: now.addingTimeInterval(-10)) + padding + "\n").utf8)
            .write(to: activeFile)
        XCTAssertTrue(
            try makeProvider(cacheURL: cacheURL, maxBytesPerFile: 4_096, maxTotalBytes: 4_096)
                .currentActivity(now: now)
        )

        let appended = Data((lifecycleLine(.completed, turnID: "cached", at: now) + "\n").utf8)
        try append(appended, to: activeFile)

        XCTAssertFalse(
            try makeProvider(
                cacheURL: cacheURL,
                maxBytesPerFile: UInt64(appended.count),
                maxTotalBytes: UInt64(appended.count)
            ).currentActivity(now: now)
        )
    }

    func testCachedHistoricalOffsetsMayExceedAggregateUnreadBudget() throws {
        let secondActiveFile = activeRoot.appendingPathComponent("rollout-second.jsonl")
        try writeLifecycle(.started, turnID: "first", to: activeFile, at: now.addingTimeInterval(-10))
        try writeLifecycle(.started, turnID: "second", to: secondActiveFile, at: now.addingTimeInterval(-9))
        XCTAssertTrue(
            try makeProvider(cacheURL: cacheURL, maxBytesPerFile: 4_096, maxTotalBytes: 8_192)
                .currentActivity(now: now)
        )

        XCTAssertTrue(
            try makeProvider(cacheURL: cacheURL, maxBytesPerFile: 1, maxTotalBytes: 1)
                .currentActivity(now: now)
        )
    }

    func testColdHugeArchiveDoesNotBlockActiveSessionDetection() throws {
        try writeLifecycle(.started, turnID: "live", to: activeFile, at: now)
        try createSparseFile(at: otherFile, size: 1_024 * 1_024)

        XCTAssertTrue(
            try makeProvider(maxBytesPerFile: 512, maxTotalBytes: 512)
                .currentActivity(now: now)
        )
    }

    func testSameIdentityLargerRewriteRebuildsFromLifecycleNearBeginning() throws {
        try writeLifecycle(.started, turnID: "old", to: activeFile, at: now.addingTimeInterval(-10))
        let provider = makeProvider()
        XCTAssertTrue(try provider.currentActivity(now: now))

        let replacement = lifecycleLine(.completed, turnID: "old", at: now)
            + String(repeating: " ", count: 4_096)
            + "\n"
        let handle = try FileHandle(forWritingTo: activeFile)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(replacement.utf8))
        try handle.close()

        XCTAssertFalse(try provider.currentActivity(now: now))
    }

    func testCorruptCacheIsDiscardedAndRebuiltFromSource() throws {
        try writeLifecycle(.started, turnID: "cached", to: activeFile, at: now.addingTimeInterval(-10))
        XCTAssertTrue(try makeProvider(cacheURL: cacheURL).currentActivity(now: now))
        try Data("not-json".utf8).write(to: cacheURL)
        try overwriteLifecycle(.completed, turnID: "cached", in: activeFile, at: now)

        XCTAssertFalse(try makeProvider(cacheURL: cacheURL).currentActivity(now: now))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)))
    }

    func testCacheContainsCursorMetadataButNotPrivatePayloadSentinel() throws {
        let sentinel = "PRIVATE-PROMPT-SENTINEL"
        try Data((lifecycleLine(.started, turnID: "safe-id", at: now, sentinel: sentinel) + "\n").utf8)
            .write(to: activeFile)

        XCTAssertTrue(try makeProvider(cacheURL: cacheURL).currentActivity(now: now))
        let cache = try String(decoding: Data(contentsOf: cacheURL), as: UTF8.self)

        XCTAssertTrue(cache.contains("schemaVersion"))
        XCTAssertTrue(cache.contains("rootsFingerprint"))
        XCTAssertTrue(cache.contains("savedAt"))
        XCTAssertTrue(cache.contains("completeLineOffset"))
        XCTAssertTrue(cache.contains("generationFingerprint"))
        XCTAssertTrue(cache.contains("turnStates"))
        XCTAssertTrue(cache.contains("task_started"))
        XCTAssertTrue(cache.contains("safe-id"))
        XCTAssertFalse(cache.contains(sentinel))
    }

    func testImpossibleCachedOffsetRebuildsFromSource() throws {
        try writeLifecycle(.started, turnID: "offset", to: activeFile, at: now)
        XCTAssertTrue(try makeProvider(cacheURL: cacheURL).currentActivity(now: now))
        try mutateCache { object in
            var cursors = try XCTUnwrap(object["cursors"] as? [[String: Any]])
            cursors[0]["completeLineOffset"] = 9_999_999
            cursors[0]["turnStates"] = []
            object["cursors"] = cursors
        }

        XCTAssertTrue(try makeProvider(cacheURL: cacheURL).currentActivity(now: now))
    }

    func testNonNewlineCachedBoundaryRebuildsFromSource() throws {
        try writeLifecycle(.started, turnID: "boundary", to: activeFile, at: now)
        XCTAssertTrue(try makeProvider(cacheURL: cacheURL).currentActivity(now: now))
        try mutateCache { object in
            var cursors = try XCTUnwrap(object["cursors"] as? [[String: Any]])
            cursors[0]["completeLineOffset"] = 10
            cursors[0]["turnStates"] = []
            object["cursors"] = cursors
        }

        XCTAssertTrue(try makeProvider(cacheURL: cacheURL).currentActivity(now: now))
    }

    func testMissingRootsAreLegitimateIdleState() throws {
        let missing = base.appendingPathComponent("missing")

        XCTAssertFalse(try makeProvider(roots: [missing]).currentActivity(now: now))
    }

    func testExistingFileRootThrowsRootIsNotDirectory() throws {
        let fileRoot = base.appendingPathComponent("not-a-directory")
        try Data().write(to: fileRoot)

        XCTAssertThrowsError(try makeProvider(roots: [fileRoot]).currentActivity(now: now)) {
            XCTAssertEqual($0 as? CodexTaskActivityProviderError, .rootIsNotDirectory)
        }
    }

    func testUnreadableTraversalThrowsCannotEnumerateRoot() throws {
        let vanishingRoot = base.appendingPathComponent("vanishing-root")
        try FileManager.default.createDirectory(at: vanishingRoot, withIntermediateDirectories: true)
        let provider = makeProvider(
            roots: [vanishingRoot],
            fileManager: RemovingAfterRootMetadataFileManager(target: vanishingRoot)
        )

        XCTAssertThrowsError(try provider.currentActivity(now: now)) {
            XCTAssertEqual($0 as? CodexTaskActivityProviderError, .cannotEnumerateRoot)
        }
    }

    func testCandidateReadFailureThrowsReadFailed() throws {
        try writeLifecycle(.started, turnID: "vanishing", to: activeFile, at: now)
        let provider = makeProvider(
            roots: [activeRoot],
            fileManager: RemovingAfterTaskMetadataFileManager(target: activeFile)
        )

        XCTAssertThrowsError(try provider.currentActivity(now: now)) {
            XCTAssertEqual($0 as? CodexTaskActivityProviderError, .readFailed)
        }
    }

    func testFileGrowthAfterMetadataUsesBoundedSnapshotThenBudgetsAppendOnNextRefresh() throws {
        let approvedData = Data(
            (lifecycleLine(.started, turnID: "bounded", at: now) + "\n").utf8
        )
        try approvedData.write(to: activeFile)
        let fileManager = GrowingAfterTaskMetadataFileManager(
            target: activeFile,
            appendedData: Data(repeating: 0x20, count: 4_096)
        )
        let approvedByteCount = UInt64(approvedData.count)
        let provider = makeProvider(
            roots: [activeRoot],
            fileManager: fileManager,
            maxBytesPerFile: approvedByteCount,
            maxTotalBytes: approvedByteCount
        )

        XCTAssertTrue(try provider.currentActivity(now: now))
        XCTAssertThrowsError(try provider.currentActivity(now: now)) {
            XCTAssertEqual($0 as? CodexTaskActivityProviderError, .fileTooLarge)
        }
    }

    func testColdActiveFileLargerThanReconstructionBudgetIsRefused() throws {
        try createSparseFile(at: activeFile, size: 1_025)

        XCTAssertThrowsError(
            try makeProvider(maxBytesPerFile: 1_024, maxTotalBytes: 4_096)
                .currentActivity(now: now)
        ) {
            XCTAssertEqual($0 as? CodexTaskActivityProviderError, .fileTooLarge)
        }
    }

    func testColdActiveAggregateLargerThanReconstructionBudgetIsRefused() throws {
        for index in 0..<3 {
            try createSparseFile(
                at: activeRoot.appendingPathComponent("rollout-\(index).jsonl"),
                size: 1_024
            )
        }

        XCTAssertThrowsError(
            try makeProvider(maxBytesPerFile: 1_024, maxTotalBytes: 2_048)
                .currentActivity(now: now)
        ) {
            XCTAssertEqual($0 as? CodexTaskActivityProviderError, .aggregateTooLarge)
        }
    }

    func testOversizedValidCacheIsIgnoredAndSourceIsRebuilt() throws {
        try writeLifecycle(.started, turnID: "cached", to: activeFile, at: now)
        XCTAssertTrue(try makeProvider(cacheURL: cacheURL).currentActivity(now: now))

        var sourceBytes = try Data(contentsOf: activeFile)
        sourceBytes.replaceSubrange(
            0..<(sourceBytes.count - 1),
            with: repeatElement(0x20, count: sourceBytes.count - 1)
        )
        try sourceBytes.write(to: activeFile, options: [])

        var oversizedCache = try Data(contentsOf: cacheURL)
        oversizedCache.append(Data(repeating: 0x20, count: 4 * 1_024 * 1_024))
        try oversizedCache.write(to: cacheURL, options: .atomic)

        XCTAssertFalse(try makeProvider(cacheURL: cacheURL).currentActivity(now: now))
    }

    private func makeProvider(
        roots: [URL]? = nil,
        fileManager: FileManager = .default,
        cacheURL: URL? = nil,
        maxBytesPerFile: UInt64 = 64 * 1_024 * 1_024,
        maxTotalBytes: UInt64 = 256 * 1_024 * 1_024
    ) -> CodexTaskActivityProvider {
        CodexTaskActivityProvider(
            roots: roots ?? [activeRoot, archivedRoot],
            fileManager: fileManager,
            cacheURL: cacheURL,
            maxBytesPerFile: maxBytesPerFile,
            maxTotalBytes: maxTotalBytes
        )
    }

    private func lifecycleLine(
        _ kind: CodexTaskLifecycleKind,
        turnID: String,
        at date: Date,
        sentinel: String? = nil
    ) -> String {
        let formatter = ISO8601DateFormatter()
        let privateField = sentinel.map { #", "private":"\#($0)""# } ?? ""
        return #"{"timestamp":"\#(formatter.string(from: date))","type":"event_msg","payload":{"type":"\#(kind.rawValue)","turn_id":"\#(turnID)"\#(privateField)}}"#
    }

    private func writeLifecycle(
        _ kind: CodexTaskLifecycleKind,
        turnID: String,
        to url: URL,
        at date: Date
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data((lifecycleLine(kind, turnID: turnID, at: date) + "\n").utf8).write(to: url)
    }

    private func appendLifecycle(
        _ kind: CodexTaskLifecycleKind,
        turnID: String,
        to url: URL,
        at date: Date
    ) throws {
        try append(Data((lifecycleLine(kind, turnID: turnID, at: date) + "\n").utf8), to: url)
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func overwriteLifecycle(
        _ kind: CodexTaskLifecycleKind,
        turnID: String,
        in url: URL,
        at date: Date
    ) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((lifecycleLine(kind, turnID: turnID, at: date) + "\n").utf8))
    }

    private func mutateCache(_ mutation: (inout [String: Any]) throws -> Void) throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
        )
        try mutation(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: cacheURL, options: .atomic)
    }

    private func createSparseFile(at url: URL, size: UInt64) throws {
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
    }
}
