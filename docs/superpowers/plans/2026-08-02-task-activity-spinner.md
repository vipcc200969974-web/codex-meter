# Task Activity Spinner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a text-height activity ring after the reset-time divider that rotates while any local ChatGPT/Codex task is running and remains visible but still when all tasks stop.

**Architecture:** A focused `CodexTaskActivityProvider` incrementally parses only structured `task_started` and `task_complete` lifecycle records from local session JSONL files and persists privacy-safe cursors. `LocalUsageLoader` and `UsageStore` publish the independent Boolean state using the existing 800 ms watcher path and 60-second fallback. `CompactStatusItemView` draws the divider and 12.5-point ring and owns a low-frequency timer only while active.

**Tech Stack:** Swift 6, AppKit, Combine, Foundation JSON decoding and file APIs, XCTest, macOS 14+

## Global Constraints

- Keep the existing quota/reset text unchanged and render one clickable tag: `64% | 6d0h | ◌`.
- Divider spacing is exactly 5 points on both sides; divider height is 9 points at 35% foreground opacity.
- Ring diameter is exactly 12.5 points with a 1.5-point rounded stroke and 6 points trailing padding.
- Active animation is 12 frames per second and one revolution per second; idle launch is top-facing and completion freezes the current angle.
- Any non-stale local turn makes the global state active; stale means older than exactly 24 hours.
- Cold scanning is capped at 64 MiB per file and 256 MiB in aggregate; cap or traversal failure never publishes partial activity.
- Reuse the existing 800 ms filesystem debounce and 60-second fallback. Do not add polling intervals or a second watcher.
- Decode only top-level event type plus lifecycle type, `turn_id`, and lifecycle timestamp. Do not decode, retain, display, or upload prompts, replies, reasoning, tool arguments, authentication data, raw lines, or partial lines.
- Add no dependency and no network request. Do not change quota, token, panel, notification, or login-item behavior.
- Use TDD for every production behavior: focused RED, minimal GREEN, focused verification, full verification, then commit.

## File Structure

- Create `Sources/CodexMeter/CodexTaskActivity.swift`: lifecycle model/parser, file discovery, incremental cursors, scan bounds, cache, and provider protocol.
- Create `Tests/CodexMeterTests/CodexTaskActivityTests.swift`: parser, provider, cursor, cache, privacy, scan-limit, and failure tests.
- Modify `Sources/CodexMeter/CodexMeterApp.swift`: loader/store activity publication, app-delegate binding, status-item layout, drawing, timer, tooltip, and accessibility.
- Modify `Tests/CodexMeterTests/UsageStoreTests.swift`: state publication, failure grace, debounce, fallback, and stale-expiry integration.
- Create `Tests/CodexMeterTests/CompactStatusItemViewTests.swift`: exact geometry and animation lifecycle tests.
- Modify `README.md`: document the task indicator, lifecycle fields, local-only privacy boundary, and idle/active behavior.

---

### Task 1: Structured Lifecycle Parser

**Files:**
- Create: `Sources/CodexMeter/CodexTaskActivity.swift`
- Create: `Tests/CodexMeterTests/CodexTaskActivityTests.swift`

**Interfaces:**
- Produces: `CodexTaskLifecycleKind`, `CodexTaskLifecycleEvent`, `JSONCodexTaskLifecycleDecoder`, and `CodexTaskLifecycleParser`.
- Consumes: `CachedDailyTokenTimestampParser` from `Sources/CodexMeter/DailyTokenUsage.swift` through the existing `DailyTokenTimestampParsing` protocol.

- [ ] **Step 1: Write failing lifecycle parser tests**

Add real JSONL tests that assert exact structured behavior:

```swift
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
}
```

