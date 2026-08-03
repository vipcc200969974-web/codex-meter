# Stop the Activity Spinner After a Task Ends Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the menu bar activity spinner after a task completes or is manually stopped, including when lifecycle records are duplicated across session files.

**Architecture:** Continue incrementally reading bounded JSONL data, but store the latest lifecycle event per turn in every file cursor. Merge those states globally by turn ID, using timestamp ordering and terminal-event precedence for ties.

**Tech Stack:** Swift 6, Foundation, CryptoKit, Swift Testing through `swift test`.

## Global Constraints

- Treat `task_started` as active.
- Treat both `task_complete` and `turn_aborted` as terminal.
- Keep the existing 24-hour lifecycle horizon and bounded incremental reads.
- Persist only turn ID, lifecycle kind, timestamp, and cursor metadata; never persist prompt or response payloads.
- Do not change the menu bar appearance, refresh interval, or quota/token behavior.

---

### Task 1: Reconcile Lifecycle State by Turn

**Files:**
- Modify: `Sources/CodexMeter/CodexTaskActivity.swift:1-864`
- Modify: `Tests/CodexMeterTests/CodexTaskActivityTests.swift`

**Interfaces:**
- Consumes: JSONL `event_msg` records containing `task_started`, `task_complete`, or `turn_aborted` plus `turn_id` and timestamp.
- Produces: `CodexTaskActivityProvider.currentActivity(now:) -> Bool`, true only when a turn's globally newest lifecycle state is active.

- [ ] **Step 1: Add failing regressions for stopped and duplicated tasks**

Add focused tests using the existing real temporary JSONL helpers:

```swift
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
```

- [ ] **Step 2: Run focused tests and confirm RED**

Run:

```bash
swift test --filter CodexTaskActivityTests
```

Expected: compilation fails because `.aborted` is missing; after adding only the enum/parser support, the copied-start and tie tests still fail because activity is tracked per file.

- [ ] **Step 3: Implement latest-event state tracking**

In `CodexTaskActivity.swift`:

1. Add `case aborted = "turn_aborted"` to `CodexTaskLifecycleKind` and include that marker in the raw discriminator.
2. Replace `FileCursor.activeTurns` with `turnStates: [String: CodexTaskLifecycleEvent]`.
3. When consuming events, retain the newer event for each turn. When timestamps are equal, retain terminal over started.
4. Retain terminal states within the 24-hour horizon so another file's older copied start can be cancelled.
5. Merge every cursor's states by turn ID using the same ordering and return true only if one merged latest state is `.started`.
6. Raise the cache schema to 3 and replace `PersistentActiveTurn` with a codable state containing `turnID`, `kind`, and `timestamp`.
7. Validate unique turn IDs, finite timestamps, and valid lifecycle kinds when loading cache data.
8. Migrate schema version 2 cursors without losing their offsets. Recover covered `task_complete` and `turn_aborted` events for legacy active turn IDs with a 64 KiB line cap so oversized private records are skipped without being cached.
9. Track the uncommitted byte count independently from the bounded partial-line buffer. Discard normal incremental lines larger than 64 KiB and resume lifecycle parsing at the next newline without retaining the oversized payload in memory.
10. Mark restored schema version 2 cursors for one-time catch-up. Scan from each legacy offset to the newest complete line with the bounded marker scanner before applying the normal byte budget, then persist schema version 3.

- [ ] **Step 4: Verify focused tests are GREEN**

Run:

```bash
swift test --filter CodexTaskActivityTests
```

Expected: all activity parser/provider tests pass with no warnings.

- [ ] **Step 5: Add restart persistence coverage**

Add a test that writes a start and abort, saves the cursor cache, constructs a new provider, and confirms the task remains idle. Extend the cache privacy assertion to require lifecycle state metadata while continuing to reject the private sentinel. Add schema version 2 migration tests that preserve an active turn, recover a covered abort, recover a completion from another file, and succeed with a zero-byte normal reconstruction budget.

Add a migration catch-up test that appends an oversized private record plus a terminal event after the schema version 2 offset and still succeeds when the normal read budget is zero.

Add provider tests proving that an oversized lifecycle-looking record is discarded and that a normal lifecycle event immediately after an oversized private record still applies.

- [ ] **Step 6: Run the complete suite and commit**

Run:

```bash
swift test
git diff --check
```

Expected: the entire suite passes and the diff has no whitespace errors.

Commit:

```bash
git add Sources/CodexMeter/CodexTaskActivity.swift Tests/CodexMeterTests/CodexTaskActivityTests.swift
git commit -m "fix: stop spinner for terminal task states"
```

### Task 2: Build, Install, and Validate the Live App

**Files:**
- Use: `scripts/build-app.sh`
- Use: `scripts/restart.sh`
- Inspect: `/Users/cc/Library/Caches/Codex Meter/task-activity-cursors.json`

**Interfaces:**
- Consumes: the tested Swift package and local Codex lifecycle logs.
- Produces: an updated `/Users/cc/Applications/Codex Meter.app` whose spinner follows current task activity.

- [ ] **Step 1: Build the release app**

Run `./scripts/build-app.sh` and confirm `build/Codex Meter.app` is produced successfully.

- [ ] **Step 2: Restart the installed app**

Run `./scripts/restart.sh` and confirm one `Codex Meter` process is running from `/Users/cc/Applications/Codex Meter.app`.

- [ ] **Step 3: Validate live lifecycle state**

Confirm the cache schema is 3, terminal state metadata is present, no prompt/response text is cached, and the known aborted turn is no longer reported active.

- [ ] **Step 4: Validate resource usage remains bounded**

Observe the installed process after launch and confirm memory remains near the previously established lightweight range rather than returning to hundreds of megabytes.

- [ ] **Step 5: Record verification without merging or pushing**

Leave the completed work on `fix/adaptive-quota-windows`. Do not merge into another branch and do not push to a remote.
