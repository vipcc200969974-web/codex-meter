# Stop the Activity Spinner After a Task Ends

## Problem

The menu bar spinner can remain active after Codex is idle. Two observed log patterns cause this:

1. A stopped task emits `turn_aborted`, which the activity parser currently ignores.
2. The same turn can appear in more than one session file. Activity is currently tracked independently per file, so a completion in one file cannot cancel a copied start in another file.

## Chosen Design

Keep incremental, bounded log reading, but retain the latest lifecycle event for each turn instead of retaining only unmatched starts.

- Treat `task_started` as active.
- Treat both `task_complete` and `turn_aborted` as inactive terminal events.
- Within each file, keep the latest event per turn.
- Across all discovered files, merge events by turn ID and keep the newest event.
- If two lifecycle events for the same turn have the same timestamp, prefer a terminal event over a start.
- Report global activity only when at least one turn's merged latest state is `task_started`.
- Keep only lifecycle states inside the existing 24-hour horizon.

The persistent cursor cache will move to schema version 3 and store only turn ID, lifecycle kind, and timestamp. Schema version 2 is discarded and reconstructed from source logs. No prompt, response, or other private payload is cached.

## Alternatives Considered

- Shorten the activity timeout: rejected because legitimate long-running tasks could appear idle.
- Inspect only the newest session file: rejected because simultaneous tasks in other files could be missed.
- Add only `turn_aborted` parsing: insufficient because copied starts can still outlive a completion in another file.

## Tests

Add regressions proving that:

- `turn_aborted` stops an active task.
- A completion in one file overrides an older copied start in another file.
- A genuinely newer start remains active after an older terminal event.
- Equal timestamps prefer terminal state.
- Persistence preserves terminal states without storing private payload text.

Run the focused activity tests, then the complete test suite, build the app, replace the installed copy, and verify the live cache no longer retains completed or aborted turns as active.