Add a counting decoder seam and a large private payload test proving the raw discriminator rejects non-lifecycle records before typed decoding.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter CodexTaskActivityTests
```

Expected: compilation fails because `CodexTaskLifecycleParser` and lifecycle types do not exist.

- [ ] **Step 3: Implement the minimal narrow parser**

Define exact public-to-module interfaces:

```swift
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
    static func parse(line: String) -> CodexTaskLifecycleEvent?
    static func parseCompleteLines(in data: Data) -> [CodexTaskLifecycleEvent]
}
```

The raw discriminator must require both `event_msg` and either lifecycle marker before invoking `JSONDecoder`. The typed envelope contains only `timestamp`, top-level `type`, `payload.type`, and `payload.turn_id`. Validate a non-empty turn ID and a parseable top-level timestamp.

- [ ] **Step 4: Run parser tests and verify GREEN**

Run `swift test --filter CodexTaskActivityTests`.

Expected: parser and privacy tests pass; unrelated private payloads record zero typed decoder calls.

- [ ] **Step 5: Commit the parser**

```bash
git add Sources/CodexMeter/CodexTaskActivity.swift Tests/CodexMeterTests/CodexTaskActivityTests.swift
git commit -m "feat: parse local task lifecycle events"
```

---

### Task 2: Incremental Global Activity Provider

**Files:**
- Modify: `Sources/CodexMeter/CodexTaskActivity.swift`
- Modify: `Tests/CodexMeterTests/CodexTaskActivityTests.swift`

**Interfaces:**
- Consumes: `CodexTaskLifecycleParser.parseCompleteLines(in:)` from Task 1.
- Produces: `CodexTaskActivityProviding.currentActivity(now:) throws -> Bool` and production `CodexTaskActivityProvider`.

- [ ] **Step 1: Write failing global-state tests**

Add helpers that write lifecycle lines into temporary active and archived roots, then add these tests:

```swift
func testAnyUncompletedTurnMakesGlobalActivityActive() throws {
    try writeLifecycle(.started, turnID: "a", to: activeFile, at: now.addingTimeInterval(-10))
    try writeLifecycle(.started, turnID: "b", to: otherFile, at: now.addingTimeInterval(-9))
    try appendLifecycle(.completed, turnID: "a", to: activeFile, at: now.addingTimeInterval(-5))

    XCTAssertTrue(try makeProvider().currentActivity(now: now))

    try appendLifecycle(.completed, turnID: "b", to: otherFile, at: now)
    XCTAssertFalse(try makeProvider().currentActivity(now: now))
}

func testCompletionForDifferentTurnDoesNotStopActiveTurn() throws {
    try writeLifecycle(.started, turnID: "a", to: activeFile, at: now.addingTimeInterval(-10))
    try appendLifecycle(.completed, turnID: "b", to: activeFile, at: now.addingTimeInterval(-5))
    XCTAssertTrue(try makeProvider().currentActivity(now: now))
}

func testTwentyFourHourBoundaryIsActiveButOlderStartIsStale() throws {
    try writeLifecycle(.started, turnID: "boundary", to: activeFile, at: now.addingTimeInterval(-86_400))
    XCTAssertTrue(try makeProvider().currentActivity(now: now))

    try writeLifecycle(.started, turnID: "stale", to: otherFile, at: now.addingTimeInterval(-86_401))
    XCTAssertFalse(try makeProvider(roots: [otherFile.deletingLastPathComponent()]).currentActivity(now: now))
}
```

Add mutation-sensitive tests for append-without-double-counting, partial-line completion, truncation, larger replacement, same-identity move, active/archive copy deduplication, restart cache hit without rereading unchanged bytes, corrupt cache rebuild, serialized-cache privacy sentinel absence, missing roots, unreadable traversal, 64 MiB/file refusal, and 256 MiB aggregate refusal.

- [ ] **Step 2: Run focused provider tests and verify RED**

Run `swift test --filter CodexTaskActivityTests`.

Expected: tests fail because `CodexTaskActivityProviding` and provider cursor behavior are absent.

- [ ] **Step 3: Implement bounded discovery, cursors, and cache**

Add the exact module interface:

```swift
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
    init(
        roots: [URL]? = nil,
        fileManager: FileManager = .default,
        cacheURL: URL? = nil,
        maxBytesPerFile: UInt64 = 64 * 1_024 * 1_024,
        maxTotalBytes: UInt64 = 256 * 1_024 * 1_024
    )

    func currentActivity(now: Date) throws -> Bool
}
```

Use one locked state transition per refresh. Discover only `.jsonl` candidates modified at or after `now - 86_400`; missing roots are empty, while existing-root traversal and candidate metadata errors throw. Key cursors by device/inode identity with basename fallback, preserve cursors across active-to-archive moves, prune disappeared keys, and rebuild on identity change, truncation, impossible offset, or non-newline cached boundary.

Persist schema version, root fingerprint, cache save timestamp, file identity, path/basename, complete-line offset, and per-file active turn IDs with their start timestamps. Apply complete appended events in file order. Completion removes only the matching ID. Remove starts whose timestamp is `< now - 86_400`; the exact 24-hour boundary remains active. Validate every cached offset and aggregate before trusting it; write the cache atomically and never persist partial data or raw input.

- [ ] **Step 4: Run focused provider tests and verify GREEN**

Run `swift test --filter CodexTaskActivityTests`.

Expected: all parser/provider/cache/privacy/failure tests pass.

- [ ] **Step 5: Commit the provider**

```bash
git add Sources/CodexMeter/CodexTaskActivity.swift Tests/CodexMeterTests/CodexTaskActivityTests.swift
git commit -m "feat: track active Codex tasks incrementally"
```

---

### Task 3: Usage Loader and Store Integration

**Files:**
- Modify: `Sources/CodexMeter/CodexMeterApp.swift:839-1185`
- Modify: `Tests/CodexMeterTests/UsageStoreTests.swift`

**Interfaces:**
- Consumes: `CodexTaskActivityProviding.currentActivity(now:) throws -> Bool` from Task 2.
- Produces: `UsageLoadResult.isTaskActive: Bool?` and `UsageStore.$isTaskActive` for Task 4.

- [ ] **Step 1: Write failing loader/store state tests**

Extend sequence loaders to return optional activity state and add:

```swift
func testSuccessfulActivityLoadPublishesIndependentState() async {
    let loader = SequenceUsageLoader(results: [
        UsageLoadResult(quota: nil, dailyTokens: nil, isTaskActive: true),
        UsageLoadResult(quota: nil, dailyTokens: nil, isTaskActive: false)
    ])
    let store = UsageStore(loader: loader, watcher: SpyActivityWatcher())

    await nextTaskActivity(from: store) { store.refresh() }
    XCTAssertTrue(store.isTaskActive)
    await nextTaskActivity(from: store) { store.refresh() }
    XCTAssertFalse(store.isTaskActive)
}

