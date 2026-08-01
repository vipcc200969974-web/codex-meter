# Real-Time Usage and Daily Tokens Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Codex Meter react to local Codex log writes within 1-3 seconds and show today's complete token usage with a proportional composition bar.

**Architecture:** Add a stateful local token-log reader and a native file-system watcher, then coordinate both quota and token reads through one serialized `UsageStore`. Quota providers expose source timestamps and are merged by window freshness; the SwiftUI popover renders one atomic `UsageSnapshot` while the menu-bar title remains quota-only.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Foundation `DispatchSourceFileSystemObject`, XCTest, SQLite CLI, macOS 14+

## Global Constraints

- Keep the app local-first and make no network requests.
- Do not parse or expose prompts, replies, attachments, authentication data, or other private session content.
- Read only structured `payload.type == "token_count"` events for token statistics.
- Define today with `Calendar.autoupdatingCurrent`; on the target Mac the time zone is Asia/Shanghai.
- Keep the permanent menu-bar title in the existing `percent | reset` form.
- Use an 800-millisecond event debounce and retain the 60-second fallback poll.
- Treat `reasoning_output_tokens` as a subset of output and never add it to the total twice.
- Preserve the last valid values during a temporary read failure and mark them stale.
- Add no third-party dependency.
- All existing quota tests must remain green.

## File Structure

- Create `Sources/CodexMeter/DailyTokenUsage.swift` for daily token models, structured JSONL parsing, incremental file cursors, and compact number formatting.
- Create `Sources/CodexMeter/CodexActivityWatcher.swift` for native directory/file watchers and watcher rebinding.
- Modify `Sources/CodexMeter/CodexMeterApp.swift` for quota observation selection, atomic usage snapshots, refresh coordination, and the token UI.
- Create `Tests/CodexMeterTests/DailyTokenUsageTests.swift` for token parsing, aggregation, day boundaries, cursor behavior, and formatting.
- Create `Tests/CodexMeterTests/QuotaObservationSelectionTests.swift` for cross-source freshness and same-window monotonicity.
- Create `Tests/CodexMeterTests/CodexActivityWatcherTests.swift` for write notification and rebinding behavior.
- Create `Tests/CodexMeterTests/UsageStoreTests.swift` for debounce, pending refresh, stale retention, and atomic publication.
- Modify `Tests/CodexMeterTests/CodexLogQuotaProviderTests.swift` and `Tests/CodexMeterTests/CodexSessionQuotaProviderTests.swift` for the observation-returning provider interface.
- Modify `README.md` to document near-real-time refresh, today's token statistics, and the local structured fields used.

---

### Task 1: Daily Token Domain Model, Parser, and Formatter

**Files:**
- Create: `Sources/CodexMeter/DailyTokenUsage.swift`
- Create: `Tests/CodexMeterTests/DailyTokenUsageTests.swift`

**Interfaces:**
- Consumes: Foundation JSON decoding and a caller-provided `DateInterval`.
- Produces: `DailyTokenUsage`, `DailyTokenEvent`, `DailyTokenLogParser.parse(line:inside:)`, and `TokenCountFormatter.compact(_:)`.

- [ ] **Step 1: Write failing parser and arithmetic tests**

Create `Tests/CodexMeterTests/DailyTokenUsageTests.swift` with the following initial tests:

```swift
import Foundation
import XCTest
@testable import CodexMeter

final class DailyTokenUsageTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        return calendar
    }

    func testParsesStructuredTokenCountAndSeparatesCachedInput() throws {
        let start = ISO8601DateFormatter().date(from: "2026-07-31T16:00:00Z")!
        let interval = DateInterval(start: start, duration: 86_400)
        let line = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":100,"reasoning_output_tokens":20,"total_tokens":1100}}}}"#

        let event = try XCTUnwrap(DailyTokenLogParser.parse(line: line, inside: interval))

        XCTAssertEqual(event.usage.totalTokens, 1_100)
        XCTAssertEqual(event.usage.cachedInputTokens, 800)
        XCTAssertEqual(event.usage.nonCachedInputTokens, 200)
        XCTAssertEqual(event.usage.outputTokens, 100)
        XCTAssertEqual(event.usage.reasoningOutputTokens, 20)
    }

    func testRejectsNonTokenEventAndEventOutsideToday() {
        let start = ISO8601DateFormatter().date(from: "2026-07-31T16:00:00Z")!
        let interval = DateInterval(start: start, duration: 86_400)
        let wrongType = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"message","info":{}}}"#
        let yesterday = #"{"timestamp":"2026-07-31T15:59:59Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":10}}}}"#

        XCTAssertNil(DailyTokenLogParser.parse(line: wrongType, inside: interval))
        XCTAssertNil(DailyTokenLogParser.parse(line: yesterday, inside: interval))
    }

    func testUsageAdditionDoesNotAddReasoningTwice() {
        let first = DailyTokenUsage(
            totalTokens: 1_100,
            cachedInputTokens: 800,
            nonCachedInputTokens: 200,
            outputTokens: 100,
            reasoningOutputTokens: 20,
            latestEventAt: Date(timeIntervalSince1970: 10)
        )
        let second = DailyTokenUsage(
            totalTokens: 550,
            cachedInputTokens: 300,
            nonCachedInputTokens: 200,
            outputTokens: 50,
            reasoningOutputTokens: 10,
            latestEventAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual((first + second).totalTokens, 1_650)
        XCTAssertEqual((first + second).outputTokens, 150)
        XCTAssertEqual((first + second).reasoningOutputTokens, 30)
    }

    func testCompactChineseFormatting() {
        XCTAssertEqual(TokenCountFormatter.compact(9_999), "9,999")
        XCTAssertEqual(TokenCountFormatter.compact(10_000), "1.0万")
        XCTAssertEqual(TokenCountFormatter.compact(7_986_313), "798.6万")
        XCTAssertEqual(TokenCountFormatter.compact(100_000_000), "1.0亿")
    }
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter DailyTokenUsageTests
```

