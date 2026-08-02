# Token Precision and Matched Menu Dividers Design

## Goal

Make every successful daily Token refresh visibly change the headline value, and make the two menu-bar separators visually identical without changing quota, task-ring, panel, login-item, or network behavior.

## Confirmed Root Cause

The Token provider and cache are updating correctly. During diagnosis the cached total advanced from `520,422,396` to `520,778,892`, while the panel continued to show `5.2亿`. The existing formatter rounds every value of at least one hundred million Tokens to one decimal place, so changes below roughly ten million Tokens are hidden.

## Token Presentation

- Show the headline total as an exact grouped integer, for example `520,778,892`.
- Keep zero as `今日暂无使用`.
- Keep the three component cards compact, but increase their visible precision:
  - values of at least one hundred million use three decimals in `亿`;
  - values of at least ten thousand use two decimals in `万`;
  - smaller values use grouped integers.
- Apply the same precise compact formatter to the reasoning row and accessibility values.
- Do not change Token parsing, aggregation, cache, watcher, refresh timing, or privacy boundaries.

## Menu-Bar Layout

- Pass percent text and reset text to `CompactStatusItemView` as separate fields instead of embedding a text `|`.
- Draw two separators with the same primitive and constants:
  - 1 point wide;
  - 9 points high;
  - 35% foreground opacity;
  - 5 points of spacing on both sides.
- Layout order is `百分比 | 重置时间 | 活动圆环`.
- Preserve the 12.5-point ring, 6-point trailing padding, animation behavior, tooltip, accessibility meaning, full-tag click target, and background geometry.
- When quota is unavailable, show `未同步 | 活动圆环` with only the separator before the ring.

## Verification

- Formatter tests prove a one-Token change alters the exact headline string and verify the new compact precision.
- Layout tests prove both separator frames have identical size, vertical alignment, opacity, and spacing.
- View tests prove width includes both separators and the full tag remains clickable.
- Run the focused formatter/view tests, the complete Swift test suite, production app build, plist lint, and `git diff --check`.
- Install the stable app, confirm its binary matches the build, confirm the Token cache continues advancing, and inspect the menu-bar tag for matching separators.

## Non-Goals

- No changes to quota calculation or labels.
- No changes to task activity detection or ring timing.
- No new polling, dependencies, network requests, or retained private log content.