func testActivityFailureRetainsForSixtySecondsThenFailsIdle() async {
    let start = Date(timeIntervalSince1970: 1_000)
    let clock = LockedDateSource(start)
    let loader = SequenceUsageLoader(results: [
        UsageLoadResult(quota: nil, dailyTokens: nil, isTaskActive: true),
        UsageLoadResult(quota: nil, dailyTokens: nil, isTaskActive: nil),
        UsageLoadResult(quota: nil, dailyTokens: nil, isTaskActive: nil)
    ])
    let store = UsageStore(loader: loader, watcher: SpyActivityWatcher(), now: clock.now)

    await nextTaskActivity(from: store) { store.refresh() }
    clock.set(start.addingTimeInterval(59.999))
    await nextSnapshot(from: store) { store.refresh() }
    XCTAssertTrue(store.isTaskActive)
    clock.set(start.addingTimeInterval(60))
    await nextTaskActivity(from: store) { store.refresh() }
    XCTAssertFalse(store.isTaskActive)
}

func testActivityFailureDoesNotChangeQuotaTokenFreshness() async {
    let loader = SequenceUsageLoader(results: [
        UsageLoadResult(
            quota: makeQuota(remainingPercent: 70, sourceName: "fresh"),
            dailyTokens: makeTokens(total: 42),
            isTaskActive: nil
        )
    ])
    let store = UsageStore(loader: loader, watcher: SpyActivityWatcher())
    let snapshot = await nextSnapshot(from: store) { store.refresh() }
    XCTAssertEqual(snapshot.freshness, .live)
    XCTAssertFalse(store.isTaskActive)
}
```

Retain and rerun the existing exact 800 ms debounce and 60-second fallback tests, with results that prove the same refresh carries activity state.

- [ ] **Step 2: Run focused store tests and verify RED**

Run `swift test --filter UsageStoreTests`.

Expected: compilation fails because the activity result and published store property are absent.

- [ ] **Step 3: Implement loader and independent state publication**

Change result and loader APIs exactly:

```swift
struct UsageLoadResult: Sendable {
    let quota: QuotaSnapshot?
    let dailyTokens: DailyTokenUsage?
    let isTaskActive: Bool?

    init(
        quota: QuotaSnapshot?,
        dailyTokens: DailyTokenUsage?,
        isTaskActive: Bool? = nil
    ) {
        self.quota = quota
        self.dailyTokens = dailyTokens
        self.isTaskActive = isTaskActive
    }
}

