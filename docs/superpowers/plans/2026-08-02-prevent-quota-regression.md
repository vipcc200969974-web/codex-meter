# Prevent Quota Regression Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep Codex Meter synchronized with the newest local Codex quota and prevent a refresh from replacing it with an older observation.

**Architecture:** Make session-file byte limits select the newest readable candidates instead of invalidating the whole provider. Add a second recency check in `UsageStore` so an older provider result cannot replace or cache over an already displayed newer quota.

**Tech Stack:** Swift 6, Foundation, SwiftUI, XCTest, Swift Package Manager, macOS 14+

## Global Constraints

- Preserve the existing 64 MB per-file and 256 MB aggregate session scan limits.
- Preserve newest-modification-first session file ordering.
- Preserve discovery and selected-file read failure behavior.
- Never cache or publish a quota observation older than the displayed observation.
- Do not change refresh timing, daily Token accounting, task activity, colors, or layout.

---

## File Structure

- `Sources/CodexMeter/CodexMeterApp.swift`: session candidate budgeting and `UsageStore` quota acceptance.
- `Tests/CodexMeterTests/CodexSessionQuotaProviderTests.swift`: integration tests for per-file and aggregate budget selection.
- `Tests/CodexMeterTests/UsageStoreTests.swift`: asynchronous publication regression test.

### Task 1: Keep Newest Session Files Within Byte Budgets

**Files:**
- Modify: `Tests/CodexMeterTests/CodexSessionQuotaProviderTests.swift:270-370`
- Modify: `Sources/CodexMeter/CodexMeterApp.swift:1800-1860`

**Interfaces:**
- Consumes: `deduplicatedSessionFiles(overlapping:) -> [SessionFile]`, ordered newest first.
- Produces: `filesWithinScanBudget(_:) -> [SessionFile]`, containing only individually eligible files whose cumulative bytes fit `maxTotalBytes`.

- [ ] **Step 1: Change the oversized-file test to require the newer readable quota**

Use explicit modification times and assert that the old oversized file is skipped:

```swift
func testOlderOversizedSessionFileDoesNotHideNewerReadableQuota() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-meter-sessions-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let activeRoot = temporaryRoot.appendingPathComponent("sessions")
    try writeSessionFile(
        under: activeRoot,
        filename: "over-byte-cap.jsonl",
        lines: [rateLimitLine(
            timestamp: 1_100,
            usedPercent: 36,
            resetsAt: 2_000,
            windowMinutes: 10_080,
            paddingBytes: 512
        )],
        modifiedAt: Date(timeIntervalSince1970: 1_100)
    )
    try writeSessionFile(
        under: activeRoot,
        filename: "newer-readable.jsonl",
        lines: [rateLimitLine(
            timestamp: 1_200,
            usedPercent: 46,
            resetsAt: 2_000,
            windowMinutes: 10_080
        )],
        modifiedAt: Date(timeIntervalSince1970: 1_200)
    )

    let testNow = now
    let weekly = try XCTUnwrap(CodexSessionQuotaProvider(
        roots: [activeRoot],
        maxBytesPerFile: 256,
        now: { testNow }
    ).currentWindowObservations().first { $0.window.kind == .weekly })

    XCTAssertEqual(weekly.window.usedPercent, 46)
    XCTAssertEqual(weekly.observedAt, Date(timeIntervalSince1970: 1_200))
}
```

- [ ] **Step 2: Change the aggregate-cap test to require the newest file that fits**

Give the two files explicit modification times `1_100` and `1_101`. Keep both individually below `maxBytesPerFile = 1_024`, make their sum exceed `maxTotalBytes = 700`, and assert:

```swift
let weekly = try XCTUnwrap(CodexSessionQuotaProvider(
    roots: [activeRoot],
    maxBytesPerFile: 1_024,
    maxTotalBytes: 700,
    now: { testNow }
).currentWindowObservations().first { $0.window.kind == .weekly })

XCTAssertEqual(weekly.window.usedPercent, 3)
XCTAssertEqual(weekly.observedAt, Date(timeIntervalSince1970: 1_101))
```

