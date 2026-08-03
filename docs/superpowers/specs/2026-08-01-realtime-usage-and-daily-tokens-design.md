# Real-Time Quota Refresh and Daily Token Usage Design

Date: 2026-08-01  
Status: Approved

## Problem

Codex Meter currently refreshes on launch, when the panel opens, after wake or unlock, and on a fixed 60-second timer. The quota records themselves are written promptly after a Codex response, but the timer can leave the menu bar showing the previous value for almost one minute.

The current snapshot also stores `Date()` as its update time. That tells the user when Codex Meter scanned the files, not when Codex produced the quota record. A stale quota can therefore look newly updated.

The app does not show how many tokens Codex has processed today. Local session JSONL files already contain structured `token_count` events with total, input, cached-input, output, and reasoning-output values, so this can be calculated without reading conversation content or making a network request.

## Goals

- Update quota and token usage within 1-3 seconds of a normal Codex log write.
- Keep a 60-second fallback poll so a missed file-system event cannot leave the UI stale indefinitely.
- Show today's complete token total and a clear breakdown of cached input, non-cached input, output, and reasoning output.
- Show a proportional composition bar for cached input, non-cached input, and output.
- Define “today” using the Mac's current local calendar and time zone. On this Mac that is Asia/Shanghai.
- Preserve the compact menu-bar title and keep all processing local.
- Retain the last valid snapshot during a temporary read or parse failure.

## Non-goals

- Calling an OpenAI or other network API.
- Treating inferred quota as an official billing or entitlement value.
- Converting tokens into money.
- Adding configurable daily token budgets, historical charts, or a full settings screen.
- Reading, displaying, indexing, or uploading prompts, model replies, attachments, or authentication data.

## Chosen Approach

Use file-system events as the primary refresh trigger and keep the existing 60-second timer as a fallback. A short debounce coalesces the several writes commonly produced by one Codex response.

The alternative of polling every 10 seconds was rejected because it repeatedly scans unchanged files and is still visibly delayed. Refreshing rapidly only while the panel is open was rejected because the menu-bar value would remain slow while the panel is closed.

## Architecture

### `CodexActivityWatcher`

This component owns lightweight native file-system watchers. It observes:

- `~/.codex/logs_2.sqlite-wal` when present;
- the parent `~/.codex` directory so the WAL can be rebound after creation, deletion, or rotation;
- the current session directories and active JSONL files under `~/.codex/sessions`;
- `~/.codex/archived_sessions` for a session that is moved while the app is running.

Use `DispatchSourceFileSystemObject` with `O_EVTONLY` descriptors. On `.write` or `.extend`, request a debounced refresh. On `.rename`, `.delete`, or a new session file, close stale descriptors, rediscover the active paths, and bind new watchers.

The debounce interval is 800 milliseconds. The watcher never parses files itself; it only reports that local usage data may have changed.

### `UsageRefreshCoordinator`

This component serializes refresh work and prevents events from being lost:

1. A watcher event, manual refresh, panel opening, wake/unlock notification, or fallback timer requests a refresh.
2. Requests arriving inside the debounce window are combined.
3. If a refresh is already running, set `refreshPending` instead of dropping the request.
4. When the current refresh finishes, immediately run one more refresh if `refreshPending` is set.
5. Publish the completed quota and token values as one `UsageSnapshot` on the main actor.

All file and SQLite reads remain off the main thread. The existing 60-second timer remains active as a recovery path, not the normal update mechanism.

### Quota providers and selection

The SQLite header provider and JSONL session provider return observations that include the source record timestamp. They no longer construct a snapshot with the current scan time.

The composite provider merges supported windows by window kind:

- Prefer the observation with the newer source timestamp.
- When two observations describe the same reset window, do not allow a newer transient lower `used_percent` to regress the visible usage; keep the highest valid observation for that reset window.
- When the reset timestamp changes, treat it as a new quota window and use the newer observation.
- Continue to reject model-specific limits and unsupported or expired windows.

The UI's “updated” text uses the selected source observation time. The time at which Codex Meter scanned the files remains internal.

### `DailyTokenUsageProvider`

Only structured lines whose `payload.type` is `token_count` are parsed. Conversation events and their contents are ignored.

For every event inside the current local calendar day, read `payload.info.last_token_usage` and accumulate:

- `totalTokens` from `total_tokens`;
- `cachedInputTokens` from `cached_input_tokens`;
- `nonCachedInputTokens` as `max(input_tokens - cached_input_tokens, 0)`;
- `outputTokens` from `output_tokens`;
- `reasoningOutputTokens` from `reasoning_output_tokens`.

Reasoning output is a subset of output and is displayed as an annotation. It is not added to the total or the composition bar a second time.

At startup, scan the current day's relevant session files once and rebuild the aggregate. While running, keep a byte offset and partial-line buffer per file, then parse only newly appended complete lines. If a file is truncated, rotated, or moved, discard the invalid offset and rebuild that file safely. File discovery deduplicates a session by its rollout filename so a move into `archived_sessions` cannot double-count it.

