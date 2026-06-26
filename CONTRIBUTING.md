# Contributing to meeting-pipe

Thanks for taking a look. This is a personal macOS product (single-user, not for sale), opened up for contributor visibility. Contributions are welcome, with the bar that they keep the core honest: on-device by default, no surprises in a live recording.

## What you need

- macOS 14 or later on Apple Silicon.
- Xcode (full app, not just Command Line Tools) for the Swift daemon. `swift test` needs `import XCTest`, which CLT alone does not provide. CI runs on `macos-14`.
- [uv](https://github.com/astral-sh/uv) for the Python pipeline.
- `ffmpeg` on `PATH` for audio handling.

## Layout

Two trees:

- `daemon/` is the Swift menu-bar app (detection, recording, ASR + diarization, HUD, hotkeys).
- `pipeline/` is the Python `mp` CLI (summarize + publish), invoked as `mp <subcommand>`.

Read [`ARCHITECTURE.md`](./ARCHITECTURE.md) before non-trivial work; it has the subsystem map and the data flow. [`CONVENTIONS.md`](./CONVENTIONS.md) is the "match this" doc for code patterns, the event-log schema, and the sidecar contract.

## Build and verify

Run these before opening a PR. CI enforces ruff strictly (any unused import fails).

| Step | Command |
|---|---|
| Pipeline lint | `cd pipeline && uv run --extra dev ruff check src tests` |
| Pipeline tests | `cd pipeline && uv run --extra dev pytest -q` |
| Daemon build | `cd daemon && swift build` |
| Daemon tests | `cd daemon && swift test` (needs full Xcode) |
| Fast rebuild + relaunch | `./scripts/rebuild.sh` |

The Swift `↔` Python boundary is the meeting sidecar (`<stem>.meta.json`). If you touch it, update both `daemon/Sources/MeetingPipe/MeetingMetaSidecar.swift` and `pipeline/src/mp/workflow.py`, plus `test_workflow_overlay.py`. They are one contract.

## Conventions

- **No em-dashes** anywhere (code, commits, docs). CI fails on a U+2014 added under `daemon/Sources` or `daemon/Resources`. Use hyphens, commas, or rewrite.
- Match the existing style of files you do not own. The shared SwiftUI primitives live in `daemon/Sources/MeetingPipe/Preferences/PreferencesControls.swift`; add new primitives there rather than one-off inline styles.
- Heavy Python imports (`mlx_lm`, `soundfile`, `numpy`) go inside the function that uses them, not at module top, so `mp --help` and Linux CI stay light.
- Do not call Anthropic or Notion from the daemon. Outbound HTTP belongs in the pipeline.

## Commits and PRs

- Work on a topic branch; one logical change per commit. Do not push to `main` without asking.
- Commit with the repository's configured git identity (`git config user.name` / `user.email`). Do not hardcode a personal name or email.
- Backlog-task commits use `<ID>: <short summary>`. Other commits follow `fix(scope): ...`, `feat(scope): ...`, or `chore(scope): ...`. Match the style for the kind of change.
- The active backlog lives in [`docs/backlog/`](./docs/backlog/) (highest-numbered quarter file). Task IDs look like `E5` (no `TECH-` prefix; historical references keep the old form).

## Scope

Anything tied to selling stays deferred (onboarding flows, license keys, telemetry, code signing, landing site, marketing copy). The exception in scope this quarter is repo presence (this file, the README, repo metadata) and the app's visual identity, for contributor visibility. If a backlog task is marked P3, leave it alone unless it is explicitly promoted.