Expected: compilation fails because `DailyTokenUsage`, `DailyTokenLogParser`, and `TokenCountFormatter` do not exist.

- [ ] **Step 3: Implement the token model and structured parser**

Create `Sources/CodexMeter/DailyTokenUsage.swift` with these public-to-module interfaces and arithmetic rules:

```swift
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
              interval.contains(timestamp),
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
```

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run:

```bash
swift test --filter DailyTokenUsageTests
```

Expected: 4 tests pass with 0 failures.

- [ ] **Step 5: Commit the domain model**

```bash
git add Sources/CodexMeter/DailyTokenUsage.swift Tests/CodexMeterTests/DailyTokenUsageTests.swift
git commit -m "feat: model daily token usage"
```

---

### Task 2: Incremental Daily Token File Provider

**Files:**
- Modify: `Sources/CodexMeter/DailyTokenUsage.swift`
- Modify: `Tests/CodexMeterTests/DailyTokenUsageTests.swift`

**Interfaces:**
- Consumes: `DailyTokenLogParser.parse(line:inside:)` and `DailyTokenUsage` from Task 1.
- Produces: `DailyTokenUsageProviding.currentUsage(now:) throws -> DailyTokenUsage` and `DailyTokenUsageProvider.init(roots:calendar:fileManager:)`.

- [ ] **Step 1: Add failing incremental, partial-line, rollover, and deduplication tests**

Append tests that create two temporary roots and use one fixed GMT+8 calendar:

```swift
func testProviderReadsOnlyNewCompleteLinesWithoutDoubleCounting() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("rollout-test.jsonl")
    let first = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":10,"reasoning_output_tokens":2,"total_tokens":110}}}}"#
    try (first + "\n").write(to: file, atomically: true, encoding: .utf8)
    let provider = DailyTokenUsageProvider(roots: [root], calendar: calendar)
    let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!

    XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 110)
    XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 110)

    let partial = #"{"timestamp":"2026-08-01T02:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":100,"output_tokens":20,"reasoning_output_tokens":4,"total_tokens":220}}}}"#
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(partial.prefix(partial.count / 2).utf8))
    try handle.close()
    XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 110)

    let finish = try FileHandle(forWritingTo: file)
    try finish.seekToEnd()
    try finish.write(contentsOf: Data((String(partial.suffix(partial.count - partial.count / 2)) + "\n").utf8))
    try finish.close()
    XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 330)
}

func testProviderResetsAtLocalMidnight() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("rollout-midnight.jsonl")
    let before = #"{"timestamp":"2026-07-31T15:59:59Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":90,"cached_input_tokens":80,"output_tokens":10,"total_tokens":100}}}}"#
    let after = #"{"timestamp":"2026-07-31T16:00:01Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":180,"cached_input_tokens":160,"output_tokens":20,"total_tokens":200}}}}"#
    try (before + "\n" + after + "\n").write(to: file, atomically: true, encoding: .utf8)
    let provider = DailyTokenUsageProvider(roots: [root], calendar: calendar)
    let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!

    XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 200)
}

func testProviderDeduplicatesSameRolloutFilenameAcrossRoots() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let active = base.appendingPathComponent("sessions")
    let archived = base.appendingPathComponent("archived")
    try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let line = #"{"timestamp":"2026-08-01T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":90,"cached_input_tokens":80,"output_tokens":10,"total_tokens":100}}}}"#
    try (line + "\n").write(to: active.appendingPathComponent("rollout-same.jsonl"), atomically: true, encoding: .utf8)
    try (line + "\n").write(to: archived.appendingPathComponent("rollout-same.jsonl"), atomically: true, encoding: .utf8)
    let provider = DailyTokenUsageProvider(roots: [active, archived], calendar: calendar)
    let now = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!

    XCTAssertEqual(try provider.currentUsage(now: now).totalTokens, 100)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter DailyTokenUsageTests
```

Expected: compilation fails because `DailyTokenUsageProvider` and `DailyTokenUsageProviding` do not exist.

- [ ] **Step 3: Implement per-rollout cursors and local-day rebuilding**

Append this interface and implement the named helpers in `DailyTokenUsage.swift`:

```swift
protocol DailyTokenUsageProviding: AnyObject, Sendable {
    func currentUsage(now: Date) throws -> DailyTokenUsage
}

final class DailyTokenUsageProvider: DailyTokenUsageProviding, @unchecked Sendable {
    private struct FileCursor {
        var url: URL
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
}
```

Implement the helpers with these exact behaviors:

