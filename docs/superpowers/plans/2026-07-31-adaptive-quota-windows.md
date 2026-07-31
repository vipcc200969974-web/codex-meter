# Adaptive Quota Windows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Synchronize Codex Meter from aggregate Codex logs that contain both five-hour and weekly quota windows or only one supported window, without mislabeling weekly quota as five-hour quota.

**Architecture:** Normalize raw primary and secondary rate-limit windows into a duration-keyed `RateLimitWindowSet`, then build a snapshot whose main quota is five-hour when available and weekly otherwise. Both the JSONL and SQLite providers feed the same model, while the view reads dynamic labels and shows the secondary weekly row only when it is distinct from the main quota.

**Tech Stack:** Swift 6, Swift Package Manager, XCTest, SwiftUI, AppKit, Foundation `Process` and `JSONSerialization`.

## Global Constraints

- Support macOS 14 and newer.
- Recognize only aggregate `limit_id == "codex"`; ignore model-specific limits such as `codex_bengalfox`.
- Recognize exactly 300-minute five-hour windows and 10,080-minute weekly windows.
- Do not add network calls or third-party dependencies.
- Never read, log, or expose prompts, replies, attachments, authentication data, or other private session content.
- When only weekly quota is present, label the main value `7 天剩余` and do not render a duplicate weekly row.
- Display `未同步` only when no supported, unexpired aggregate Codex window is available.

---

### Task 1: Duration-keyed quota domain model

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/CodexMeter/CodexMeterApp.swift:1177-1219`
- Create: `Tests/CodexMeterTests/QuotaWindowModelTests.swift`

**Interfaces:**
- Produces: `QuotaWindowKind`, `RateLimitWindow.kind`, `RateLimitWindowSet.init(windows:now:)`, `RateLimitRecord.windowSet`.
- Consumes: Existing raw `usedPercent`, `resetsAt`, and `windowMinutes` values.

- [ ] **Step 1: Add the SwiftPM test target and write failing classification tests**

Add this target after the executable target in `Package.swift`:

```swift
.testTarget(
    name: "CodexMeterTests",
    dependencies: ["CodexMeter"]
)
```

Create `Tests/CodexMeterTests/QuotaWindowModelTests.swift`:

```swift
import Foundation
import XCTest
@testable import CodexMeter

final class QuotaWindowModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testClassifiesReversedSupportedWindowsByDuration() {
        let weekly = RateLimitWindow(usedPercent: 35, resetsAt: 2_000, windowMinutes: 10_080)
        let fiveHour = RateLimitWindow(usedPercent: 20, resetsAt: 1_500, windowMinutes: 300)

        let result = RateLimitWindowSet(windows: [weekly, fiveHour], now: now)

        XCTAssertEqual(result.fiveHour?.usedPercent, 20)
        XCTAssertEqual(result.weekly?.usedPercent, 35)
    }

    func testKeepsWeeklyWindowWhenFiveHourWindowIsMissing() {
        let weekly = RateLimitWindow(usedPercent: 35, resetsAt: 2_000, windowMinutes: 10_080)

        let result = RateLimitWindowSet(windows: [weekly], now: now)

        XCTAssertNil(result.fiveHour)
        XCTAssertEqual(result.weekly?.usedPercent, 35)
    }

    func testDropsExpiredAndUnsupportedWindowsIndividually() {
        let expiredFiveHour = RateLimitWindow(usedPercent: 20, resetsAt: 900, windowMinutes: 300)
        let weekly = RateLimitWindow(usedPercent: 35, resetsAt: 2_000, windowMinutes: 10_080)
        let unknown = RateLimitWindow(usedPercent: 10, resetsAt: 2_000, windowMinutes: 60)

        let result = RateLimitWindowSet(windows: [expiredFiveHour, weekly, unknown], now: now)

        XCTAssertNil(result.fiveHour)
        XCTAssertEqual(result.weekly?.usedPercent, 35)
    }
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `swift test --filter QuotaWindowModelTests`

Expected: compilation fails because `RateLimitWindowSet` and `RateLimitWindow.kind` do not exist and `RateLimitWindow` is private.

- [ ] **Step 3: Implement the minimal duration-keyed model**

Replace the fixed two-window fields on `RateLimitRecord`, make `RateLimitWindow` testable within the module, and add:

