# Watch Activity from Every Codex Project

## Problem

Codex session files stay in the date directory where their task was created. A project created on July 31 can still append lifecycle events on August 3. The current watcher binds only the current calendar day's directory and files, so an older project's start or completion is invisible until the 60-second fallback refresh.

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

## Alternatives Considered

- Bind every recently modified JSONL file: smaller change, but the first write to a long-dormant project can still be missed until fallback polling.
- Poll task activity every two seconds: reliable but repeatedly enumerates session data and risks restoring the high CPU and memory use already removed.

## Tests

- Appending to a session file whose date directory is older than the current day emits a change.
- Appending to a current session file still emits a change.
- Unrelated nested files under `.codex` do not emit a change.
- Start, stop, restart, and callback-triggered stop remain safe.
- The full activity and application test suites remain green.

## Acceptance

While any Codex project is working, its lifecycle append triggers a menu-bar refresh promptly regardless of the project's creation date. When the lifecycle becomes complete or aborted, the same recursive watcher triggers the refresh that stops the ring. Idle resource use remains bounded and the 60-second fallback stays enabled.
