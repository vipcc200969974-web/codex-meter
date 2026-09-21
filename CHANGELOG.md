# Changelog

## [Unreleased]

### Added
- Initial open-source hardening pass for project metadata.
- Added contribution and security docs (`CONTRIBUTING.md`, `SECURITY.md`).

### Changed
- Removed mock quota fallback so the app now prefers real local session-derived quotas.
- Menu bar now displays unavailable state when no quota record is available.

## [0.1.2] - 2026-09-21

### Changed
- Published the lightweight memory-optimized build with the latest quota refresh and menu-bar fixes.

## [0.1.1] - 2026-08-04

### Changed
- Token log usage now reads in bounded 1 MiB chunks and aggregates events as they arrive.
- Large session files no longer need to be loaded into memory in one operation.
- Added regression coverage for multi-megabyte logs and file growth during refresh.

## [0.1.0] - 2026-07-09

- Initial release scaffold with 5-hour and weekly quota meter, menu bar status text, and popover panel.
- Local-only inference from `.codex/sessions` logs.
- Optional periodic voice broadcast and low-quota notifications.
- DMG packaging script.