- `discoverCandidateFiles(since:)` recursively enumerates regular `.jsonl` files whose modification date is at or after the local day start, sorts newest first, and returns one URL per `lastPathComponent` so active/archived copies are not both read.
- `updateCursor(for:interval:)` keys `cursors` by `lastPathComponent`, preserves a cursor when the same rollout moves to a new root, and resets that cursor when the current file size is smaller than its stored offset.
- Read from `offset` to EOF, prepend `partial`, split on byte `0x0A`, retain the final unterminated bytes, parse complete UTF-8 lines with `DailyTokenLogParser`, and replace the cursor in the dictionary.
- On a reset/truncation, set the cursor's offset, partial data, and per-file usage back to zero before rereading; do not add new data to an old aggregate.

Use this complete-line loop inside `updateCursor`:

```swift
var combined = cursor.partial
combined.append(newData)
let chunks = combined.split(separator: 0x0A, omittingEmptySubsequences: false)
let endsWithNewline = combined.last == 0x0A
let complete = endsWithNewline ? chunks.dropLast() : chunks.dropLast()
cursor.partial = endsWithNewline ? Data() : (chunks.last.map(Data.init) ?? Data())
for bytes in complete where !bytes.isEmpty {
    let line = String(decoding: bytes, as: UTF8.self)
    if let event = DailyTokenLogParser.parse(line: line, inside: interval) {
        cursor.usage = cursor.usage + event.usage
    }
}
cursor.offset = fileSize
```

- [ ] **Step 4: Run the focused and full test suites**

Run:

```bash
swift test --filter DailyTokenUsageTests
swift test
```

Expected: all daily-token tests and all existing quota tests pass.

- [ ] **Step 5: Commit the incremental provider**

```bash
git add Sources/CodexMeter/DailyTokenUsage.swift Tests/CodexMeterTests/DailyTokenUsageTests.swift
git commit -m "feat: aggregate today token usage"
```

---

### Task 3: Timestamped Quota Observations and Cross-Source Selection

**Files:**
- Modify: `Sources/CodexMeter/CodexMeterApp.swift:872-1255`
- Create: `Tests/CodexMeterTests/QuotaObservationSelectionTests.swift`
- Modify: `Tests/CodexMeterTests/CodexLogQuotaProviderTests.swift`
- Modify: `Tests/CodexMeterTests/CodexSessionQuotaProviderTests.swift`

**Interfaces:**
- Consumes: existing `RateLimitRecord`, `RateLimitWindow`, `RateLimitWindowSet`, and the two local quota sources.
- Produces: `ObservedRateLimitWindow`, `QuotaObservation`, `QuotaObservationProviding.currentWindowObservations()`, `CompositeQuotaProvider.currentObservation(now:)`, and `QuotaSnapshot.init(observation:)`.

- [ ] **Step 1: Write failing cross-source selection tests**

Create `Tests/CodexMeterTests/QuotaObservationSelectionTests.swift`:

```swift
import Foundation
import XCTest
@testable import CodexMeter

final class QuotaObservationSelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testNewerSourceWinsWhenResetWindowChanges() throws {
        let old = ObservedRateLimitWindow(
            window: RateLimitWindow(usedPercent: 80, resetsAt: 1_500, windowMinutes: 300),
            observedAt: Date(timeIntervalSince1970: 1_100),
            sourceName: "SQLite"
        )
        let fresh = ObservedRateLimitWindow(
            window: RateLimitWindow(usedPercent: 5, resetsAt: 2_000, windowMinutes: 300),
            observedAt: Date(timeIntervalSince1970: 1_200),
            sourceName: "JSONL"
        )

        let result = try XCTUnwrap(CompositeQuotaProvider.merge([old, fresh], now: now))

        XCTAssertEqual(result.windowSet.fiveHour?.usedPercent, 5)
        XCTAssertEqual(result.observedAt, fresh.observedAt)
    }

    func testHighestUsageWinsInsideSameResetWindow() throws {
        let olderHigh = ObservedRateLimitWindow(
            window: RateLimitWindow(usedPercent: 42, resetsAt: 2_000, windowMinutes: 300),
            observedAt: Date(timeIntervalSince1970: 1_100),
            sourceName: "SQLite"
        )
        let newerZero = ObservedRateLimitWindow(
            window: RateLimitWindow(usedPercent: 0, resetsAt: 2_000, windowMinutes: 300),
            observedAt: Date(timeIntervalSince1970: 1_200),
            sourceName: "JSONL"
        )

        let result = try XCTUnwrap(CompositeQuotaProvider.merge([olderHigh, newerZero], now: now))

        XCTAssertEqual(result.windowSet.fiveHour?.usedPercent, 42)
        XCTAssertEqual(result.observedAt, olderHigh.observedAt)
    }

    func testSnapshotUsesSourceObservationTime() throws {
        let observedAt = Date(timeIntervalSince1970: 1_200)
        let observation = try XCTUnwrap(CompositeQuotaProvider.merge([
            ObservedRateLimitWindow(
                window: RateLimitWindow(usedPercent: 39, resetsAt: 2_000, windowMinutes: 10_080),
                observedAt: observedAt,
                sourceName: "JSONL"
            )
        ], now: now))

        XCTAssertEqual(QuotaSnapshot(observation: observation).lastUpdated, observedAt)
    }
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter QuotaObservationSelectionTests
```

Expected: compilation fails because the observation types and merge function do not exist.