```swift
enum QuotaWindowKind: Int, Sendable {
    case fiveHour = 300
    case weekly = 10_080

    var displayLabel: String {
        switch self {
        case .fiveHour: "5 小时剩余"
        case .weekly: "7 天剩余"
        }
    }

    var spokenName: String {
        switch self {
        case .fiveHour: "五小时额度"
        case .weekly: "七天额度"
        }
    }
}

struct RateLimitWindow: Sendable {
    let usedPercent: Double
    let resetsAt: Double
    let windowMinutes: Int?

    var kind: QuotaWindowKind? {
        windowMinutes.flatMap { QuotaWindowKind(rawValue: $0) }
    }
}

struct RateLimitWindowSet: Sendable {
    let fiveHour: RateLimitWindow?
    let weekly: RateLimitWindow?

    init(windows: [RateLimitWindow], now: Date) {
        let active = windows.filter { $0.resetsAt > now.timeIntervalSince1970 }
        fiveHour = active.last { $0.kind == .fiveHour }
        weekly = active.last { $0.kind == .weekly }
    }

    var isEmpty: Bool { fiveHour == nil && weekly == nil }
}
```

Change `RateLimitRecord` to carry `let windowSet: RateLimitWindowSet`.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run: `swift test --filter QuotaWindowModelTests`

Expected: 3 tests pass with 0 failures.

- [ ] **Step 5: Commit the domain model**

```bash
git add Package.swift Sources/CodexMeter/CodexMeterApp.swift Tests/CodexMeterTests/QuotaWindowModelTests.swift
git commit -m "refactor: model quota windows by duration"
```

---

### Task 2: JSONL provider accepts partial supported records

**Files:**
- Modify: `Sources/CodexMeter/CodexMeterApp.swift:995-1175`
- Create: `Tests/CodexMeterTests/CodexSessionQuotaProviderTests.swift`

**Interfaces:**
- Consumes: `RateLimitWindowSet.init(windows:now:)` from Task 1.
- Produces: `CodexSessionQuotaProvider.parseRecord(line:fileModifiedAt:now:) -> RateLimitRecord?` and `bestRateLimitRecord(from:now:) -> RateLimitRecord?`.

- [ ] **Step 1: Write failing JSONL parsing tests**

Create `Tests/CodexMeterTests/CodexSessionQuotaProviderTests.swift` with literal records that contain no conversation fields:

```swift
import Foundation
import XCTest
@testable import CodexMeter

final class CodexSessionQuotaProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testParsesWeeklyOnlyAggregateCodexRecord() throws {
        let line = #"{"timestamp":"1970-01-01T00:16:40Z","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":35.0,"window_minutes":10080,"resets_at":2000},"secondary":null}}}"#

        let record = CodexSessionQuotaProvider.parseRecord(
            line: line,
            fileModifiedAt: now,
            now: now
        )

        XCTAssertNil(record?.windowSet.fiveHour)
        XCTAssertEqual(record?.windowSet.weekly?.usedPercent, 35)
    }

    func testRejectsModelSpecificWeeklyRecord() {
        let line = #"{"timestamp":"1970-01-01T00:16:40Z","payload":{"rate_limits":{"limit_id":"codex_bengalfox","primary":{"used_percent":0,"window_minutes":10080,"resets_at":2000}}}}"#

        XCTAssertNil(CodexSessionQuotaProvider.parseRecord(
            line: line,
            fileModifiedAt: now,
            now: now
        ))
    }

    func testKeepsHighestUsageWithinCurrentFiveHourWindow() {
        let reset = 2_000.0
        let older = RateLimitRecord(
            timestamp: Date(timeIntervalSince1970: 1_100),
            fileModifiedAt: now,
            windowSet: RateLimitWindowSet(windows: [
                RateLimitWindow(usedPercent: 42, resetsAt: reset, windowMinutes: 300)
            ], now: now)
        )
        let newerTransientZero = RateLimitRecord(
            timestamp: Date(timeIntervalSince1970: 1_200),
            fileModifiedAt: now,
            windowSet: RateLimitWindowSet(windows: [
                RateLimitWindow(usedPercent: 0, resetsAt: reset, windowMinutes: 300)
            ], now: now)
        )

        let result = CodexSessionQuotaProvider.bestRateLimitRecord(
            from: [older, newerTransientZero],
            now: now
        )

        XCTAssertEqual(result?.windowSet.fiveHour?.usedPercent, 42)
    }
}
```