At the next local start of day, clear the aggregate, discard prior-day offsets, discover the new day's files, and publish a zero-value daily snapshot. `Calendar.autoupdatingCurrent` handles a system time-zone change.

### `UsageSnapshot`

Quota and daily token data are combined into one value before publication. This prevents the panel from briefly showing a new quota with old token numbers or the reverse.

The snapshot contains:

- selected quota windows;
- quota observation time and source label;
- today's `DailyTokenUsage`;
- the token aggregate's latest event time;
- a freshness state used to distinguish live, stale, and unavailable data.

## Data Flow

```text
Codex writes SQLite WAL / session JSONL
                  |
                  v
        CodexActivityWatcher
                  |
           800 ms debounce
                  |
                  v
       UsageRefreshCoordinator
          /                 \
         v                   v
  quota providers    daily token provider
         \                   /
          v                 v
             UsageSnapshot
                  |
                  v
         menu bar + popover
```

## User Interface

### Menu bar

Keep the existing compact quota-only title, for example:

```text
61% | 4d0h
```

Today's token count is not added to the menu bar because it would make the permanent status item too wide.

### Popover

Keep the current 360-point card width and increase the height only enough to add a second compact surface below the quota surface.

Conceptual layout:

```text
本机日志 · 刚刚更新              ↻  ···

61%                               4d0h
7 天剩余                       8月5日恢复
[ quota remaining progress bar        ]

今日 Token                       798.6万
[ cached | non-cached | output         ]
缓存 748.6万 · 非缓存 46.8万 · 输出 3.2万
推理 0.8万（已包含在输出中）
```

The token composition bar uses exact proportions:

- cached input: light blue;
- non-cached input: purple;
- output: orange.

Reasoning output is not a separate segment because it is already included in output. Small segments are allowed to be visually small; the numeric legend remains the authoritative way to read them.

Token counts use a compact Chinese formatter:

- below 10,000: grouped integer;
- 10,000 and above: one decimal place in `万`;
- 100,000,000 and above: one decimal place in `亿`.

The header shows the real source-record time. If no event has occurred today, the token surface says `今日暂无使用` and displays an empty composition bar.

## Failure Handling

- A watcher setup or rebind failure does not stop the app; the 60-second fallback timer continues.
- An incomplete JSONL line is buffered until the terminating newline arrives.
- Malformed or unrelated lines are skipped without invalidating the rest of the file.
- A temporary SQLite or JSONL read failure keeps the previous valid snapshot and marks it stale instead of replacing it with zero or unavailable data.
- A manual refresh bypasses the debounce delay but still goes through the serialized refresh coordinator.
- Sleep, wake, and session activation cause immediate refresh and watcher rebinding.
- If both quota sources are unavailable and no cached value exists, retain the current unavailable state.
- A local-day rollover clears only daily token usage; quota windows remain intact.

## Testing

### Token aggregation tests

- Sum complete `last_token_usage` events inside one local day.
- Exclude events before local midnight and at or after the next midnight.
- Calculate non-cached input without double-counting cached input.
- Keep reasoning output inside output and outside the composition total.
- Ignore malformed, unrelated, and incomplete lines.
- Resume a partial line after the next append.
- Rebuild correctly after file truncation, rotation, and application restart.
- Deduplicate a rollout moved from sessions to archived sessions.
- Reset at the next local start of day.

### Quota selection tests

- Prefer the newer valid observation from SQLite or JSONL.
- Preserve the highest usage for the same reset window.
- Accept a lower value when the reset timestamp identifies a new window.
- Preserve weekly-only support and all existing adaptive-window behavior.
- Confirm the displayed update time comes from the source record.

### Refresh coordination tests

- Coalesce a burst of watcher events into one refresh.
- Queue exactly one follow-up refresh when an event arrives during a read.
- Verify manual, wake, panel-open, and fallback triggers use the same coordinator.
- Verify a watcher failure leaves fallback polling active.

### UI model tests

- Format total and breakdown values at integer, `万`, and `亿` boundaries.
- Produce exact composition fractions for cached input, non-cached input, and output.
- Show the empty state for zero daily usage.
- Keep the menu-bar title unchanged by token usage.

All existing quota tests must continue to pass. Tests use synthetic temporary logs and databases; they do not read real prompts or other private session content.

## Acceptance Criteria

- After a complete quota or `token_count` record is written under normal local load, the menu bar and open panel update within 1-3 seconds.
- A missed watcher event is corrected by the 60-second fallback poll.
- Repeated writes from one response do not cause overlapping refreshes.
- Today's total equals the sum of today's `last_token_usage.total_tokens` events across active and archived sessions.
- Cached input, non-cached input, and output add up to the displayed total when the source fields are internally consistent.
- The UI never counts reasoning output twice.
- The app restarts into the correct current-day total and resets at local midnight.
- The last valid values remain visible during temporary read failures and are visibly marked stale.
- No network request, third-party dependency, or private conversation-content parsing is introduced.