- [ ] **Step 3: Refactor quota providers to expose observed windows**

Replace the snapshot-returning protocol with:

```swift
struct ObservedRateLimitWindow: Sendable {
    let window: RateLimitWindow
    let observedAt: Date
    let sourceName: String
}

struct QuotaObservation: Sendable {
    let windowSet: RateLimitWindowSet
    let observedAt: Date
    let sourceName: String
}

protocol QuotaObservationProviding: Sendable {
    func currentWindowObservations() -> [ObservedRateLimitWindow]
}
```

Implement `CodexLogQuotaProvider.currentWindowObservations()` by mapping the newest valid header record's supported windows to `ObservedRateLimitWindow` with `record.sortDate` and source `Codex 日志`.

Refactor the selection body already present in `CodexSessionQuotaProvider.bestRateLimitRecord` into a helper that keeps each selected `(record, window)` pair. Use those pairs both to preserve the existing `bestRateLimitRecord` behavior and to implement `currentWindowObservations()` with accurate per-window observation times and source `Codex 会话`.

Implement the composite merge with this algorithm:

```swift
struct CompositeQuotaProvider: Sendable {
    private let providers: [any QuotaObservationProviding]

    init(providers: [any QuotaObservationProviding] = [
        CodexLogQuotaProvider(),
        CodexSessionQuotaProvider()
    ]) {
        self.providers = providers
    }

    func currentObservation(now: Date = Date()) -> QuotaObservation? {
        Self.merge(providers.flatMap { $0.currentWindowObservations() }, now: now)
    }

    static func merge(_ candidates: [ObservedRateLimitWindow], now: Date) -> QuotaObservation? {
        let supported = candidates.filter {
            $0.window.kind != nil && $0.window.resetsAt > now.timeIntervalSince1970
        }
        let selected = QuotaWindowKind.allCases.compactMap { kind -> ObservedRateLimitWindow? in
            let forKind = supported.filter { $0.window.kind == kind }
            guard let newest = forKind.max(by: { $0.observedAt < $1.observedAt }) else { return nil }
            return forKind
                .filter { $0.window.resetsAt == newest.window.resetsAt }
                .max {
                    if $0.window.usedPercent == $1.window.usedPercent {
                        return $0.observedAt < $1.observedAt
                    }
                    return $0.window.usedPercent < $1.window.usedPercent
                }
        }
        guard let newest = selected.max(by: { $0.observedAt < $1.observedAt }) else { return nil }
        let sourceNames = Set(selected.map(\.sourceName))
        return QuotaObservation(
            windowSet: RateLimitWindowSet(windows: selected.map(\.window), now: now),
            observedAt: newest.observedAt,
            sourceName: sourceNames.count == 1 ? newest.sourceName : "本机日志"
        )
    }
}
```

Make `QuotaWindowKind` conform to `CaseIterable`, make `QuotaSnapshot` conform to `Sendable`, and add `QuotaSnapshot.init(observation:)` that passes `observation.observedAt` to the existing initializer.

- [ ] **Step 4: Update provider tests for the new interfaces**

Change provider-level assertions from `provider.currentSnapshot()` to observations plus a constructed snapshot:

```swift
let observation = CompositeQuotaProvider.merge(
    CodexLogQuotaProvider(databaseURL: databaseURL).currentWindowObservations(),
    now: now
)
let snapshot = observation.map(QuotaSnapshot.init(observation:))
XCTAssertEqual(snapshot?.remainingPercent, 65)
```

Keep all existing partial-window, model-specific-limit, and large-SQLite-output test cases.

- [ ] **Step 5: Run focused and full tests**

Run:

```bash
swift test --filter QuotaObservationSelectionTests
swift test --filter CodexLogQuotaProviderTests
swift test --filter CodexSessionQuotaProviderTests
swift test
```

Expected: all tests pass; weekly-only behavior remains unchanged.

- [ ] **Step 6: Commit quota observation selection**

```bash
git add Sources/CodexMeter/CodexMeterApp.swift Tests/CodexMeterTests/QuotaObservationSelectionTests.swift Tests/CodexMeterTests/CodexLogQuotaProviderTests.swift Tests/CodexMeterTests/CodexSessionQuotaProviderTests.swift
git commit -m "fix: select freshest local quota observations"
```

---

### Task 4: Native Codex Activity Watcher

**Files:**
- Create: `Sources/CodexMeter/CodexActivityWatcher.swift`
- Create: `Tests/CodexMeterTests/CodexActivityWatcherTests.swift`

**Interfaces:**
- Consumes: local Codex root/session paths and a callback supplied by `UsageStore` in Task 5.
- Produces: `CodexActivityWatching`, `CodexActivityPaths`, and `CodexActivityWatcher.start()`, `rebind()`, and `stop()`.

- [ ] **Step 1: Write a failing watcher integration test**

Create `Tests/CodexMeterTests/CodexActivityWatcherTests.swift`:

