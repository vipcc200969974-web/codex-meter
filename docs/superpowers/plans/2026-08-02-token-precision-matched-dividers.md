# Token Precision and Matched Dividers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every successful daily Token refresh visibly change the headline count and render identical separators between percent, reset time, and the task ring.

**Architecture:** Keep the proven Token provider and watcher unchanged. Add a presentation-only exact formatter for the headline, increase compact metric precision, and split the status item's quota text into independently measured percent/reset segments so AppKit draws both separators with one geometry primitive.

**Tech Stack:** Swift 6, Foundation formatting, AppKit, SwiftUI, Combine, XCTest, macOS 14+

## Global Constraints

- Headline total is an exact grouped integer such as `520,778,892`; zero remains `今日暂无使用`.
- Compact values use three decimals for `亿`, two decimals for `万`, and grouped integers below `10,000`.
- Both menu separators are exactly 1 point wide, 9 points high, 35% foreground opacity, with 5 points on each side.
- Preserve the 12.5-point ring, 6-point trailing padding, 12 fps animation, full-tag clicking, tooltip, accessibility, and background geometry.
- Unavailable quota renders `未同步 | 活动圆环` with only the activity separator.
- Do not change Token parsing, aggregation, cache, watcher, refresh timing, quota behavior, activity detection, login item, dependencies, network behavior, or privacy boundaries.
- Use focused RED, minimal GREEN, focused verification, full verification, and scoped commits.

## File Structure

- Modify `Sources/CodexMeter/DailyTokenUsage.swift`: exact and precise compact Token formatting only.
- Modify `Tests/CodexMeterTests/DailyTokenUsageTests.swift`: formatting visibility and precision coverage.
- Modify `Sources/CodexMeter/CodexMeterApp.swift`: separate percent/reset inputs, dual-divider layout, drawing, accessibility, and exact headline use.
- Modify `Tests/CodexMeterTests/CompactStatusItemViewTests.swift`: exact dual-divider geometry, unavailable layout, click width, and accessibility coverage.
- Modify `README.md`: document exact total and visually matched separators.

---

### Task 1: Visible Token Formatting

**Files:**
- Modify: `Sources/CodexMeter/DailyTokenUsage.swift:306-317`
- Modify: `Sources/CodexMeter/CodexMeterApp.swift:507-535`
- Test: `Tests/CodexMeterTests/DailyTokenUsageTests.swift:536-544`

**Interfaces:**
- Produces: `TokenCountFormatter.exact(_ value: Int64) -> String` and the revised `TokenCountFormatter.compact(_:)`.
- Consumes: nonnegative `Int64` values already validated by `DailyTokenUsage.hasValidMetrics`.

- [ ] **Step 1: Write failing formatter tests**

Replace the compact expectations and add exact visibility coverage:

```swift
func testExactFormattingMakesOneTokenDifferenceVisible() {
    XCTAssertEqual(TokenCountFormatter.exact(520_778_892), "520,778,892")
    XCTAssertEqual(TokenCountFormatter.exact(520_778_893), "520,778,893")
}

func testCompactChineseFormattingUsesUsefulPrecision() {
    XCTAssertEqual(TokenCountFormatter.compact(9_999), "9,999")
    XCTAssertEqual(TokenCountFormatter.compact(10_000), "1.00万")
    XCTAssertEqual(TokenCountFormatter.compact(7_986_313), "798.63万")
    XCTAssertEqual(TokenCountFormatter.compact(100_000_000), "1.000亿")
    XCTAssertEqual(TokenCountFormatter.compact(520_778_892), "5.208亿")
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter DailyTokenUsageTests/testExactFormattingMakesOneTokenDifferenceVisible
swift test --filter DailyTokenUsageTests/testCompactChineseFormattingUsesUsefulPrecision
```

Expected: the exact test does not compile because `exact` is absent; compact expectations fail because production uses one decimal.

- [ ] **Step 3: Implement the two presentation formatters**

Add an exact grouped-integer function and change only compact precision:

```swift
enum TokenCountFormatter {
    static func exact(_ value: Int64) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    static func compact(_ value: Int64) -> String {
        if value >= 100_000_000 {
            return String(format: "%.3f亿", Double(value) / 100_000_000)
        }
        if value >= 10_000 {
            return String(format: "%.2f万", Double(value) / 10_000)
        }
        return exact(value)
    }
}
```

In `DailyTokenUsageCard`, use `TokenCountFormatter.exact(usage.totalTokens)` for the nonzero headline. Keep component, reasoning, and accessibility calls on `compact` so they inherit the additional precision.

- [ ] **Step 4: Run focused formatter tests and verify GREEN**

Run `swift test --filter DailyTokenUsageTests`.

Expected: all daily Token tests pass and a one-Token total change has a distinct headline string.

- [ ] **Step 5: Commit Token presentation**

```bash
git add Sources/CodexMeter/DailyTokenUsage.swift Sources/CodexMeter/CodexMeterApp.swift Tests/CodexMeterTests/DailyTokenUsageTests.swift
git commit -m "fix: show visible token refreshes"
```

---

### Task 2: Identical Menu-Bar Separators

**Files:**
- Modify: `Sources/CodexMeter/CodexMeterApp.swift:115-130,186-230,270-390`
- Modify: `Tests/CodexMeterTests/CompactStatusItemViewTests.swift:1-145`