- [ ] **Step 3: Run the focused provider tests and verify the new expectations fail**

Run:

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swiftpm-module-cache" \
swift test --filter CodexSessionQuotaProviderTests
```

Expected: FAIL because the current all-or-nothing budget check returns no observations.

- [ ] **Step 4: Select newest candidates that fit the existing limits**

Replace `filesFitScanBudget(_:)` with:

```swift
private func filesWithinScanBudget(_ files: [SessionFile]) -> [SessionFile] {
    var selected: [SessionFile] = []
    var totalBytes: UInt64 = 0

    for file in files {
        guard file.byteCount <= maxBytesPerFile,
              file.byteCount <= maxTotalBytes,
              totalBytes <= maxTotalBytes - file.byteCount else {
            continue
        }
        selected.append(file)
        totalBytes += file.byteCount
    }
    return selected
}
```

In `recentRateLimitRecords(now:)`, scan the selected files:

```swift
let filesToScan = filesWithinScanBudget(files)

var records: [RateLimitRecord] = []
for file in filesToScan {
    guard let fileRecords = rateLimitRecords(
        in: file.url,
        expectedByteCount: file.byteCount,
        fileModifiedAt: file.modifiedAt,
        now: now,
        lowerBound: lowerBound
    ) else {
        return nil
    }
    records.append(contentsOf: fileRecords)
}
```

- [ ] **Step 5: Run the focused provider tests and verify they pass**

Run the Task 1 command again. Expected: all `CodexSessionQuotaProviderTests` pass.

- [ ] **Step 6: Commit the provider fix**

```bash
git add Sources/CodexMeter/CodexMeterApp.swift Tests/CodexMeterTests/CodexSessionQuotaProviderTests.swift
git commit -m "fix: keep newest quota files within scan budget"
```

### Task 2: Reject Older Quota Publications

**Files:**
- Modify: `Tests/CodexMeterTests/UsageStoreTests.swift:60-170`
- Modify: `Tests/CodexMeterTests/UsageStoreTests.swift:1220-1245`
- Modify: `Sources/CodexMeter/CodexMeterApp.swift:1370-1410`

**Interfaces:**
- Consumes: `UsageLoadResult.quota: QuotaSnapshot?` and the current `UsageSnapshot.quota`.
- Produces: accepted quota rule `old.isUnavailable || candidate.lastUpdated >= old.lastUpdated`.

- [ ] **Step 1: Add the failing publication regression test**

```swift
func testOlderQuotaResultCannotReplaceNewerPublishedSnapshot() async {
    let newerTime = Date(timeIntervalSince1970: 1_200)
    let olderTime = Date(timeIntervalSince1970: 1_100)
    let loader = SequenceUsageLoader(results: [
        UsageLoadResult(
            quota: makeQuota(
                remainingPercent: 54,
                sourceName: "Codex 会话",
                lastUpdated: newerTime
            ),
            dailyTokens: .zero
        ),
        UsageLoadResult(
            quota: makeQuota(
                remainingPercent: 64,
                sourceName: "Codex 日志",
                lastUpdated: olderTime
            ),
            dailyTokens: .zero
        )
    ])
    let store = UsageStore(loader: loader, watcher: nil)

    let newest = await nextSnapshot(from: store) { store.refresh() }
    let afterOlderRefresh = await nextSnapshot(from: store) { store.refresh() }

    XCTAssertEqual(newest.quota.remainingPercent, 54)
    XCTAssertEqual(afterOlderRefresh.quota.remainingPercent, 54)
    XCTAssertEqual(afterOlderRefresh.quota.lastUpdated, newerTime)
    XCTAssertEqual(afterOlderRefresh.freshness, .stale)
}
```

Extend the test helper:

```swift
private func makeQuota(
    remainingPercent: Int,
    sourceName: String,
    lastUpdated: Date = Date(timeIntervalSince1970: 1_000)
) -> QuotaSnapshot {
    let now = lastUpdated
    return QuotaSnapshot(
        record: RateLimitRecord(
            timestamp: now,
            fileModifiedAt: now,
            windowSet: RateLimitWindowSet(windows: [
                RateLimitWindow(
                    usedPercent: Double(100 - remainingPercent),
                    resetsAt: 4_102_444_800,
                    windowMinutes: 10_080
                )
            ], now: now)
        ),
        sourceName: sourceName,
        lastUpdated: lastUpdated
    )
}
```

- [ ] **Step 2: Run the focused store test and verify it fails with 64 instead of 54**

Run:

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swiftpm-module-cache" \
swift test --filter UsageStoreTests/testOlderQuotaResultCannotReplaceNewerPublishedSnapshot
```

