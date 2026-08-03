# Watch Activity from Every Codex Project

## Problem

Codex session files stay in the date directory where their task was created. A project created on July 31 can still append lifecycle events on August 3. The current watcher binds only the current calendar day's directory and files, so an older project's start or completion is invisible until the 60-second fallback refresh.

There is a second delay after an event is detected: `LocalUsageLoader` reads quota and token data before activity, and `UsageStore` publishes all three only after the combined load finishes. A slow full refresh can therefore delay the ring even when the filesystem event arrived promptly.

## Chosen Design

Replace the date-specific session file bindings with one native recursive FSEvents stream rooted at `~/.codex`.

- Request per-file events and filter paths before scheduling a refresh.
- Refresh for `.jsonl` files below `sessions` or `archived_sessions`.
- Refresh for `logs_2.sqlite`, its WAL, and its shared-memory companion so quota updates continue to work.
- Ignore unrelated `.codex` changes, including source, memory, and configuration writes.
- Coalesce filesystem events through the existing 0.8-second `UsageStore` debounce.
- Preserve callback-safe `start`, `rebind`, and `stop` behavior.
- Keep the existing 60-second fallback as recovery for missed or unavailable filesystem events.

This uses one recursive stream instead of one file descriptor per active file. It detects writes for old and new projects without frequent directory scans or faster polling.

Add an activity-only loading path alongside the existing combined usage load:

- `LocalUsageLoader` exposes a fast method that calls only `CodexTaskActivityProvider`.
- `UsageStore` runs that method on a separate serial queue at startup, after watcher events, and after wake or unlock.
- Activity-only loads have their own debounce, in-flight, and pending state so they never wait for quota or token work and never overlap themselves.
- The existing combined refresh still updates quota and daily tokens; the fast result only updates `isTaskActive` and its success timestamp.
- Test loaders that do not implement the activity-only interface keep their existing behavior.

The 15-minute orphan lease must use the newer of the unmatched start timestamp and its session file's modification time, but file liveness applies only when that start is the file's latest lifecycle event. A long-running task therefore stays active while its project log continues changing, even when the original start is older than 15 minutes. A newer terminal event prevents unrelated old starts in the same file from being revived. A terminal lifecycle event still wins globally and stops immediately; a genuinely abandoned start becomes idle only when both the start and its source file have been quiet for longer than the lease.

## Alternatives Considered

- Bind every recently modified JSONL file: smaller change, but the first write to a long-dormant project can still be missed until fallback polling.
- Poll task activity every two seconds: reliable but repeatedly enumerates session data and risks restoring the high CPU and memory use already removed.
- Reorder activity to the start of the combined load: parsing would happen earlier, but the UI still could not publish it until quota and token work returned.

## Tests

- Appending to a session file whose date directory is older than the current day emits a change.
- Appending to a current session file still emits a change.
- Unrelated nested files under `.codex` do not emit a change.
- Start, stop, restart, and callback-triggered stop remain safe.
- A watcher event publishes activity while an intentionally blocked full usage load is still running.
- Burst watcher events produce one activity-only follow-up rather than concurrent activity scans.
- A start older than 15 minutes remains active when its session file was modified recently, while an equally old quiet file remains idle.
- A recent file write cannot revive an older unmatched start when that file's latest lifecycle event is terminal.
- The full activity and application test suites remain green.

## Acceptance

While any Codex project is working, its lifecycle append triggers an activity-only menu-bar refresh promptly regardless of the project's creation date or the duration of quota and token loading. When the lifecycle becomes complete or aborted, the same path stops the ring. Idle resource use remains bounded and the 60-second fallback stays enabled.
