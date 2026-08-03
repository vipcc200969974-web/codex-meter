# Prevent Quota Regression

## Problem

Codex Meter can briefly show the latest weekly quota and then jump back to an older percentage. On 2026-08-02 the live evidence was:

- session JSONL at 13:58: 46% used, 54% remaining, reset at 2026-08-08 11:32:51;
- SQLite at 10:43: 36% used, 64% remaining, reset at 2026-08-08 11:33:06;
- the panel regressed from 54% to 64% and changed its update label from 13:58 to 10:43;
- an archived session candidate was approximately 20.7 GB, above the provider's 64 MB per-file limit.

`CodexSessionQuotaProvider` currently invalidates its entire result when any candidate exceeds the per-file limit or when the aggregate candidates exceed the total limit. This hides newer readable JSONL files and leaves the older SQLite observation as the only source. `UsageStore` then accepts that older observation without comparing it to the already displayed snapshot.

## Approaches Considered

1. Reject older snapshots only. This stops the visible jump but leaves the session provider unable to supply newer data after a large archived file appears.
2. Make the session provider skip oversized candidates only. This restores the current session data, but a later transiently incomplete source could still replace a newer displayed observation.
3. Repair candidate budgeting and add a publication-time recency barrier. This addresses both the source failure and the visible state regression, so it is the selected approach.

## Design

### Bounded session selection

The session provider keeps candidates in its existing newest-modification-first order. It skips individual files larger than `maxBytesPerFile`, then selects as many remaining files as fit within `maxTotalBytes`. A single oversized or older over-budget file no longer invalidates newer readable files.

The provider still treats discovery failure or a read failure in any selected file as a failed session read. The change is limited to files that are intentionally excluded by the configured byte budgets.

### Monotonic publication

Before publishing a quota result, `UsageStore` compares its `lastUpdated` value with the currently displayed quota. A candidate is eligible when the current quota is unavailable or the candidate observation time is equal to or newer than the current observation time.

An older candidate is treated like a quota read failure:

- the current quota and its update time remain visible;
- the older candidate is not written to `UserDefaults`;
- freshness becomes stale unless both quota and token data were accepted;
- token and task-activity updates continue independently.

Equal timestamps remain eligible because the provider already resolves reset-cycle, source-priority, and highest-usage ties before constructing the snapshot.

`UsageStore` receives its initial cached quota and cache-save action explicitly. `AppDelegate` supplies the real `UserDefaults` load/save behavior, while tests default to no cached quota and a no-op save action. This keeps the regression tests independent from the user's installed-app cache.

## Testing

Add or update focused tests for these production failures:

- an older oversized session file cannot hide a newer readable quota file;
- when aggregate candidates exceed the total budget, the newest files that fit are still scanned;
- an older quota result cannot replace a newer `UsageStore` snapshot or cache value.

Then run the focused provider and store tests, the full Swift test suite, a release build, bundle validation, installation, and live comparison against the newest session/SQLite quota observation. Repeated refreshes must not move the panel's update time backward.

## Non-Goals

- No change to the 60-second fallback refresh interval.
- No network request or account scraping.
- No changes to daily Token accounting, activity-ring detection, quota color bands, or panel layout.
