# Recursive Codex Activity Watching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the menu-bar activity ring refresh immediately when any Codex project writes lifecycle events, regardless of the session file's original date directory.

**Architecture:** Replace date-specific `DispatchSource` bindings with one filtered recursive FSEvents stream rooted at `~/.codex`. Keep `UsageStore`'s existing debounce and 60-second fallback, and keep `CodexTaskActivityProvider` as the single source of truth for active versus stopped state.

**Tech Stack:** Swift 6, Foundation, CoreServices FSEvents, XCTest, macOS 14.

## Global Constraints

- Observe session JSONL writes below both `sessions` and `archived_sessions`, independent of directory date.
- Observe `logs_2.sqlite`, `logs_2.sqlite-wal`, and `logs_2.sqlite-shm` for quota refreshes.
- Ignore unrelated `.codex` writes.
- Preserve callback-safe `start`, `rebind`, and `stop` behavior.
- Keep the existing 0.8-second debounce and 60-second fallback refresh.
- Do not change quota calculation, token calculation, activity parsing, or menu-bar appearance.

---

### Task 1: Reproduce Cross-Date Session Writes

**Files:**
- Modify: `Tests/CodexMeterTests/CodexActivityWatcherTests.swift`

**Interfaces:**
- Consumes: `CodexActivityWatcher.init(paths:calendar:now:onChange:)`, `start()`, and `stop()`.
- Produces: regression coverage requiring a nested JSONL append outside today's calendar path to invoke `onChange`.

- [ ] **Step 1: Add the failing regression**

Add a test that creates today's directory and a different, older directory, starts the real watcher, and appends to the older file:

```swift
func testAppendToOlderSessionFileEmitsChange() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let olderSessions = root.appendingPathComponent("sessions/2042/07/29")
    let currentSessions = root.appendingPathComponent("sessions/2042/08/01")
    let archived = root.appendingPathComponent("archived_sessions")
    try FileManager.default.createDirectory(at: olderSessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: currentSessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
    let file = olderSessions.appendingPathComponent("rollout-old-project.jsonl")
    try Data().write(to: file)
    defer { try? FileManager.default.removeItem(at: root) }

    let changed = expectation(description: "older project emitted change")
    let watcher = CodexActivityWatcher(
        paths: CodexActivityPaths(
            codexRoot: root,
            sessionsRoot: root.appendingPathComponent("sessions"),
            archivedSessionsRoot: archived
        ),
        calendar: shanghaiCalendar(),
        now: { self.fixedNow },
        onChange: { changed.fulfill() }
    )
    watcher.start()
    defer { watcher.stop() }

    let handle = try FileHandle(forWritingTo: file)
    try handle.write(contentsOf: Data("{}\n".utf8))
    try handle.close()

    wait(for: [changed], timeout: 3)
}
```

- [ ] **Step 2: Run the focused test and confirm RED**

Run:

```bash
swift test --filter CodexActivityWatcherTests/testAppendToOlderSessionFileEmitsChange
```

Expected: fail by timeout because the current watcher binds only `2042/08/01`.

- [ ] **Step 3: Commit the failing regression together with the later green implementation**

Do not commit a deliberately failing tree. Preserve the verified RED output, then continue to Task 2.

### Task 2: Replace Date-Specific Bindings with Filtered FSEvents

**Files:**
- Modify: `Sources/CodexMeter/CodexActivityWatcher.swift`
- Modify: `Tests/CodexMeterTests/CodexActivityWatcherTests.swift`

**Interfaces:**
- Consumes: `CodexActivityPaths` and the existing synchronous `onChange: () -> Void` callback contract.
- Produces: `CodexActivityWatcher` with the unchanged `CodexActivityWatching` lifecycle interface and recursive path detection.

- [ ] **Step 1: Add CoreServices and stream ownership**

Import `CoreServices`. Replace the arrays of dispatch sources and descriptors with one `FSEventStreamRef?` owned by the watcher. Keep the existing private serial queue and queue-specific synchronization key.

