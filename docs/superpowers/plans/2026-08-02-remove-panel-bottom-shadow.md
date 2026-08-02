# Remove Main Panel Bottom Shadow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the clipped faint band beneath the main status panel without changing the glass styling or the actions popover shadow.

**Architecture:** Add a small role model that distinguishes the main panel from the actions popover. `PanelGlassBackground` will draw one shared glass surface and conditionally apply its existing outer shadow only for the popover role.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest, Swift Package Manager, macOS 14+

## Global Constraints

- Change only the outer shadow behavior of the main panel.
- Preserve the glass material, gradient, rounded outline, inner highlight, and inset cards.
- Preserve the existing actions popover outer shadow.
- Do not change quota, token, color, activity-ring, refresh, or login-item behavior.
- Make no dependency or package-platform changes.

---

## File Structure

- `Sources/CodexMeter/CodexMeterApp.swift`: owns the two glass surface call sites and the shared SwiftUI glass background.
- `Tests/CodexMeterTests/PanelGlassBackgroundTests.swift`: protects the role-specific outer-shadow policy.

### Task 1: Make the Outer Shadow Role-Specific

**Files:**
- Create: `Tests/CodexMeterTests/PanelGlassBackgroundTests.swift`
- Modify: `Sources/CodexMeter/CodexMeterApp.swift:474-499`
- Modify: `Sources/CodexMeter/CodexMeterApp.swift:674-730`
- Modify: `Sources/CodexMeter/CodexMeterApp.swift:935-962`

**Interfaces:**
- Consumes: existing `PanelGlassBackground` SwiftUI surface and its main-panel and actions-popover call sites.
- Produces: `PanelGlassSurfaceRole`, `PanelGlassSurfaceRole.castsOuterShadow: Bool`, and `PanelGlassBackground(role:)`.

- [ ] **Step 1: Write the failing role-policy test**

```swift
import XCTest
@testable import CodexMeter

final class PanelGlassBackgroundTests: XCTestCase {
    func testMainPanelOmitsOuterShadowWhileActionsPopoverKeepsIt() {
        XCTAssertFalse(PanelGlassSurfaceRole.mainPanel.castsOuterShadow)
        XCTAssertTrue(PanelGlassSurfaceRole.actionsPopover.castsOuterShadow)
    }
}
```

- [ ] **Step 2: Run the focused test and verify the missing role fails compilation**

Run:

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swiftpm-module-cache" \
swift test --filter PanelGlassBackgroundTests
```

Expected: FAIL because `PanelGlassSurfaceRole` is not defined.

- [ ] **Step 3: Add the role policy and apply it at both call sites**

Add beside `PanelGlassBackground`:

```swift
enum PanelGlassSurfaceRole {
    case mainPanel
    case actionsPopover

    var castsOuterShadow: Bool {
        self == .actionsPopover
    }
}
```

Change the main panel call to:

```swift
PanelGlassBackground(role: .mainPanel)
```

Change the actions popover call to:

```swift
.background(PanelGlassBackground(role: .actionsPopover))
```

Split the shared surface from the conditional shadow:

```swift
struct PanelGlassBackground: View {
    let role: PanelGlassSurfaceRole

    @ViewBuilder
    var body: some View {
        if role.castsOuterShadow {
            glassSurface
                .shadow(color: Color.black.opacity(0.12), radius: 18, x: 0, y: 10)
        } else {
            glassSurface
        }
    }

    private var glassSurface: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

        return ZStack {
            shape
                .fill(.ultraThinMaterial)

            shape
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.64),
                            Color(red: 0.82, green: 0.94, blue: 1.0).opacity(0.48),
                            Color.white.opacity(0.30)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.84),
                            Color(red: 0.90, green: 0.98, blue: 1.0).opacity(0.32),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 4,
                        endRadius: 82
                    )
                )
                .frame(width: 130, height: 150)
                .offset(x: 130, y: -56)
                .blur(radius: 4)

            shape
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.68),
                            Color.white.opacity(0.38),
                            Color(red: 0.42, green: 0.70, blue: 0.88).opacity(0.20)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )

            shape
                .stroke(Color.white.opacity(0.22), lineWidth: 0.7)
                .padding(1.2)
        }
        .clipShape(shape)
    }
}
```

- [ ] **Step 4: Run the focused test and verify it passes**

Run:

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swiftpm-module-cache" \
swift test --filter PanelGlassBackgroundTests
```

Expected: PASS with one test and no unexpected-signal output.

- [ ] **Step 5: Commit the behavior change**

```bash
git add Sources/CodexMeter/CodexMeterApp.swift Tests/CodexMeterTests/PanelGlassBackgroundTests.swift
git commit -m "fix: remove clipped main panel shadow"
```

### Task 2: Verify, Build, Install, and Visually Inspect

**Files:**
- Verify: `Sources/CodexMeter/CodexMeterApp.swift`
- Verify: `Tests/CodexMeterTests/PanelGlassBackgroundTests.swift`
- Build: `build/Codex Meter.app`
- Install: `/Users/cc/Applications/Codex Meter.app`

**Interfaces:**
- Consumes: the role-specific glass background from Task 1.
- Produces: a verified and installed app bundle whose main panel has no bottom shadow band.

- [ ] **Step 1: Run the complete Swift test suite with strict exit checking**

```bash
set -o pipefail
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swiftpm-module-cache" \
swift test > /private/tmp/codex-meter-panel-shadow-full-test.log 2>&1
result=$?
if rg -q "unexpected signal|error: Process" /private/tmp/codex-meter-panel-shadow-full-test.log; then
    result=1
fi
tail -n 20 /private/tmp/codex-meter-panel-shadow-full-test.log
exit "$result"
```

Expected: exit 0, all tests pass, and no unexpected-signal marker appears.

- [ ] **Step 2: Check formatting and build the application bundle**

```bash
git diff --check
./scripts/build-app.sh
plutil -lint "build/Codex Meter.app/Contents/Info.plist"
```

Expected: every command exits 0 and the property list reports `OK`.

- [ ] **Step 3: Replace the stable app and restart it**

```bash
pkill -x CodexMeter || true
ditto "build/Codex Meter.app" "/Users/cc/Applications/Codex Meter.app"
open -n "/Users/cc/Applications/Codex Meter.app"
```

Expected: the installed app launches and its menu-bar item reappears.

- [ ] **Step 4: Inspect the live panel and installed bundle**

Open the menu-bar panel and capture its screen region. Confirm all of the following:

- no faint rectangular band appears below the rounded main card;
- the rounded glass material and inset cards remain visible;
- the actions popover still receives the `.actionsPopover` role;
- built and installed executable hashes match;
- the `CodexMeter` process is running and the existing login item remains enabled.

- [ ] **Step 5: Confirm the branch state**

```bash
git status --short --branch
git log -2 --oneline
```

Expected: the feature branch contains the design and behavior commits, with no uncommitted source or test changes.
