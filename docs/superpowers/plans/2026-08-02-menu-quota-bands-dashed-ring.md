# Menu Quota Bands and Dashed Activity Ring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Codex Meter consistent red/orange/green quota thresholds and replace the continuous activity arc with a visibly rotating dashed arc.

**Architecture:** Add a single `QuotaColorBand` classifier that owns quota tint, badge background, and text colors. Extract creation of the actual `NSBezierPath` for the activity ring so drawing and tests use the same 285-degree dashed arc while the existing layout and timer remain unchanged.

**Tech Stack:** Swift 6, AppKit, SwiftUI, XCTest, Swift Package Manager, macOS status item application

## Global Constraints

- `0...20%` is critical red.
- `21...50%` is warning orange.
- `51...100%` keeps the existing healthy mint green.
- Unavailable quota remains neutral.
- The ring remains 12.5 points in diameter with a 1.5-point stroke, 285-degree sweep, 75-degree opening, 12 FPS animation, and 30-degree animation step.
- The ring dash pattern is exactly `[1.6, 2.4]` with rounded caps.
- Layout, click target, dividers, tooltip, accessibility, and active/idle behavior must not change.

---

### Task 1: Unify Quota Color Bands

**Files:**
- Modify: `Sources/CodexMeter/CodexMeterApp.swift`
- Modify: `Tests/CodexMeterTests/QuotaSnapshotTests.swift`

**Interfaces:**
- Produces: `QuotaColorBand.init(remainingPercent: Int)`, `tint: Color`, `tagBackgroundColor: NSColor`, and `tagTextColor: NSColor`
- Consumes: `QuotaSnapshot.mainWindow?.remainingPercent` and `weeklyWindow?.remainingPercent`

- [ ] **Step 1: Write failing boundary tests**

Add literal classification tests:

```swift
func testQuotaColorBandsUseInclusiveTwentyAndFiftyPercentBoundaries() {
    XCTAssertEqual(QuotaColorBand(remainingPercent: 20), .critical)
    XCTAssertEqual(QuotaColorBand(remainingPercent: 21), .warning)
    XCTAssertEqual(QuotaColorBand(remainingPercent: 50), .warning)
    XCTAssertEqual(QuotaColorBand(remainingPercent: 51), .healthy)
}
```

Add a warning snapshot test that derives 50% remaining from a real 50%-used weekly window and asserts `snapshot.tint == .orange`, background `NSColor(calibratedRed: 1.000, green: 0.820, blue: 0.550, alpha: 0.94)`, and text `NSColor(calibratedRed: 0.400, green: 0.200, blue: 0.000, alpha: 1)`.

- [ ] **Step 2: Run the focused test and verify RED**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swiftpm-module-cache" \
swift test --filter QuotaSnapshotTests
```

Expected: compilation fails because `QuotaColorBand` does not exist, proving the test targets the new shared classifier.

- [ ] **Step 3: Implement the shared color band**

Add the enum next to `QuotaSnapshot`:

```swift
enum QuotaColorBand: Equatable {
    case critical
    case warning
    case healthy

    init(remainingPercent: Int) {
        switch remainingPercent {
        case 0...20: self = .critical
        case 21...50: self = .warning
        default: self = .healthy
        }
    }
}
```

Move the existing critical and healthy colors into computed properties on the enum. Use background `NSColor(calibratedRed: 1.000, green: 0.820, blue: 0.550, alpha: 0.94)`, text `NSColor(calibratedRed: 0.400, green: 0.200, blue: 0.000, alpha: 1)`, and `Color.orange` for warning. Update `QuotaSnapshot.tint`, `tagBackgroundColor`, `tagTextColor`, and `weeklyTint` to derive from `QuotaColorBand`.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the command from Step 2. Expected: every `QuotaSnapshotTests` test passes.

- [ ] **Step 5: Commit the color change**

```bash
git add Sources/CodexMeter/CodexMeterApp.swift Tests/CodexMeterTests/QuotaSnapshotTests.swift
git commit -m "feat: add quota color bands"
```

### Task 2: Draw a Dashed Activity Arc

**Files:**
- Modify: `Sources/CodexMeter/CodexMeterApp.swift`
- Modify: `Tests/CodexMeterTests/CompactStatusItemViewTests.swift`

**Interfaces:**
- Produces: `StatusActivityRingPath.make(in:angleDegrees:) -> NSBezierPath`
- Consumes: `CompactStatusItemLayout.ringFrame` and `CompactStatusItemView.ringAngleDegrees`

- [ ] **Step 1: Write a failing path-style test**

Build the same path that production drawing will stroke and inspect its real AppKit style:

```swift
func testActivityRingPathUsesRoundedShortDashes() {
    let path = StatusActivityRingPath.make(
        in: NSRect(x: 0, y: 0, width: 12.5, height: 12.5),
        angleDegrees: 90
    )
    var count = 0
    var phase: CGFloat = 0
    path.getLineDash(nil, count: &count, phase: &phase)
    var pattern = [CGFloat](repeating: 0, count: count)
    pattern.withUnsafeMutableBufferPointer {
        path.getLineDash($0.baseAddress, count: &count, phase: &phase)
    }

    XCTAssertEqual(path.lineWidth, 1.5)
    XCTAssertEqual(path.lineCapStyle, .round)
    XCTAssertEqual(pattern, [1.6, 2.4])
    XCTAssertEqual(phase, 0)
}
```

- [ ] **Step 2: Run the focused test and verify RED**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swiftpm-module-cache" \
swift test --filter CompactStatusItemViewTests
```

