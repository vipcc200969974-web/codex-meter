# Codex task activity spinner design

Date: 2026-08-02

## Goal

Add an always-visible task-state indicator to the right side of the existing Codex Meter menu-bar quota tag. When any local ChatGPT/Codex task is running, the indicator rotates. When no task is running, the same indicator remains visible and stops rotating.

The feature must remain local-only, compact, low-power, and visually consistent with the existing quota tag.

## Approved menu-bar appearance

The menu-bar tag keeps its existing quota and reset text, then adds a second divider and a custom activity ring:

```text
64% | 6d0h | ◌
```

- The quota and reset text remain unchanged.
- The new divider appears after the reset time.
- Divider spacing is 5 points on both sides.
- The activity ring is 12.5 points in diameter so its visual height matches the 12-point menu-bar text.
- The ring uses a 1.5-point rounded stroke and the same foreground color as the quota text.
- The tag keeps 6 points of trailing space after the ring.
- The divider is 9 points high at 35% foreground opacity so it separates without dominating.

The ring is an incomplete custom-drawn circle whose gap makes rotation visible. While active it rotates at 12 frames per second and one revolution per second. When activity stops, the timer is invalidated and the ring freezes at its current angle. On an idle launch it uses a stable top-facing angle.

The entire tag remains one clickable status item and continues to open the existing panel.

## Activity semantics

“Active” means at least one local ChatGPT/Codex turn has emitted a structured `task_started` event without a matching `task_complete` event.

- Activity is global across all local ChatGPT/Codex tasks, not limited to the currently visible task.
- Multiple simultaneous turns are tracked independently by `turn_id`.
- The ring keeps rotating until the last active turn completes.
- A `task_complete` event only removes its matching `turn_id`.
- A started turn older than 24 hours is treated as stale and inactive. This prevents a crash or forcibly terminated task from leaving the ring spinning forever.

## Local data source and privacy

The activity provider reads the same local roots already watched by Codex Meter:

```text
~/.codex/sessions
~/.codex/archived_sessions
```

It recognizes only complete JSONL records whose top-level type is `event_msg` and whose structured payload type is `task_started` or `task_complete`. It decodes only the lifecycle type, `turn_id`, and lifecycle timestamp needed to determine state.

Prompt text, replies, reasoning, tool arguments, authentication data, and unrelated event payloads are not decoded, retained, displayed, or uploaded. No network request is introduced. The persistent cursor cache contains only file identity, complete-line offsets, SHA-256 generation fingerprints, lifecycle type, turn identifier, and timestamp; it never contains raw JSONL bytes or partial lines.

## Architecture and data flow

### `CodexTaskActivityProvider`

A dedicated provider owns lifecycle parsing and incremental file state.

1. Discover JSONL candidates in active and archived session roots.
2. Treat a never-tracked archived file as definitively stopped, while continuing to follow a cached active file that moves into the archive.
3. Deduplicate moved or archived copies by stable file identity, with rollout basename as a fallback.
4. Read only bytes appended after each validated complete-line cursor, using bounded chunks.
5. Use a narrow raw discriminator before typed decoding so unrelated records are skipped without materializing their payloads.
6. Maintain the latest lifecycle state for each `turn_id`.
7. Return `isActive == true` when at least one non-stale turn remains started.

On first launch without a valid cursor cache, the provider rebuilds lifecycle state from active-session files modified within the 24-hour activity horizon. A cold rebuild or incremental refresh accepts at most 256 MiB of unread bytes per file and 512 MiB of unread bytes in aggregate; validated historical offsets do not consume that budget. Exceeding either unread bound makes that refresh unavailable rather than publishing a partial false-active result. A refresh reads the metadata-approved snapshot and leaves bytes appended during that read for the next refresh. File replacement, truncation, active-to-archive moves, and incomplete trailing lines must not duplicate or lose lifecycle events. SHA-256 samples at the beginning and validated boundary detect same-identity truncate-and-rewrite generations without persisting source bytes.

### `UsageStore`

`UsageStore` gains independently published task activity state while preserving the existing quota/token snapshot semantics.

- The existing filesystem watcher triggers activity refreshes along with quota and token refreshes.
- The existing 800 ms debounce remains the normal event path.
- The existing 60-second fallback refresh also rechecks task activity.
- Task activity failure does not mark quota or token data stale.
- A transient activity read failure retains the last known value for one 60-second fallback interval; a second consecutive failure publishes idle so the ring cannot spin indefinitely.

### `AppDelegate` and `CompactStatusItemView`

The app delegate updates the status view whenever either the usage snapshot or activity state changes.

`CompactStatusItemView` receives `isTaskActive` in addition to the existing title, colors, and tooltip. It calculates the expanded intrinsic width, draws the second divider and ring, and owns a main-run-loop animation timer that exists only while active. State transitions are idempotent so repeated active updates do not create duplicate timers.

The tooltip adds either `ChatGPT 正在执行任务` or `当前无运行任务`. The activity drawing also exposes the same state through accessibility text.

## Failure behavior

- Missing session roots are a legitimate idle first-run state.
- Traversal, metadata, or read failures do not publish partially reconstructed activity.
- Malformed, non-lifecycle, timestamp-less, or identifier-less events are ignored.
- An incomplete final JSONL line is retained only in memory until it becomes complete and is never persisted.
- A cache whose identity, offset, day horizon, or generation fingerprint cannot be validated is discarded and rebuilt.
- After an app or task crash, the 24-hour lifecycle expiry guarantees eventual idle state even if no completion event was written.

## Testing and acceptance criteria

Implementation uses test-driven development and must cover:

- parsing valid `task_started` and `task_complete` records;
- rejecting unrelated/private, malformed, timestamp-less, and identifier-less records before broad decoding;
- one active turn, matching completion, and multiple simultaneous turns;
- ignoring completion for a different turn;
- 24-hour stale-start expiry;
- incremental append without double counting;
- incomplete-line completion, truncation, replacement, move, archive deduplication, and restart cache validation;
- missing roots versus traversal/read failures;
- exact 800 ms watcher debounce and 60-second fallback behavior;
- timer starts once while active, stops on idle, and stays stopped during repeated idle updates;
- layout math for text, divider spacing, 12–13 point ring, and trailing padding;
- tooltip and accessibility state text.

Acceptance requires the full Swift test suite, release build, plist validation, installation to `/Users/cc/Applications/Codex Meter.app`, process-path verification, login-item verification, and a visual check of both rotating and stopped states.

## Out of scope

- Showing task names, prompt text, thread titles, or task counts.
- Network or official API polling.
- Changing quota calculation, token aggregation, panel contents, refresh intervals, or notification behavior.
- Creating a second independent menu-bar item.