- [ ] **Step 2: Run provider tests and verify RED**

Run: `swift test --filter CodexSessionQuotaProviderTests`

Expected: compilation fails because the testable parser and best-record functions do not exist.

- [ ] **Step 3: Parse each available window independently**

Extract the current line body into the internal static function:

```swift
static func parseRecord(
    line: String,
    fileModifiedAt: Date,
    now: Date
) -> RateLimitRecord? {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let payload = object["payload"] as? [String: Any],
          let rateLimits = payload["rate_limits"] as? [String: Any],
          isAggregateCodexLimit(rateLimits) else { return nil }

    let windows = [parseWindow(rateLimits["primary"]), parseWindow(rateLimits["secondary"])]
        .compactMap { $0 }
    let windowSet = RateLimitWindowSet(windows: windows, now: now)
    guard !windowSet.isEmpty else { return nil }

    return RateLimitRecord(
        timestamp: parseDate(object["timestamp"] as? String),
        fileModifiedAt: fileModifiedAt,
        windowSet: windowSet
    )
}
```

Have `rateLimitRecords(in:fileModifiedAt:)` call this function for candidate
lines. Implement `bestRateLimitRecord(from:now:)` using this selection order:

```swift
static func bestRateLimitRecord(
    from records: [RateLimitRecord],
    now: Date
) -> RateLimitRecord? {
    let active = records.filter { !$0.windowSet.isEmpty }
    guard !active.isEmpty else { return nil }

    let latestWeekly = active.compactMap { record in
        record.windowSet.weekly.map { (record, $0) }
    }.max { $0.0.sortDate < $1.0.sortDate }

    let latestFiveHour = active.compactMap { record in
        record.windowSet.fiveHour.map { (record, $0) }
    }.max { $0.0.sortDate < $1.0.sortDate }

    let bestFiveHour = latestFiveHour.flatMap { latest in
        active.compactMap { record in
            record.windowSet.fiveHour.map { (record, $0) }
        }
        .filter { $0.1.resetsAt == latest.1.resetsAt }
        .max { $0.1.usedPercent < $1.1.usedPercent }
    }

    let selected = [bestFiveHour, latestWeekly].compactMap { $0 }
    let windows = selected.map(\.1)
    let windowSet = RateLimitWindowSet(windows: windows, now: now)
    guard !windowSet.isEmpty,
          let newest = selected.max(by: { $0.0.sortDate < $1.0.sortDate }) else {
        return nil
    }

    return RateLimitRecord(
        timestamp: newest.0.timestamp,
        fileModifiedAt: newest.0.fileModifiedAt,
        windowSet: windowSet
    )
}
```

- [ ] **Step 4: Run JSONL provider and domain tests**

Run: `swift test --filter 'QuotaWindowModelTests|CodexSessionQuotaProviderTests'`

Expected: 6 tests pass with 0 failures.

- [ ] **Step 5: Commit the JSONL provider change**

```bash
git add Sources/CodexMeter/CodexMeterApp.swift Tests/CodexMeterTests/CodexSessionQuotaProviderTests.swift
git commit -m "fix: accept partial Codex quota records"
```

---

### Task 3: SQLite provider skips diagnostic false positives

**Files:**
- Modify: `Sources/CodexMeter/CodexMeterApp.swift:868-992`
- Create: `Tests/CodexMeterTests/CodexLogQuotaProviderTests.swift`

**Interfaces:**
- Consumes: `RateLimitWindowSet` and `RateLimitRecord` from Tasks 1 and 2.
- Produces: `CodexLogQuotaProvider.parseHeaderRecord(timestamp:text:now:) -> RateLimitRecord?` and a JSON-decoded SQLite row scan.

- [ ] **Step 1: Write failing header parsing tests**

Create `Tests/CodexMeterTests/CodexLogQuotaProviderTests.swift`:

```swift
import Foundation
import XCTest
@testable import CodexMeter

final class CodexLogQuotaProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testParsesWeeklyOnlyHeaderSet() {
        let text = #"{"x-codex-primary-used-percent": "35", "x-codex-primary-window-minutes": "10080", "x-codex-primary-reset-at": "2000", "x-codex-secondary-used-percent": "0", "x-codex-secondary-window-minutes": "0", "x-codex-secondary-reset-at": ""}"#

        let record = CodexLogQuotaProvider.parseHeaderRecord(
            timestamp: 1_100,
            text: text,
            now: now
        )

        XCTAssertNil(record?.windowSet.fiveHour)
        XCTAssertEqual(record?.windowSet.weekly?.usedPercent, 35)
    }

    func testRejectsDiagnosticTextThatOnlyMentionsHeaderName() {
        let text = #"query contains x-codex-primary-used-percent but has no header values"#

        XCTAssertNil(CodexLogQuotaProvider.parseHeaderRecord(
            timestamp: 1_100,
            text: text,
            now: now
        ))
    }
}
```

