# Reduce Codex Meter Runtime Resource Usage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop Codex Meter from eagerly scanning hundreds of megabytes of session JSONL whenever SQLite already supplies a valid quota.

**Architecture:** Preserve the ordered provider list, but evaluate it lazily. The first provider that produces a valid supported observation wins; later providers remain fallbacks and are not invoked on the normal SQLite path.

**Tech Stack:** Swift 6, Foundation, XCTest, Swift Package Manager, native macOS app bundle.

## Global Constraints

- Keep `CodexLogQuotaProvider` first and `CodexSessionQuotaProvider` second in production.
- Keep `UsageStore`'s monotonic `lastUpdated` publication barrier.
- Do not change refresh intervals, Token accounting, task activity, menu UI, or login-item behavior.
- Do not delete or rewrite Codex logs or session files.
- Verify idle CPU below 5% and physical memory below 150 MB across at least two 60-second fallback intervals.
- Keep the feature branch and worktree; do not merge, push, or open a pull request.

---

### Task 1: Make quota providers lazy

**Files:**
- Modify: `Tests/CodexMeterTests/QuotaObservationSelectionTests.swift`
- Modify: `Sources/CodexMeter/CodexMeterApp.swift:1608-1624`

**Interfaces:**
- Consumes: `QuotaObservationProviding.currentWindowObservations() -> [ObservedRateLimitWindow]` and `CompositeQuotaProvider.merge(_:now:)`.
- Produces: `CompositeQuotaProvider.currentObservation(now:) -> QuotaObservation?` with ordered lazy fallback behavior.

- [ ] **Step 1: Write the failing normal-path test**

Add a synchronized test provider and a test proving that a valid first result prevents fallback work:

```swift
private final class CountingQuotaProvider: QuotaObservationProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let observations: [ObservedRateLimitWindow]
    private var storedInvocationCount = 0

    init(observations: [ObservedRateLimitWindow]) {
        self.observations = observations
    }

    var invocationCount: Int {
        lock.withLock { storedInvocationCount }
    }

    func currentWindowObservations() -> [ObservedRateLimitWindow] {
        lock.withLock { storedInvocationCount += 1 }
        return observations
    }
}

func testValidPrimaryObservationDoesNotInvokeExpensiveFallback() throws {
    let reset = 2_000.0
    let primary = CountingQuotaProvider(observations: [
        ObservedRateLimitWindow(
            window: RateLimitWindow(usedPercent: 48, resetsAt: reset, windowMinutes: 10_080),
            observedAt: Date(timeIntervalSince1970: 1_200),
            sourceName: "Codex 日志"
        )
    ])
    let fallback = CountingQuotaProvider(observations: [
        ObservedRateLimitWindow(
            window: RateLimitWindow(usedPercent: 99, resetsAt: reset, windowMinutes: 10_080),
            observedAt: Date(timeIntervalSince1970: 1_300),
            sourceName: "Codex 会话"
        )
    ])

    let result = try XCTUnwrap(
        CompositeQuotaProvider(providers: [primary, fallback]).currentObservation(now: now)
    )

    XCTAssertEqual(result.windowSet.weekly?.usedPercent, 48)
    XCTAssertEqual(primary.invocationCount, 1)
    XCTAssertEqual(fallback.invocationCount, 0)
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter QuotaObservationSelectionTests/testValidPrimaryObservationDoesNotInvokeExpensiveFallback
```

Expected: FAIL because the current eager `flatMap` implementation invokes the fallback once.

- [ ] **Step 3: Add the fallback behavior test**

```swift
func testEmptyPrimaryInvokesFallbackAndReturnsItsObservation() throws {
    let primary = CountingQuotaProvider(observations: [])
    let fallback = CountingQuotaProvider(observations: [
        ObservedRateLimitWindow(
            window: RateLimitWindow(usedPercent: 48, resetsAt: 2_000, windowMinutes: 10_080),
            observedAt: Date(timeIntervalSince1970: 1_200),
            sourceName: "Codex 会话"
        )
    ])

    let result = try XCTUnwrap(
        CompositeQuotaProvider(providers: [primary, fallback]).currentObservation(now: now)
    )

    XCTAssertEqual(result.windowSet.weekly?.usedPercent, 48)
    XCTAssertEqual(primary.invocationCount, 1)
    XCTAssertEqual(fallback.invocationCount, 1)
}
```

This passes before and after the change and protects the retained fallback contract.

- [ ] **Step 4: Implement ordered lazy provider selection**

Replace the eager `flatMap` expression with:

```swift
func currentObservation(now: Date = Date()) -> QuotaObservation? {
    for provider in providers {
        if let observation = Self.merge(provider.currentWindowObservations(), now: now) {
            return observation
        }
    }
    return nil
}
```

- [ ] **Step 5: Run focused and full tests**

Run:

```bash
swift test --filter QuotaObservationSelectionTests
swift test
```

Expected: the focused normal-path test passes with fallback count zero; the complete suite reports zero failures.

- [ ] **Step 6: Commit the behavior change**

```bash
git add Sources/CodexMeter/CodexMeterApp.swift Tests/CodexMeterTests/QuotaObservationSelectionTests.swift
git commit -m "perf: avoid unnecessary session quota scans"
```

### Task 2: Build, install, and prove resource usage

**Files:**
- Verify: `build/Codex Meter.app`
- Install: `/Users/cc/Applications/Codex Meter.app`

**Interfaces:**
- Consumes: the production release executable from Task 1.
- Produces: a signed running menu-bar application with measured quota correctness and bounded resource use.

- [ ] **Step 1: Build and sign the app**

Run:

```bash
./scripts/build-app.sh
codesign --force --deep --sign - "build/Codex Meter.app"
codesign --verify --deep --strict --verbose=2 "build/Codex Meter.app"
```

Expected: release build exits zero and signature verification reports valid on disk.

- [ ] **Step 2: Replace and restart the installed app**

Run the existing safe bundle-copy and restart workflow, preserving `app.codex-meter.prototype` defaults and the enabled login item.

Expected: one `/Users/cc/Applications/Codex Meter.app/Contents/MacOS/CodexMeter` process is running and its executable hash matches the signed build.

- [ ] **Step 3: Compare live quota truth**

Read only quota header fields from the newest authentic `codex_http_client::client` SQLite row and compare them with `app.codex-meter.prototype` defaults.

Expected: remaining percentage and reset cycle agree; `quota.lastUpdated` does not move backward.

- [ ] **Step 4: Monitor two fallback intervals**

Sample process CPU, resident/physical memory, and quota defaults for at least 130 seconds after launch settles.

Expected: average CPU below 5%, physical or resident memory below 150 MB without sustained growth, and no quota percentage or timestamp regression.

- [ ] **Step 5: Verify final repository and installed state**

Run:

```bash
git diff --check
git status --short
codesign --verify --deep --strict --verbose=2 "/Users/cc/Applications/Codex Meter.app"
```

Expected: no uncommitted source changes, no whitespace errors, and a valid installed bundle. Preserve `fix/adaptive-quota-windows` and its worktree.