```swift
import Foundation
import XCTest
@testable import CodexMeter

final class CodexActivityWatcherTests: XCTestCase {
    func testAppendToSessionFileEmitsChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions/2026/08/01")
        let archived = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("rollout-watch.jsonl")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let fixedNow = ISO8601DateFormatter().date(from: "2026-08-01T03:00:00Z")!
        let changed = expectation(description: "watcher emitted change")
        changed.assertForOverFulfill = false
        let watcher = CodexActivityWatcher(
            paths: CodexActivityPaths(codexRoot: root, sessionsRoot: root.appendingPathComponent("sessions"), archivedSessionsRoot: archived),
            calendar: calendar,
            now: { fixedNow },
            onChange: { changed.fulfill() }
        )
        watcher.start()

        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()

        wait(for: [changed], timeout: 3)
        watcher.stop()
    }
}
```

- [ ] **Step 2: Run the watcher test and verify RED**

Run:

```bash
swift test --filter CodexActivityWatcherTests
```

Expected: compilation fails because the watcher types do not exist.

- [ ] **Step 3: Implement native file and directory bindings**

Create `Sources/CodexMeter/CodexActivityWatcher.swift` with this API:

```swift
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
    private let now: () -> Date
    private let onChange: () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var descriptors: [Int32] = []

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
    }

    func start() { queue.sync { bindAll() } }
    func rebind() { queue.async { [weak self] in self?.bindAll() } }
    func stop() { queue.sync { tearDown() } }
}
```

Implement `bindAll()` to tear down old sources, use the injected `now()` plus `calendar` to discover the existing current-day session directory chain and active `.jsonl` files, then watch:

- the Codex root;
- `logs_2.sqlite-wal` if it exists;
- the sessions root and each existing year/month/day component for today;
- each `.jsonl` file in today's session directory;
- the archived sessions root.

Use `open(path, O_EVTONLY)`, `DispatchSource.makeFileSystemObjectSource`, and event mask `[.write, .extend, .rename, .delete, .revoke]`. The event handler calls `onChange()`. For rename/delete/revoke or a directory write, schedule `bindAll()` again on the watcher queue after the current handler returns. The cancel handler closes its matching descriptor exactly once. `tearDown()` cancels all sources and clears both arrays.

- [ ] **Step 4: Run the watcher and full tests**

Run:

```bash
swift test --filter CodexActivityWatcherTests
swift test
```

Expected: watcher test passes within 3 seconds and all existing tests remain green.

- [ ] **Step 5: Commit the watcher**

```bash
git add Sources/CodexMeter/CodexActivityWatcher.swift Tests/CodexMeterTests/CodexActivityWatcherTests.swift
git commit -m "feat: watch local Codex activity"
```

---

### Task 5: Atomic Usage Snapshot and Serialized Refresh Store

**Files:**
- Modify: `Sources/CodexMeter/CodexMeterApp.swift:28-178`
- Modify: `Sources/CodexMeter/CodexMeterApp.swift:529-862`
- Create: `Tests/CodexMeterTests/UsageStoreTests.swift`

**Interfaces:**
- Consumes: `CompositeQuotaProvider.currentObservation(now:)`, `DailyTokenUsageProviding`, and `CodexActivityWatching`.
- Produces: `UsageSnapshot`, `UsageFreshness`, `UsageLoadResult`, `UsageLoading`, `LocalUsageLoader`, and `UsageStore`.

- [ ] **Step 1: Write failing store coordination tests**

Create `Tests/CodexMeterTests/UsageStoreTests.swift` with a locked loader that can delay completion:

```swift
import Foundation
import XCTest
@testable import CodexMeter

@MainActor
final class UsageStoreTests: XCTestCase {
    func testRefreshRequestedDuringLoadRunsOneFollowUp() async throws {
        let loader = BlockingUsageLoader()
        let store = UsageStore(loader: loader, watcher: nil, debounceInterval: 0.01)
        store.refresh()
        await loader.waitUntilStarted()
        store.refresh()
        store.refresh()
        loader.release()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(loader.callCount, 2)
    }

    func testFailedQuotaReadKeepsPreviousValueAndMarksStale() async throws {
        let quota = QuotaSnapshot(
            record: RateLimitRecord(
                timestamp: Date(timeIntervalSince1970: 1_000),
                fileModifiedAt: Date(timeIntervalSince1970: 1_000),
                windowSet: RateLimitWindowSet(windows: [
                    RateLimitWindow(usedPercent: 39, resetsAt: 4_102_444_800, windowMinutes: 10_080)
                ], now: Date(timeIntervalSince1970: 1_000))
            ),
            sourceName: "测试",
            lastUpdated: Date(timeIntervalSince1970: 1_000)
        )
        let loader = SequenceUsageLoader(results: [
            UsageLoadResult(quota: quota, dailyTokens: .zero),
            UsageLoadResult(quota: nil, dailyTokens: nil)
        ])
        let store = UsageStore(loader: loader, watcher: nil, debounceInterval: 0.01)
        store.refresh()
        try await Task.sleep(for: .milliseconds(80))
        store.refresh()
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(store.snapshot.quota.remainingPercent, 61)
        XCTAssertEqual(store.snapshot.freshness, .stale)
    }

    func testWatcherBurstDebouncesToOneLoad() async throws {
        let loader = CountingUsageLoader(result: .empty)
        let store = UsageStore(loader: loader, watcher: nil, debounceInterval: 0.02)

        store.scheduleRefresh()
        store.scheduleRefresh()
        store.scheduleRefresh()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(loader.callCount, 1)
    }

    func testWakeRebindsWatcherAndRefreshesImmediately() async throws {
        let loader = CountingUsageLoader(result: .empty)
        let watcher = SpyActivityWatcher()
        let store = UsageStore(loader: loader, watcher: watcher, debounceInterval: 0.8)

        store.refreshAfterWakeOrUnlock()
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(watcher.rebindCount, 1)
        XCTAssertEqual(loader.callCount, 1)
    }
}
```