- [ ] **Step 2: Run header tests and verify RED**

Run: `swift test --filter CodexLogQuotaProviderTests`

Expected: compilation fails because `parseHeaderRecord` does not exist.

- [ ] **Step 3: Restrict and scan SQLite rows**

Change the SQL to select the newest 40 authentic HTTP-client rows:

```sql
select ts, feedback_log_body
from logs
where target = 'codex_http_client::client'
  and feedback_log_body like '%x-codex-primary-used-percent%'
order by ts desc, ts_nanos desc, id desc
limit 40;
```

Invoke `/usr/bin/sqlite3` with `-readonly -json`, decode rows using:

```swift
private struct SQLiteLogRow: Decodable {
    let ts: Double
    let feedback_log_body: String
}
```

Loop newest-first and return the first row for which `parseHeaderRecord` produces at least one supported active window. Parse primary and secondary header triplets independently so an empty secondary reset does not discard the valid weekly primary window.

- [ ] **Step 4: Run all tests**

Run: `swift test`

Expected: all model and provider tests pass with 0 failures.

- [ ] **Step 5: Commit the SQLite provider change**

```bash
git add Sources/CodexMeter/CodexMeterApp.swift Tests/CodexMeterTests/CodexLogQuotaProviderTests.swift
git commit -m "fix: read authentic quota header rows"
```

---

### Task 4: Adaptive snapshot and truthful UI copy

**Files:**
- Modify: `Sources/CodexMeter/CodexMeterApp.swift:110-120,242-318,711-858,861-1016,1211-1397`
- Create: `Tests/CodexMeterTests/QuotaSnapshotTests.swift`

**Interfaces:**
- Consumes: `RateLimitRecord.windowSet`, `QuotaWindowKind.displayLabel`, and `QuotaWindowKind.spokenName`.
- Produces: `QuotaSnapshot.init(record:sourceName:lastUpdated:)`, `mainQuotaLabel`, `mainQuotaSpokenName`, and `showsWeeklySecondary`.

- [ ] **Step 1: Write failing snapshot presentation tests**

Create `Tests/CodexMeterTests/QuotaSnapshotTests.swift`:

```swift
import Foundation
import XCTest
@testable import CodexMeter

final class QuotaSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testWeeklyOnlySnapshotPromotesWeeklyQuotaWithoutDuplicateRow() {
        let record = RateLimitRecord(
            timestamp: now,
            fileModifiedAt: now,
            windowSet: RateLimitWindowSet(windows: [
                RateLimitWindow(usedPercent: 35, resetsAt: 2_000, windowMinutes: 10_080)
            ], now: now)
        )

        let snapshot = QuotaSnapshot(record: record, sourceName: "Codex 会话", lastUpdated: now)

        XCTAssertEqual(snapshot.remainingPercent, 65)
        XCTAssertEqual(snapshot.mainQuotaLabel, "7 天剩余")
        XCTAssertEqual(snapshot.mainQuotaSpokenName, "七天额度")
        XCTAssertFalse(snapshot.showsWeeklySecondary)
    }

    func testDualWindowSnapshotKeepsFiveHourMainAndWeeklySecondary() {
        let record = RateLimitRecord(
            timestamp: now,
            fileModifiedAt: now,
            windowSet: RateLimitWindowSet(windows: [
                RateLimitWindow(usedPercent: 20, resetsAt: 1_500, windowMinutes: 300),
                RateLimitWindow(usedPercent: 35, resetsAt: 2_000, windowMinutes: 10_080)
            ], now: now)
        )

        let snapshot = QuotaSnapshot(record: record, sourceName: "Codex 会话", lastUpdated: now)

        XCTAssertEqual(snapshot.remainingPercent, 80)
        XCTAssertEqual(snapshot.mainQuotaLabel, "5 小时剩余")
        XCTAssertTrue(snapshot.showsWeeklySecondary)
        XCTAssertEqual(snapshot.weeklyPercentText, "65%")
    }
}
```