Expected: FAIL because `UsageStore.refresh()` currently publishes every non-nil quota result.

- [ ] **Step 3: Accept only an equal-or-newer quota observation**

In the main-thread completion block, replace the direct quota assignment with:

```swift
let acceptedQuota = result.quota.flatMap { candidate in
    old.quota.isUnavailable || candidate.lastUpdated >= old.quota.lastUpdated
        ? candidate
        : nil
}
let quota = acceptedQuota ?? old.quota
let isCurrentDayLoad = loadDay == currentDay
let tokens = isCurrentDayLoad ? (result.dailyTokens ?? old.dailyTokens) : old.dailyTokens
let hasFreshQuota = acceptedQuota != nil
```

Cache only `acceptedQuota`:

```swift
if let acceptedQuota {
    acceptedQuota.cache()
}
```

- [ ] **Step 4: Run the focused store test and then all UsageStore tests**

Run:

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swiftpm-module-cache" \
swift test --filter UsageStoreTests
```

Expected: all `UsageStoreTests` pass and the older candidate leaves freshness stale.

- [ ] **Step 5: Commit the publication barrier**

```bash
git add Sources/CodexMeter/CodexMeterApp.swift Tests/CodexMeterTests/UsageStoreTests.swift
git commit -m "fix: prevent quota snapshots from moving backward"
```

### Task 3: Full Verification and Installation

**Files:**
- Build: `build/Codex Meter.app`
- Install: `/Users/cc/Applications/Codex Meter.app`

**Interfaces:**
- Consumes: bounded session selection and monotonic quota publication.
- Produces: installed menu-bar app that stays on the newest local Codex quota across repeated refreshes.

- [ ] **Step 1: Run the complete Swift test suite with strict signal detection**

```bash
set -o pipefail
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swiftpm-module-cache" \
swift test > /private/tmp/codex-meter-quota-regression-full-test.log 2>&1
result=$?
if rg -q "unexpected signal|error: Process" /private/tmp/codex-meter-quota-regression-full-test.log; then
    result=1
fi
tail -n 20 /private/tmp/codex-meter-quota-regression-full-test.log
exit "$result"
```

- [ ] **Step 2: Build, sign, and validate the bundle**

```bash
git diff --check
./scripts/build-app.sh
codesign --force --deep --sign - "build/Codex Meter.app"
codesign --verify --deep --strict "build/Codex Meter.app"
plutil -lint "build/Codex Meter.app/Contents/Info.plist"
```

- [ ] **Step 3: Install and restart the stable app**

```bash
pkill -x CodexMeter || true
ditto "build/Codex Meter.app" "/Users/cc/Applications/Codex Meter.app"
open -n "/Users/cc/Applications/Codex Meter.app"
```

- [ ] **Step 4: Verify live quota and non-regression**

Compare only quota percentages and observation/reset times from the newest eligible session JSONL and SQLite records. Open the panel, trigger repeated refreshes over at least one fallback interval, and confirm:

- the displayed observation time never moves backward;
- the displayed remaining percentage matches the newest accepted local Codex observation;
- the built and installed executable hashes match;
- the process and existing login item remain enabled.

- [ ] **Step 5: Confirm a clean preserved feature branch**

```bash
git status --short --branch
git log -5 --oneline
```