Define the thread-safe loader fakes in the same test file:

```swift
final class BlockingUsageLoader: UsageLoading, @unchecked Sendable {
    private let condition = NSCondition()
    private var calls = 0
    private var started = false
    private var released = false
    private var startedContinuation: CheckedContinuation<Void, Never>?

    var callCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return calls
    }

    func load(now: Date) -> UsageLoadResult {
        condition.lock()
        calls += 1
        if !started {
            started = true
            let continuation = startedContinuation
            startedContinuation = nil
            condition.unlock()
            continuation?.resume()
            condition.lock()
        }
        while !released {
            condition.wait()
        }
        condition.unlock()
        return .empty
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if started {
                condition.unlock()
                continuation.resume()
            } else {
                startedContinuation = continuation
                condition.unlock()
            }
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

final class SequenceUsageLoader: UsageLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [UsageLoadResult]

    init(results: [UsageLoadResult]) {
        self.results = results
    }

    func load(now: Date) -> UsageLoadResult {
        lock.lock()
        defer { lock.unlock() }
        return results.isEmpty ? .empty : results.removeFirst()
    }
}

final class CountingUsageLoader: UsageLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let result: UsageLoadResult

    init(result: UsageLoadResult) {
        self.result = result
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func load(now: Date) -> UsageLoadResult {
        lock.lock()
        calls += 1
        lock.unlock()
        return result
    }
}

final class SpyActivityWatcher: CodexActivityWatching {
    private(set) var startCount = 0
    private(set) var rebindCount = 0
    private(set) var stopCount = 0

    func start() { startCount += 1 }
    func rebind() { rebindCount += 1 }
    func stop() { stopCount += 1 }
}
```

- [ ] **Step 2: Run the store tests and verify RED**

Run:

```bash
swift test --filter UsageStoreTests
```

Expected: compilation fails because the usage snapshot/store interfaces do not exist.

- [ ] **Step 3: Add atomic usage and loader types**

Add these types near the existing store:

```swift
enum UsageFreshness: Equatable, Sendable {
    case live
    case stale
    case unavailable
}

struct UsageSnapshot: Sendable {
    let quota: QuotaSnapshot
    let dailyTokens: DailyTokenUsage
    let freshness: UsageFreshness

    static let unavailable = UsageSnapshot(
        quota: .unavailable(),
        dailyTokens: .zero,
        freshness: .unavailable
    )
}

struct UsageLoadResult: Sendable {
    let quota: QuotaSnapshot?
    let dailyTokens: DailyTokenUsage?
    static let empty = UsageLoadResult(quota: nil, dailyTokens: nil)
}

protocol UsageLoading: Sendable {
    func load(now: Date) -> UsageLoadResult
}

final class LocalUsageLoader: UsageLoading, @unchecked Sendable {
    private let quotaProvider: CompositeQuotaProvider
    private let tokenProvider: any DailyTokenUsageProviding

    init(
        quotaProvider: CompositeQuotaProvider = CompositeQuotaProvider(),
        tokenProvider: any DailyTokenUsageProviding = DailyTokenUsageProvider()
    ) {
        self.quotaProvider = quotaProvider
        self.tokenProvider = tokenProvider
    }

    func load(now: Date) -> UsageLoadResult {
        let quota = quotaProvider.currentObservation(now: now).map(QuotaSnapshot.init(observation:))
        let tokens = try? tokenProvider.currentUsage(now: now)
        return UsageLoadResult(quota: quota, dailyTokens: tokens)
    }
}
```

- [ ] **Step 4: Replace `QuotaStore` with serialized `UsageStore`**

Rename the existing `QuotaStore` to `UsageStore`, change `snapshot` to `UsageSnapshot`, and inject:

```swift
private let loader: any UsageLoading
private var watcher: CodexActivityWatching?
private let debounceInterval: TimeInterval
private let fallbackInterval: TimeInterval
private var debounceTimer: Timer?
private var refreshPending = false
```

Use this initializer shape:

```swift
init(
    loader: any UsageLoading = LocalUsageLoader(),
    watcher: CodexActivityWatching? = nil,
    debounceInterval: TimeInterval = 0.8,
    fallbackInterval: TimeInterval = 60
) {
    self.loader = loader
    self.watcher = watcher
    self.debounceInterval = debounceInterval
    self.fallbackInterval = fallbackInterval
    let cachedQuota = QuotaSnapshot.cached() ?? .unavailable()
    self.snapshot = UsageSnapshot(
        quota: cachedQuota,
        dailyTokens: .zero,
        freshness: cachedQuota.isUnavailable ? .unavailable : .stale
    )
    let savedInterval = UserDefaults.standard.integer(forKey: CacheKey.voiceBroadcastIntervalMinutes)
    self.voiceBroadcastIntervalMinutes = Self.allowedVoiceBroadcastIntervals.contains(savedInterval) ? savedInterval : 1
}
```