final class LocalUsageLoader: UsageLoading, @unchecked Sendable {
    init(
        quotaProvider: CompositeQuotaProvider = CompositeQuotaProvider(),
        tokenProvider: any DailyTokenUsageProviding = DailyTokenUsageProvider(),
        taskActivityProvider: any CodexTaskActivityProviding = CodexTaskActivityProvider()
    )
}

@MainActor final class UsageStore: ObservableObject {
    @Published private(set) var isTaskActive = false
    private var lastTaskActivitySuccessAt: Date?
}
```

`LocalUsageLoader.load` catches provider failure as `nil` without affecting quota/token results. On a non-nil activity result, publish it and record `loadDate`. On nil, retain a previous active value only while `loadDate.timeIntervalSince(lastSuccess) < fallbackInterval`; otherwise publish false. Keep activity independent of `UsageFreshness`, daily-token midnight reset, voice, and notification logic.

- [ ] **Step 4: Run store and full tests**

Run:

```bash
swift test --filter UsageStoreTests
swift test
```

Expected: focused tests pass; the full existing suite remains green.

- [ ] **Step 5: Commit integration**

```bash
git add Sources/CodexMeter/CodexMeterApp.swift Tests/CodexMeterTests/UsageStoreTests.swift
git commit -m "feat: publish active task state"
```

---

### Task 4: Text-Height Divider and Animated Ring

**Files:**
- Modify: `Sources/CodexMeter/CodexMeterApp.swift:24-250`
- Create: `Tests/CodexMeterTests/CompactStatusItemViewTests.swift`

**Interfaces:**
- Consumes: `UsageStore.$isTaskActive` from Task 3.
- Produces: `CompactStatusItemView.update(title:color:backgroundColor:tooltip:isTaskActive:)` and exact testable layout metrics.

- [ ] **Step 1: Write failing geometry and animation lifecycle tests**

Add a fake animation factory/task and assert exact metrics:

```swift
@MainActor
final class CompactStatusItemViewTests: XCTestCase {
    func testLayoutAddsDividerRingAndApprovedSpacing() {
        let layout = CompactStatusItemLayout(textWidth: 100, statusHeight: 24)
        XCTAssertEqual(layout.dividerFrame.height, 9)
        XCTAssertEqual(layout.ringFrame.width, 12.5)
        XCTAssertEqual(layout.ringFrame.height, 12.5)
        XCTAssertEqual(layout.dividerFrame.maxX + 5, layout.ringFrame.minX)
        XCTAssertEqual(layout.ringFrame.maxX + 6, layout.totalWidth)
    }

    func testActiveUpdatesStartOneTimerAndIdleStopsIt() {
        let factory = SpyStatusAnimationFactory()
        let view = CompactStatusItemView(animationFactory: factory.make)
        view.update(
            title: "64% | 6d0h",
            color: .labelColor,
            backgroundColor: .systemGreen,
            tooltip: "test",
            isTaskActive: true
        )
        view.update(
            title: "64% | 6d0h",
            color: .labelColor,
            backgroundColor: .systemGreen,
            tooltip: "test",
            isTaskActive: true
        )
        XCTAssertEqual(factory.createdCount, 1)
        view.update(
            title: "64% | 6d0h",
            color: .labelColor,
            backgroundColor: .systemGreen,
            tooltip: "test",
            isTaskActive: false
        )
        XCTAssertEqual(factory.cancelledCount, 1)
    }
}
```

Also test 12 fps interval, 30-degree angle advance per tick, frozen angle after stop, stable top angle on idle launch, full-tag click behavior unchanged, activity tooltip suffix, and accessibility text.

- [ ] **Step 2: Run focused view tests and verify RED**

Run `swift test --filter CompactStatusItemViewTests`.

Expected: compilation fails because layout and animation interfaces do not exist.

- [ ] **Step 3: Implement exact AppKit layout, drawing, and timer**

Define testable layout constants and frames:

```swift
struct CompactStatusItemLayout {
    static let horizontalPadding: CGFloat = 5
    static let dividerSpacing: CGFloat = 5
    static let dividerHeight: CGFloat = 9
    static let ringDiameter: CGFloat = 12.5
    static let trailingPadding: CGFloat = 6

    let textFrame: NSRect
    let dividerFrame: NSRect
    let ringFrame: NSRect
    let totalWidth: CGFloat

