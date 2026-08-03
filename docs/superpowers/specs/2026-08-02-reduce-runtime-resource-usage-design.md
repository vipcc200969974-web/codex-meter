# Reduce Codex Meter Runtime Resource Usage

## Problem

Codex Meter can consume nearly one CPU core and hundreds of megabytes of memory while Codex is active. Live profiling on 2026-08-02 showed:

- sustained CPU between 55% and 100%;
- a 596 MB physical footprint with a 1.1 GB peak;
- 3,759 of 3,759 sampled background stack entries inside `CodexSessionQuotaProvider`;
- approximately 228 MB of eligible session JSONL data being scanned during one quota refresh;
- file-system activity scheduling another refresh while the current scan is still running.

The recent quota-regression repair correctly made readable session files available again, but `CompositeQuotaProvider.currentObservation` eagerly calls every provider with `flatMap`. Therefore the expensive session fallback runs even when the lightweight SQLite provider has already returned a valid Codex quota.

## Approaches Considered

1. **Use providers lazily in priority order.** Query SQLite first and return its valid observation without invoking the session provider. Invoke the session provider only if SQLite has no current supported quota. This removes the unnecessary scan from the normal path and keeps the existing fallback.
2. **Build a persistent incremental session-quota index.** Track offsets and latest quota records for every session file. This would also reduce fallback cost, but adds cache versioning, truncation handling, file-identity tracking, and recovery behavior.
3. **Increase debounce and fallback intervals.** This reduces how often the scan runs but makes quota, Token, and task activity visibly slower while retaining large periodic CPU and memory spikes.

Approach 1 is selected because the SQLite log contains the same server response headers used by Codex, is already ordered and bounded by its query, and matched the current 52% quota during diagnosis. It removes the measured hot path without changing refresh responsiveness or adding persistent state.

## Design

### Lazy provider priority

`CompositeQuotaProvider.currentObservation(now:)` evaluates providers in their configured order. For each provider it obtains that provider's observations and calls the existing `merge` function on those observations only. It returns the first valid `QuotaObservation` and does not invoke later providers.

The production order remains:

1. `CodexLogQuotaProvider` backed by `~/.codex/logs_2.sqlite`;
2. `CodexSessionQuotaProvider` backed by active and archived JSONL files.

If SQLite is missing, unreadable, contains no authentic Codex quota header, or contains no supported unexpired window, `merge` returns `nil` and the session provider remains available as the fallback. `UsageStore` keeps the existing recency barrier, so an older fallback result cannot replace a newer published or cached quota.

### Unchanged behavior

- Keep the 0.8-second file-event debounce and 60-second fallback refresh.
- Keep daily Token and task-activity incremental providers unchanged.
- Keep the menu-bar ring animation, quota colors, panel layout, and login item unchanged.
- Do not delete or rewrite any Codex session records.
- Do not add a network request or scrape account pages.

## Testing

Add provider-level tests using real protocol implementations with synchronized invocation counters:

- when the first provider returns a valid supported quota, the second provider is not invoked;
- when the first provider returns no valid quota, the second provider is invoked and its quota is returned.

The first test must fail against the eager `flatMap` implementation because the fallback invocation count is one. After the minimal lazy-selection change, run the focused tests and the full Swift suite.

Build and install the signed application, restart it to release memory retained by the previous repeated scans, and verify on the live Mac:

- Codex Meter's displayed quota matches the newest Codex SQLite header;
- the quota timestamp never moves backward across repeated refreshes;
- CPU averages below 5% after launch settles;
- physical memory remains below 150 MB without sustained growth during at least two fallback intervals.

## Non-Goals

- No redesign of `CodexSessionQuotaProvider`'s fallback scanner in this change.
- No reduction in visual animation frame rate unless profiling later identifies it as material.
- No merge, push, or pull request without separate user authorization.