When `start()` is called and no watcher was injected, create `CodexActivityWatcher { [weak self] in DispatchQueue.main.async { self?.scheduleRefresh() } }`, start it, perform an immediate refresh, and schedule the fallback timer with `fallbackInterval` (60 seconds in production). Add `stop()` to invalidate timers and stop the watcher; call it from `applicationWillTerminate`.

Add `refreshAfterWakeOrUnlock()` to call `watcher?.rebind()` followed by immediate `refresh()`. Change `AppDelegate.refreshAfterSleepOrUnlock` to call this method so wake/unlock never waits for the debounce or fallback timer.

Implement coordination exactly as follows:

```swift
func scheduleRefresh() {
    debounceTimer?.invalidate()
    debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
        Task { @MainActor in self?.refresh() }
    }
}

func refresh() {
    guard !isRefreshing else {
        refreshPending = true
        return
    }
    isRefreshing = true
    let loader = loader
    refreshQueue.async { [weak self] in
        let result = loader.load(now: Date())
        DispatchQueue.main.async {
            guard let self else { return }
            let old = self.snapshot
            let quota = result.quota ?? old.quota
            let tokens = result.dailyTokens ?? old.dailyTokens
            let hasFreshQuota = result.quota != nil
            let hasFreshTokens = result.dailyTokens != nil
            self.snapshot = UsageSnapshot(
                quota: quota,
                dailyTokens: tokens,
                freshness: hasFreshQuota && hasFreshTokens ? .live : (quota.isUnavailable ? .unavailable : .stale)
            )
            if let freshQuota = result.quota { freshQuota.cache() }
            self.isRefreshing = false
            self.finishRefreshSideEffects()
            if self.refreshPending {
                self.refreshPending = false
                self.refresh()
            }
        }
    }
}
```

Move the existing notification and optional speech work into `finishRefreshSideEffects()`, always passing `snapshot.quota`. Update every existing `store.snapshot` quota reference to `store.snapshot.quota` until the UI task adds token references.

- [ ] **Step 5: Run store and full tests**

Run:

```bash
swift test --filter UsageStoreTests
swift test
```

Expected: both store tests and the complete suite pass; no concurrent refresh is dropped.

- [ ] **Step 6: Commit the coordinated store**

```bash
git add Sources/CodexMeter/CodexMeterApp.swift Tests/CodexMeterTests/UsageStoreTests.swift
git commit -m "feat: coordinate atomic usage refreshes"
```

---

### Task 6: Token Composition Card and Progress Bar

**Files:**
- Modify: `Sources/CodexMeter/CodexMeterApp.swift:18-26`
- Modify: `Sources/CodexMeter/CodexMeterApp.swift:28-321`
- Modify: `Tests/CodexMeterTests/DailyTokenUsageTests.swift`

**Interfaces:**
- Consumes: `UsageSnapshot.dailyTokens`, `DailyTokenUsage` fractions, and `TokenCountFormatter`.
- Produces: `DailyTokenUsageCard`, `TokenCompositionBar`, and the final expanded popover layout.

- [ ] **Step 1: Add failing display-model assertions**

Append:

```swift
func testCompositionFractionsUseTotalWithoutReasoningDuplication() {
    let usage = DailyTokenUsage(
        totalTokens: 1_000,
        cachedInputTokens: 700,
        nonCachedInputTokens: 200,
        outputTokens: 100,
        reasoningOutputTokens: 40,
        latestEventAt: nil
    )

    XCTAssertEqual(usage.cachedFraction, 0.7, accuracy: 0.0001)
    XCTAssertEqual(usage.nonCachedFraction, 0.2, accuracy: 0.0001)
    XCTAssertEqual(usage.outputFraction, 0.1, accuracy: 0.0001)
    XCTAssertEqual(usage.cachedFraction + usage.nonCachedFraction + usage.outputFraction, 1, accuracy: 0.0001)
}
```

- [ ] **Step 2: Run the focused test**

Run:

```bash
swift test --filter DailyTokenUsageTests/testCompositionFractionsUseTotalWithoutReasoningDuplication
```

Expected: PASS if Task 1 arithmetic is correct; if it fails, fix the fractions before adding UI.

- [ ] **Step 3: Expand the popover and add the token card**

Change `PanelMetrics.cardHeight` from `220` to `340`. In `StatusPanelView`, render `dailyTokenOverview` after `quotaOverview` with the existing 12-point outer spacing.

Add:

```swift
private var dailyTokenOverview: some View {
    DailyTokenUsageCard(usage: store.snapshot.dailyTokens)
        .padding(14)
        .notificationInsetSurface(cornerRadius: 12)
}
```

Create the views with these exact labels and colors:

```swift
struct DailyTokenUsageCard: View {
    let usage: DailyTokenUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日 Token").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(usage.totalTokens == 0 ? "今日暂无使用" : TokenCountFormatter.compact(usage.totalTokens))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            TokenCompositionBar(usage: usage)
            HStack(spacing: 12) {
                TokenMetric(label: "缓存", value: usage.cachedInputTokens, color: .cyan)
                TokenMetric(label: "非缓存", value: usage.nonCachedInputTokens, color: .purple)
                TokenMetric(label: "输出", value: usage.outputTokens, color: .orange)
            }
            Text("推理 \(TokenCountFormatter.compact(usage.reasoningOutputTokens))（已包含在输出中）")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
```