Expected: compilation fails because `StatusActivityRingPath` does not exist.

- [ ] **Step 3: Implement and use the dashed path helper**

Create an internal helper before `CompactStatusItemView`:

```swift
enum StatusActivityRingPath {
    static let lineWidth: CGFloat = 1.5
    static let sweepDegrees: CGFloat = 285
    static let dashPattern: [CGFloat] = [1.6, 2.4]

    static func make(in frame: NSRect, angleDegrees: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        dashPattern.withUnsafeBufferPointer {
            path.setLineDash($0.baseAddress, count: $0.count, phase: 0)
        }
        path.appendArc(
            withCenter: NSPoint(x: frame.midX, y: frame.midY),
            radius: (CompactStatusItemLayout.ringDiameter - lineWidth) / 2,
            startAngle: angleDegrees,
            endAngle: angleDegrees + sweepDegrees,
            clockwise: false
        )
        return path
    }
}
```

Replace the inline continuous `NSBezierPath` construction in `draw(_:)` with this helper. Keep coloring and `stroke()` in `draw(_:)`.

- [ ] **Step 4: Run focused UI tests and verify GREEN**

Run the command from Step 2. Expected: all compact status item tests pass, including existing animation, layout, click, and accessibility coverage.

- [ ] **Step 5: Commit the dashed ring change**

```bash
git add Sources/CodexMeter/CodexMeterApp.swift Tests/CodexMeterTests/CompactStatusItemViewTests.swift
git commit -m "feat: draw dashed task activity ring"
```

### Task 3: Verify, Build, Install, and Inspect

**Files:**
- Verify: `Sources/CodexMeter/CodexMeterApp.swift`
- Verify: `Tests/CodexMeterTests/QuotaSnapshotTests.swift`
- Verify: `Tests/CodexMeterTests/CompactStatusItemViewTests.swift`
- Build output: `build/Codex Meter.app`
- Installed output: `/Users/cc/Applications/Codex Meter.app`

**Interfaces:**
- Consumes: Tasks 1 and 2
- Produces: a tested, installed menu-bar application and a real menu-bar screenshot

- [ ] **Step 1: Run the complete test suite**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swiftpm-module-cache" \
swift test
```

Expected: all tests pass with zero failures and no XCTest signal interruption.

- [ ] **Step 2: Build and validate the release application**

```bash
./scripts/build-app.sh
plutil -lint "build/Codex Meter.app/Contents/Info.plist"
git diff --check
```

Expected: the build exits successfully, the plist is valid, and the diff check is clean.

- [ ] **Step 3: Install and restart the stable application**

```bash
pkill -x CodexMeter
ditto "build/Codex Meter.app" "/Users/cc/Applications/Codex Meter.app"
open -n "/Users/cc/Applications/Codex Meter.app"
```

- [ ] **Step 4: Verify the installed result**

Confirm the built and installed executable SHA-256 hashes match, the running process uses `/Users/cc/Applications/Codex Meter.app`, the login item remains enabled, and a cropped menu-bar screenshot shows the dashed activity arc at the existing size and spacing.

- [ ] **Step 5: Confirm branch cleanliness**

```bash
git diff --check
git status --short --branch
```

Expected: the branch has no uncommitted changes.