    init(textWidth: CGFloat, statusHeight: CGFloat)
}
```

Add a cancellable animation task seam whose production implementation schedules a common-run-loop `Timer` at `1.0 / 12.0`. `CompactStatusItemView` advances 30 degrees per tick, calls `needsDisplay`, creates no timer while idle, creates only one timer across repeated active updates, and cancels without resetting angle when activity becomes false or the view deinitializes.

Use these exact seam signatures so tests can record interval, ticks, creation, and cancellation without waiting on wall-clock time:

```swift
protocol StatusItemAnimationTask: AnyObject {
    func cancel()
}

typealias StatusItemAnimationFactory = (
    _ interval: TimeInterval,
    _ tick: @escaping @MainActor () -> Void
) -> any StatusItemAnimationTask

@MainActor
final class CompactStatusItemView: NSView {
    init(animationFactory: @escaping StatusItemAnimationFactory = makeStatusItemAnimation)

    func update(
        title: String,
        color: NSColor,
        backgroundColor: NSColor,
        tooltip: String,
        isTaskActive: Bool
    )
}
```

Draw the 9-point divider at 35% foreground opacity and a 12.5-point incomplete ring with 1.5-point rounded stroke. Expand the rounded tag background to `layout.totalWidth`. Extend `update` with `isTaskActive`, append the state to tooltip/accessibility text, and keep mouse handling unchanged.

In `AppDelegate`, replace the snapshot-only subscription with:

```swift
snapshotCancellable = Publishers.CombineLatest(
    usageStore.$snapshot,
    usageStore.$isTaskActive
).sink { [weak self] snapshot, isTaskActive in
    self?.updateStatusItem(with: snapshot, isTaskActive: isTaskActive)
}
```

- [ ] **Step 4: Run focused and full tests**

Run:

```bash
swift test --filter CompactStatusItemViewTests
swift test
```

Expected: geometry/animation/accessibility tests and the full suite pass.

- [ ] **Step 5: Commit the menu-bar UI**

```bash
git add Sources/CodexMeter/CodexMeterApp.swift Tests/CodexMeterTests/CompactStatusItemViewTests.swift
git commit -m "feat: animate menu task activity ring"
```

---

### Task 5: Documentation, Release Verification, and Stable Deployment

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: completed lifecycle provider, store state, and status-item UI.
- Produces: installed and verified `/Users/cc/Applications/Codex Meter.app`.

- [ ] **Step 1: Update documentation**

Document `64% | reset | ring`, global-any-task semantics, rotating/stopped states, 24-hour crash expiry, exact local lifecycle fields, local-only privacy, 800 ms event path, and 60-second fallback. Do not claim an official server task API.

- [ ] **Step 2: Run final source verification**

Run:

```bash
swift test
./scripts/build-app.sh
plutil -lint "build/Codex Meter.app/Contents/Info.plist"
git diff --check
git status --short --branch
```

Expected: all tests pass, release build succeeds with only the pre-existing `NSStatusItem.view` deprecation warning, plist reports `OK`, diff check is clean, and only the intentional README change is uncommitted.

- [ ] **Step 3: Commit documentation**

```bash
git add README.md
git commit -m "docs: describe task activity ring"
```

- [ ] **Step 4: Install and restart the stable app**

Run with the required macOS permissions:

```bash
ditto "build/Codex Meter.app" "/Users/cc/Applications/Codex Meter.app"
pkill -x CodexMeter
open -n "/Users/cc/Applications/Codex Meter.app"
```

- [ ] **Step 5: Verify process, login item, and both visual states**

Verify the running executable path is exactly `/Users/cc/Applications/Codex Meter.app/Contents/MacOS/CodexMeter` and `sfltool dumpbtm` still reports the stable app enabled and allowed.

Use Computer Use against the exact app path to inspect the menu-bar tag. During a live task, confirm the format is visually equivalent to `64% | 6d0h | ◌`, the divider has balanced spacing, the ring matches text height, and successive screenshots show angle movement. After `task_complete`, confirm successive screenshots show the same ring angle and no clipping or width jump. Confirm the entire tag still opens the existing panel.

- [ ] **Step 6: Final branch review**

Run a fresh whole-branch code review against the pre-feature commit. Fix Critical or Important findings with new RED/GREEN tests, rerun the full suite/build, and report the final commit list plus any unrelated pre-existing warnings.
