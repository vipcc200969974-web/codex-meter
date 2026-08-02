# Quota Reset Drift Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Codex Meter show the newest truthful remaining quota when the same reset cycle's timestamp drifts by a few seconds.

**Architecture:** Keep the fix inside `RateLimitWindowReducer.bestWindows`. Select the active reset cycle using the greatest reset timestamp plus an inclusive 60-second tolerance, then combine that cycle's highest usage with its newest observation metadata.

**Tech Stack:** Swift 6, Foundation, XCTest, Swift Package Manager, AppKit/SwiftUI macOS application

## Global Constraints

- Reset timestamps differing by at most 60 seconds are the same cycle.
- Usage within a cycle remains monotonic by selecting the highest observed usage.
- The published observation time, source, and reset timestamp come from the newest observation in the selected cycle.
- Reset timestamps more than 60 seconds apart remain distinct cycles.
- Existing five-hour, weekly-only, expiry, and unsupported-window behavior must remain unchanged.

---

### Task 1: Tolerate Reset Timestamp Drift

**Files:**
- Modify: `Tests/CodexMeterTests/QuotaObservationSelectionTests.swift`
- Modify: `Sources/CodexMeter/CodexMeterApp.swift`

**Interfaces:**
- Consumes: `CompositeQuotaProvider.merge(_:now:)`, `ObservedRateLimitWindow`, `RateLimitWindowReducer.bestWindows(from:now:)`
- Produces: reducer behavior that groups reset epochs within 60 seconds and publishes the newest observation's reset epoch

- [ ] **Step 1: Write the failing regression test**

Add a test with the real observed pattern:

```swift
func testResetDriftWithinSixtySecondsUsesNewestTruthfulQuota() throws {
    let older = ObservedRateLimitWindow(
        window: RateLimitWindow(usedPercent: 36, resetsAt: 1_986, windowMinutes: 10_080),
        observedAt: Date(timeIntervalSince1970: 1_100),
        sourceName: "Codex 日志"
    )
    let newer = ObservedRateLimitWindow(
        window: RateLimitWindow(usedPercent: 43, resetsAt: 1_971, windowMinutes: 10_080),
        observedAt: Date(timeIntervalSince1970: 1_200),
        sourceName: "Codex 日志"
    )

    let result = try XCTUnwrap(CompositeQuotaProvider.merge([older, newer], now: now))

    XCTAssertEqual(result.windowSet.weekly?.usedPercent, 43)
    XCTAssertEqual(result.windowSet.weekly?.resetsAt, 1_971)
    XCTAssertEqual(result.observedAt, newer.observedAt)
}
```

Also add a 61-second boundary test where the cycle with the greater reset epoch continues to win.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swiftpm-module-cache" \
swift test --filter QuotaObservationSelectionTests
```

Expected: the drift regression fails because the old implementation returns 36% used with reset epoch `1986`.

- [ ] **Step 3: Implement the minimal reducer fix**

In `RateLimitWindowReducer`, add an internal tolerance and select candidates whose reset timestamp remains within that tolerance of the greatest reset timestamp:

```swift
private static let resetDriftTolerance: Int64 = 60

let selectedCycle = candidatesForKind.filter {
    guard let reset = $0.window.canonicalResetEpochSecond else { return false }
    return newestReset - reset <= resetDriftTolerance
}
```

Keep `highestUsage` and `latestObservation` selection, but construct the returned window with `latestObservation.window.resetsAt` and `latestObservation.window.windowMinutes`.

- [ ] **Step 4: Run focused quota tests and verify GREEN**

Run the command from Step 2. Expected: all `QuotaObservationSelectionTests` pass.

- [ ] **Step 5: Run all quota-provider tests**

Run:

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swiftpm-module-cache" \
swift test --filter 'QuotaObservationSelectionTests|CodexLogQuotaProviderTests|CodexSessionQuotaProviderTests|QuotaSnapshotTests|QuotaWindowModelTests'
```

Expected: every selected test passes with zero failures.

- [ ] **Step 6: Commit the code and regression tests**

```bash
git add Sources/CodexMeter/CodexMeterApp.swift Tests/CodexMeterTests/QuotaObservationSelectionTests.swift
git commit -m "fix: tolerate quota reset timestamp drift"
```

### Task 2: Build, Install, and Verify Live Quota

**Files:**
- Verify: `Sources/CodexMeter/CodexMeterApp.swift`
- Verify: `Tests/CodexMeterTests/QuotaObservationSelectionTests.swift`
- Build output: `build/Codex Meter.app`
- Installed output: `/Users/cc/Applications/Codex Meter.app`

**Interfaces:**
- Consumes: the corrected reducer from Task 1 and local `codex_http_client::client` quota headers
- Produces: a running installed menu-bar app whose cached weekly remaining percentage matches the newest local header

- [ ] **Step 1: Run the complete test suite**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swiftpm-module-cache" \
swift test
```

Expected: all tests pass with zero failures.

- [ ] **Step 2: Build and validate the application bundle**

```bash
./scripts/build-app.sh
plutil -lint "build/Codex Meter.app/Contents/Info.plist"
git diff --check
```

Expected: the release build succeeds, the plist is valid, and the diff check is clean.

- [ ] **Step 3: Install and restart the stable application**

```bash
pkill -x CodexMeter
ditto "build/Codex Meter.app" "/Users/cc/Applications/Codex Meter.app"
open -n "/Users/cc/Applications/Codex Meter.app"
```

- [ ] **Step 4: Verify the live value and installation**

Read the newest aggregate weekly quota header from `~/.codex/logs_2.sqlite`, calculate `100 - used_percent`, and compare it with `defaults read app.codex-meter.prototype quota.main.remainingPercent`. Verify the built and installed executable SHA-256 hashes match and the running process uses `/Users/cc/Applications/Codex Meter.app`.

Expected: the cached remaining percentage matches the newest local header (57% for the captured reproduction), and the installed executable matches the build.

- [ ] **Step 5: Confirm the working tree is clean**

```bash
git status --short --branch
```

Expected: no uncommitted files remain on `fix/adaptive-quota-windows`.
