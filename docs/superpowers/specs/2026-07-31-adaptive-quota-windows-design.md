# Adaptive Quota Windows Design

## Problem

Codex Meter currently accepts a quota record only when it contains both a
300-minute primary window and a 10,080-minute secondary window. Current Codex
Pro logs can instead contain one aggregate `codex` window: a 10,080-minute
primary window with no secondary window. The record is valid, but the app
discards it and displays `未同步`.

The app must not label a weekly limit as a five-hour limit merely to avoid the
unavailable state.

## Desired behavior

- Identify quota windows by `window_minutes`, independent of whether a window
  appears under `primary` or `secondary`.
- Recognize 300 minutes as the five-hour quota and 10,080 minutes as the weekly
  quota.
- When both windows exist, keep the current layout: five-hour quota in the main
  card and weekly quota in the secondary row.
- When only the weekly window exists, promote it to the main card, label it
  `7 天剩余`, and omit the duplicate secondary row.
- When only the five-hour window exists, show it in the main card and omit the
  weekly row.
- Display `未同步` only when no supported, unexpired aggregate Codex window is
  available.
- Keep model-specific limits such as `codex_bengalfox` excluded.

## Data model and parsing

Introduce a quota-window kind for five-hour and weekly windows. A parsed rate
limit record carries optional windows for both kinds instead of requiring a
fixed primary-secondary pair.

Both local providers normalize their source into the same representation:

1. Inspect every available primary and secondary window.
2. Classify supported windows by duration.
3. Ignore unsupported window durations and malformed windows.
4. Retain records that contain at least one supported unexpired window.
5. Select the newest valid aggregate `codex` record. Within the same active
   five-hour window, preserve the highest recently observed usage so a
   transient `0%` record cannot make remaining quota jump upward.

The SQLite provider must scan recent matching log rows until it finds an actual
rate-limit header set. It must not stop at the newest row merely because that
row happens to mention a header name in diagnostic text.

## Snapshot and presentation

`QuotaSnapshot` exposes an optional five-hour quota and an optional weekly
quota. It derives a main quota using this priority:

1. Five-hour quota when present.
2. Weekly quota otherwise.

Menu-bar text, tooltip text, progress color, reset time, voice announcements,
and low-quota notifications use the main quota and its truthful label. The
secondary weekly row appears only when the five-hour quota is the main quota
and a separate weekly quota is present.

Caching stores the optional windows without inventing a missing window. Cached
data remains persistence-only for this change and is not used as a fallback for
missing live data; expired cached windows are never presented as current data.

## Error handling and privacy

- A malformed line or SQLite row is skipped without failing the whole refresh.
- Expired windows are ignored individually.
- No network calls are added.
- Tests and diagnostics use only timestamps, window durations, reset times, and
  percentages. Conversation content remains unread and undisplayed.

## Testing

Add focused Swift tests around source-independent normalization and snapshot
presentation:

- A standard record containing 300-minute and 10,080-minute windows displays
  five-hour quota as main and weekly quota as secondary.
- A weekly-only aggregate record with 35% used displays `65%` and `7 天剩余`
  as the main quota without a secondary duplicate.
- Reversed primary-secondary order still classifies both windows correctly.
- Unsupported or model-specific records remain unavailable.
- Expired windows are ignored without discarding another valid window in the
  same record.
- SQLite diagnostic text that only mentions header names is skipped in favor of
  the newest parseable rate-limit row.

After the tests pass, rebuild the release app, restart it, and verify that the
running process presents the current weekly-only log record as synchronized.