**Interfaces:**
- Produces: `CompactStatusItemLayout(percentWidth:resetWidth:statusHeight:)` with `quotaDividerFrame: NSRect?`, `resetFrame: NSRect?`, `activityDividerFrame: NSRect`, `ringFrame`, and `totalWidth`.
- Produces: `CompactStatusItemView.update(percentText:resetText:color:backgroundColor:tooltip:isTaskActive:)`.
- Consumes: `QuotaSnapshot.percentText`, optional `QuotaSnapshot.shortResetText`, existing colors, tooltip, and activity Boolean.

- [ ] **Step 1: Write failing dual-divider layout tests**

Add tests equivalent to:

```swift
func testLayoutDrawsTwoIdenticalDividersAroundResetText() throws {
    let layout = CompactStatusItemLayout(
        percentWidth: 28,
        resetWidth: 36,
        statusHeight: 24
    )
    let quotaDivider = try XCTUnwrap(layout.quotaDividerFrame)
    XCTAssertEqual(quotaDivider.size, NSSize(width: 1, height: 9))
    XCTAssertEqual(layout.activityDividerFrame.size, quotaDivider.size)
    XCTAssertEqual(layout.activityDividerFrame.midY, quotaDivider.midY)
    XCTAssertEqual(layout.percentFrame.maxX + 5, quotaDivider.minX)
    let resetFrame = try XCTUnwrap(layout.resetFrame)
    XCTAssertEqual(quotaDivider.maxX + 5, resetFrame.minX)
    XCTAssertEqual(resetFrame.maxX + 5, layout.activityDividerFrame.minX)
    XCTAssertEqual(layout.activityDividerFrame.maxX + 5, layout.ringFrame.minX)
}

func testUnavailableLayoutKeepsOnlyActivityDivider() {
    let layout = CompactStatusItemLayout(percentWidth: 36, resetWidth: nil, statusHeight: 24)
    XCTAssertNil(layout.quotaDividerFrame)
    XCTAssertNil(layout.resetFrame)
    XCTAssertEqual(layout.percentFrame.maxX + 5, layout.activityDividerFrame.minX)
}
```

Update view helpers to pass `percentText: "64%"` and `resetText: "5d22h"`. Update width, tooltip, accessibility, idle, and animation tests to the new API without weakening their assertions.

- [ ] **Step 2: Run focused view tests and verify RED**

Run `swift test --filter CompactStatusItemViewTests`.

Expected: compilation fails because the split layout and update interfaces do not exist.

- [ ] **Step 3: Implement split text measurement and dual-divider drawing**

In `AppDelegate.updateStatusItem`, pass `percentText` and optional reset text separately:

```swift
let percentText = quota.isUnavailable ? "未同步" : quota.percentText
let resetText = quota.isUnavailable ? nil : quota.shortResetText
statusView?.update(
    percentText: percentText,
    resetText: resetText,
    color: quota.tagTextColor,
    backgroundColor: quota.tagBackgroundColor,
    tooltip: tooltip,
    isTaskActive: isTaskActive
)
```

In `CompactStatusItemView`, keep separately attributed percent/reset strings. Measure them independently, draw the percent and optional reset text in their frames, then draw every divider through one helper:

```swift
private func drawDivider(in frame: NSRect) {
    color.withAlphaComponent(0.35).setFill()
    NSBezierPath(rect: frame).fill()
}
```

Call the helper for the optional quota divider and mandatory activity divider. Build tooltip/accessibility from the semantic fields rather than a literal pipe. Preserve the animation lifecycle and click handlers unchanged.

- [ ] **Step 4: Run focused view tests and verify GREEN**

Run `swift test --filter CompactStatusItemViewTests`.

Expected: exact two-divider geometry, unavailable geometry, click width, accessibility, and animation tests all pass.

- [ ] **Step 5: Commit the menu-bar layout**

```bash
git add Sources/CodexMeter/CodexMeterApp.swift Tests/CodexMeterTests/CompactStatusItemViewTests.swift
git commit -m "fix: match menu bar dividers"
```

---

### Task 3: Documentation, Full Verification, and Stable Deployment

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the exact headline and matched-divider behavior from Tasks 1 and 2.
- Produces: verified production app at `/Users/cc/Applications/Codex Meter.app`.

- [ ] **Step 1: Update user-facing documentation**

State that the panel shows the exact grouped Token total, compact component values use useful precision, and the menu bar uses identical drawn separators around reset time.

- [ ] **Step 2: Run full verification**

Run:

```bash
swift test
./scripts/build-app.sh
plutil -lint "build/Codex Meter.app/Contents/Info.plist"
git diff --check
git status --short --branch
```

Expected: all tests pass, production build succeeds, plist is valid, diff check is clean, and only intended files are changed.

- [ ] **Step 3: Commit documentation**

```bash
git add README.md
git commit -m "docs: describe precise token display"
```

- [ ] **Step 4: Install and restart the stable app**

```bash
pkill -x CodexMeter
ditto "build/Codex Meter.app" "/Users/cc/Applications/Codex Meter.app"
open -n "/Users/cc/Applications/Codex Meter.app"
```

Verify the running process path and SHA-256 equality between the built and installed executables. Confirm the login item remains `enabled, allowed`.

- [ ] **Step 5: Perform real-data acceptance**

Read only aggregate cache fields. Confirm two successful refresh snapshots with different exact totals render different headline strings. Inspect the menu bar to confirm both separators have matching height, opacity, and spacing; confirm the whole tag opens the panel; confirm the ring still rotates during an active task and freezes afterward.
