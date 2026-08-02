# Quota Reset Drift Design

## Problem

Codex reports the same weekly quota window with slightly different `reset-at` values between requests. On 2026-08-02, the older observation reported 36% used with reset epoch `1786159986`, while the newer observation reported 43% used with reset epoch `1786159971`. The 15-second drift caused the reducer to treat the older observation as a later reset cycle and keep showing 64% remaining instead of the truthful 57%.

## Approved Behavior

- Treat supported quota observations whose reset timestamps differ by at most 60 seconds as the same reset cycle.
- Within one reset cycle, retain the highest observed usage so transient zero or lower readings cannot make remaining quota increase incorrectly.
- Publish the newest observation timestamp and source from that cycle so the UI shows the real refresh time.
- Keep observations more than 60 seconds apart in separate cycles. Continue selecting the cycle with the latest reset timestamp.
- Preserve all existing behavior for five-hour and weekly windows, weekly-only promotion, unsupported-window rejection, and expired-window rejection.

## Design

The change stays inside `RateLimitWindowReducer.bestWindows`. For each supported quota kind, observations are sorted by canonical reset timestamp and grouped into reset cycles. Adjacent reset timestamps that remain within 60 seconds of the cycle's newest reset timestamp belong to the same cycle. The reducer selects the cycle with the greatest reset timestamp, then combines its highest usage with its newest observation metadata.

The resulting window uses the newest observation's reset timestamp normalized to its canonical whole second rather than the stale maximum. This keeps the displayed countdown aligned with the freshest response, preserves the existing fractional-reset normalization, and preserves monotonic usage within the cycle.

## Testing

Add reducer-level regression coverage for:

1. A newer 43%-used weekly observation whose reset timestamp is 15 seconds earlier than an older 36%-used observation. The result must be 43% used and carry the newer observation time/reset value.
2. Observations more than 60 seconds apart. They must remain separate cycles, and the later reset cycle must still win.

Run the focused quota selection tests, then the complete Swift test suite. Finally build and install the app, verify the cached quota becomes 57%, and compare it with the newest local quota header.