Implement `TokenCompositionBar` with a `GeometryReader`, a zero-spacing `HStack`, and three rectangles whose widths are `geometry.size.width * cachedFraction`, `* nonCachedFraction`, and `* outputFraction`. Use light blue, purple, and orange respectively, set height to 7 points, and clip the stack with `Capsule()`. When total is zero, render the same capsule filled with `Color.secondary.opacity(0.15)`.

Implement `TokenMetric` as a compact colored dot, 10-point label, and `TokenCountFormatter.compact(value)` in monospaced digits. Do not impose a fake minimum segment width; the numeric metrics remain authoritative for small fractions.

Update the header to use `store.snapshot.quota.sourceName` and quota source time. When `store.snapshot.freshness == .stale`, append ` · 暂未更新` and use secondary/orange styling; when unavailable, preserve the existing red state.

- [ ] **Step 4: Keep menu-bar and voice behavior quota-only**

In `AppDelegate.updateStatusItem`, bind `let quota = snapshot.quota` and preserve the existing title expression:

```swift
let title = quota.isUnavailable ? "未同步" : "\(quota.percentText) | \(quota.shortResetText)"
```

Do not add token text to the status item, tooltip, low-quota notification, or voice broadcast.

- [ ] **Step 5: Run tests and build the app**

Run:

```bash
swift test
./scripts/build-app.sh
plutil -lint "build/Codex Meter.app/Contents/Info.plist"
```

Expected: all tests pass, the release build succeeds, and `Info.plist` reports `OK`.

- [ ] **Step 6: Commit the token UI**

```bash
git add Sources/CodexMeter/CodexMeterApp.swift Tests/CodexMeterTests/DailyTokenUsageTests.swift
git commit -m "feat: show today's token composition"
```

---

### Task 7: Documentation, Live Validation, and Stable App Replacement

**Files:**
- Modify: `README.md:11-19`
- Modify: `README.md:73-90`
- Verify: `build/Codex Meter.app`
- Replace installed bundle: `/Users/cc/Applications/Codex Meter.app`

**Interfaces:**
- Consumes: the complete implementation from Tasks 1-6.
- Produces: documented behavior, a passing release build, and the installed menu-bar app running from its stable path.

- [ ] **Step 1: Document the new behavior and privacy boundary**

Update the feature list to include:

```markdown
- Codex 写入本机日志后通常在 1–3 秒内刷新，60 秒轮询作为兜底
- 在弹出面板中查看今日 Token 总量、缓存输入、非缓存输入、输出和推理明细
- 用组成进度条查看缓存、非缓存和输出的比例
```

Update “数据从哪里来” to state that quota uses structured rate-limit records and today's token usage reads only `payload.type == "token_count"` plus `payload.info.last_token_usage`. Explicitly retain the statement that conversation content and credentials are not read or uploaded.

- [ ] **Step 2: Run the complete verification suite**

Run:

```bash
swift test
./scripts/build-app.sh
plutil -lint "build/Codex Meter.app/Contents/Info.plist"
```

Expected: all tests pass, build exits 0, and `Info.plist` is valid.

- [ ] **Step 3: Verify the real current-day token total independently**

Calculate a read-only reference total from today's local session directory:

```bash
jq -s '[.[] | select(.payload.type == "token_count") | .payload.info.last_token_usage] | {total:(map(.total_tokens // 0)|add // 0),cached:(map(.cached_input_tokens // 0)|add // 0),input:(map(.input_tokens // 0)|add // 0),output:(map(.output_tokens // 0)|add // 0),reasoning:(map(.reasoning_output_tokens // 0)|add // 0)}' /Users/cc/.codex/sessions/$(date +%Y/%m/%d)/*.jsonl
```

Expected: the app's total equals `total`; cached equals `cached`; non-cached equals `input - cached`; output and reasoning match their fields. If a session has moved to archived sessions, include that file once rather than counting both roots.

- [ ] **Step 4: Replace and restart the stable installed application**

After obtaining the required filesystem/GUI approval, run:

```bash
ditto "build/Codex Meter.app" "/Users/cc/Applications/Codex Meter.app"
pkill -x CodexMeter
open -n "/Users/cc/Applications/Codex Meter.app"
```

Expected: the running executable path is `/Users/cc/Applications/Codex Meter.app/Contents/MacOS/CodexMeter`; the existing macOS Login Item continues to point at the stable bundle.

- [ ] **Step 5: Perform visual and latency validation**

Use Computer Use to open the menu-bar panel and verify:

- menu-bar text still has the compact quota-only form;
- the quota progress bar remains visible;
- the token card shows today's total and four numeric details;
- the composition bar contains cached/non-cached/output colors;
- reasoning is labeled as included in output;
- the panel fits on screen without clipped content.

Trigger one normal Codex response, note the source record time, and verify the panel updates within 1-3 seconds. Also verify manual refresh, sleep/wake refresh, and the 60-second fallback remain available.

- [ ] **Step 6: Commit documentation**

```bash
git add README.md
git commit -m "docs: describe realtime usage metrics"
```

- [ ] **Step 7: Final repository check**

Run:

```bash
git status --short --branch
git log --oneline --decorate -10
```

Expected: the feature branch is clean and contains separate commits for the token model, token provider, quota selection, watcher, refresh store, UI, and documentation.