- [ ] **Step 2: Run snapshot tests and verify RED**

Run: `swift test --filter QuotaSnapshotTests`

Expected: compilation fails because the record initializer and dynamic presentation properties do not exist.

- [ ] **Step 3: Build adaptive snapshots**

Add a `QuotaWindowSnapshot` value carrying `kind`, `remainingPercent`, and
`resetDate`. Refactor `QuotaSnapshot` to retain an optional main window and an
optional distinct weekly secondary window so `.unavailable()` does not invent a
quota. `QuotaSnapshot(record:sourceName:lastUpdated:)` chooses
`fiveHour ?? weekly` as main, rounds and clamps percentages, and exposes:

```swift
var isUnavailable: Bool { mainWindow == nil }
var mainQuotaLabel: String { mainWindow?.kind.displayLabel ?? "额度未获取" }
var mainQuotaSpokenName: String { mainWindow?.kind.spokenName ?? "Codex 额度" }
var showsWeeklySecondary: Bool { mainWindow?.kind == .fiveHour && weeklyWindow != nil }
```

Update `CodexLogQuotaProvider` and `CodexSessionQuotaProvider` to construct
snapshots through this initializer. Replace the old fixed cache keys with
`quota.main.kind`, `quota.main.remainingPercent`, `quota.main.resetDate`,
`quota.weekly.remainingPercent`, and `quota.weekly.resetDate`. In `cache()`, call
`removeObject(forKey:)` for both weekly keys when `weeklyWindow == nil`; in
`cached()`, require all three main keys and construct `weeklyWindow` only when
both weekly keys exist. This keeps cached partial data truthful without using
it as a fallback for missing live data.

- [ ] **Step 4: Update all user-facing copy and layout**

Make these exact behavior changes:

```swift
Text(store.snapshot.mainQuotaLabel)
```

Wrap the divider and `SecondaryQuotaRow` in:

```swift
if store.snapshot.showsWeeklySecondary {
    Divider().padding(.vertical, 1)
    SecondaryQuotaRow(
        title: "周额度",
        percentText: store.snapshot.weeklyPercentText,
        trailing: store.snapshot.weeklyResetDateText
    )
}
```

Use `mainQuotaSpokenName` in tooltip, speech, and notification text. Leave color thresholds and the 60-second refresh cadence unchanged.

- [ ] **Step 5: Run all tests and verify GREEN**

Run: `swift test`

Expected: all tests pass with 0 failures.

- [ ] **Step 6: Commit adaptive presentation**

```bash
git add Sources/CodexMeter/CodexMeterApp.swift Tests/CodexMeterTests/QuotaSnapshotTests.swift
git commit -m "feat: display whichever Codex quota window is available"
```

---

### Task 5: Release build and live weekly-only verification

**Files:**
- Verify: `Sources/CodexMeter/CodexMeterApp.swift`
- Verify: `build/Codex Meter.app`
- Preserve uncommitted: `scripts/restart.sh`, `scripts/test-restart.sh`

**Interfaces:**
- Consumes: The complete model, providers, and adaptive presentation from Tasks 1-4.
- Produces: A running release app that shows the current aggregate weekly quota as synchronized.

- [ ] **Step 1: Run the complete automated suite**

Run: `swift test`

Expected: all tests pass with 0 failures.

- [ ] **Step 2: Build the release application**

Run: `./scripts/build-app.sh`

Expected: exit status 0 and `build/Codex Meter.app/Contents/MacOS/CodexMeter` exists and is executable.

- [ ] **Step 3: Restart the app**

Run: `./scripts/restart.sh`

Expected: exit status 0 and `pgrep -fl CodexMeter` reports the built executable.

- [ ] **Step 4: Verify the live source against privacy-safe local evidence**

Query only `timestamp`, `limit_id`, `used_percent`, `window_minutes`, and `resets_at` from the newest JSONL rate-limit event. Confirm the live aggregate record is a weekly-only `codex` window with `used_percent == 35`, and confirm the app process remains running after at least one refresh cycle or a manual refresh.

- [ ] **Step 5: Review the final diff**

Run: `git diff --check` and `git status --short`.

Expected: no whitespace errors; quota commits are clean; only the previously created restart-script fix and its test remain uncommitted unless separately committed by explicit choice.