- [ ] **Step 2: Create and start the recursive stream**

In `bindAll()`, stop any old stream, verify the Codex root exists, and create an FSEvents stream for `[paths.codexRoot.path]` using:

```swift
let flags = FSEventStreamCreateFlags(
    kFSEventStreamCreateFlagFileEvents
        | kFSEventStreamCreateFlagNoDefer
        | kFSEventStreamCreateFlagUseCFTypes
)
```

Use `kFSEventStreamEventIdSinceNow`, a `0.2` second latency, and `FSEventStreamSetDispatchQueue(stream, queue)`. The callback recovers the unretained watcher from `FSEventStreamContext.info`, converts the CF path array to `[String]`, and calls a queue-confined handler.

- [ ] **Step 3: Filter events at the watcher boundary**

Add a private predicate that returns true only for:

```swift
sessionPath.hasPrefix(paths.sessionsRoot.standardizedFileURL.path + "/")
    && sessionPath.hasSuffix(".jsonl")
```

or the equivalent archived-session prefix, or exact standardized paths for `logs_2.sqlite`, `logs_2.sqlite-wal`, and `logs_2.sqlite-shm`. Invoke `onChange()` once per callback batch when any supplied path matches.

- [ ] **Step 4: Preserve lifecycle safety**

Implement `tearDown()` with `FSEventStreamStop`, `FSEventStreamSetDispatchQueue(stream, nil)`, `FSEventStreamInvalidate`, and `FSEventStreamRelease`, then clear the stored reference. Keep `start`, `rebind`, and `stop` on the existing private queue so a callback can safely call `stop()` without deadlock.

- [ ] **Step 5: Run watcher tests and confirm GREEN**

Run:

```bash
swift test --filter CodexActivityWatcherTests
```

Expected: the older-directory regression and all existing callback/restart/replacement tests pass.

- [ ] **Step 6: Add and run the unrelated-path filter regression**

Add an inverted expectation, start the watcher, append to `root/config.toml`, and wait for 0.8 seconds. The callback must not fire. Re-run `CodexActivityWatcherTests` and require zero failures.

- [ ] **Step 7: Commit the watcher fix**

```bash
git add Sources/CodexMeter/CodexActivityWatcher.swift Tests/CodexMeterTests/CodexActivityWatcherTests.swift
git commit -m "fix: watch activity across all projects"
```

### Task 3: Verify, Build, Install, and Observe

**Files:**
- Use: `scripts/build-app.sh`
- Install: `/Users/cc/Applications/Codex Meter.app`
- Inspect: `/Users/cc/Library/Caches/Codex Meter/task-activity-cursors.json`

**Interfaces:**
- Consumes: the tested recursive watcher and existing activity provider.
- Produces: an installed menu-bar app that promptly starts and stops its ring for every project.

- [ ] **Step 1: Run all tests and source checks**

Run:

```bash
swift test
git diff --check
```

Expected: all tests pass with zero failures and no whitespace errors.

- [ ] **Step 2: Build and sign**

Run `./scripts/build-app.sh`, ad-hoc sign `build/Codex Meter.app`, and verify the signature with `codesign --verify --deep --strict`.

- [ ] **Step 3: Replace and restart the installed app**

Stop the existing `CodexMeter` process, copy the built app to `/Users/cc/Applications/Codex Meter.app`, verify the installed signature and binary hash, then launch exactly one installed process.

- [ ] **Step 4: Validate the live cross-date event**

While this Codex task continues writing its July 31 session file, confirm the installed app's activity cache advances within a few seconds rather than waiting for the 60-second fallback. Confirm the newest `task_started` state is active during work and a terminal state is accepted when work stops.

- [ ] **Step 5: Validate bounded resources**

Observe the installed process after startup and event handling. Confirm memory remains far below the prior 354 MB regression and CPU settles without a tight polling loop.

- [ ] **Step 6: Preserve the branch**

Leave all commits on `fix/adaptive-quota-windows`. Do not merge, push, or remove the worktree.
