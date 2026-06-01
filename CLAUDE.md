# meeting-pipe — operating notes for Claude

## Shape

Personal macOS product (single-user, not for sale). Two trees:

- `daemon/`: Swift menu-bar app. Detection, recording, ASR + diarization (FluidAudio), HUD, hotkeys.
- `pipeline/`: Python summarize + publish, invoked as `mp <subcommand>`.

## Orientation — read these when relevant

| File | When to read |
|---|---|
| [`ARCHITECTURE.md`](./ARCHITECTURE.md) | Where code lives. Subsystem map + data flow + key invariants. Read before non-trivial work. |
| [`CONVENTIONS.md`](./CONVENTIONS.md) | Swift + Python patterns + event-log schema + sidecar contract. The "match this" doc. |
| [`GLOSSARY.md`](./GLOSSARY.md) | Project terms (workflow, lockon, BYO, regulated, sidecar, RMS fallback, …). Skim when a term is unfamiliar. |
| [`SPEC.md`](./SPEC.md) | Architectural *why*. Read when the question is "why is it shaped this way?" |
| [`README.md`](./README.md) | Operating guide (the *how*). Edit when user-visible behaviour or surfaces change. |
| `daemon/CLAUDE.md` | Auto-loads when you touch Swift. Short Swift-specific gotchas. |
| `pipeline/CLAUDE.md` | Auto-loads when you touch Python. Short Python-specific gotchas. |

The active backlog lives in [`docs/backlog/`](./docs/backlog/): the highest-numbered `meetingpipe-q<N>-backlog.md` (currently `meetingpipe-q4-backlog.md`; earlier quarters are archived beside it). Task IDs look like `TECH-E5`. The `/tech-task TECH-<ID>` slash command is the codified delegation contract.

## Verify before declaring done

| Step | Command (from repo root unless noted) |
|---|---|
| Pipeline lint | `cd pipeline && uv run --extra dev ruff check src tests` |
| Pipeline tests | `cd pipeline && uv run --extra dev pytest -q` |
| Daemon build (debug) | `cd daemon && swift build` |
| Daemon build (release) | `cd daemon && swift build -c release` |
| Daemon tests | `cd daemon && swift test` — needs full Xcode; Command Line Tools alone errors on `import XCTest`. Write tests anyway; CI (macos-14) runs them. |
| Fast rebuild + relaunch | `./scripts/rebuild.sh` — for live-testing daemon changes against a running install. |

CI enforces ruff strictly (any F401 unused import fails). Run ruff locally before committing. CI deliberately installs only light deps and bypasses `uv sync` so torch / whisperx / mlx don't download; the heavy imports live inside function bodies (see `pipeline/CLAUDE.md`).

## Git workflow

- Commit with the repository's configured git identity (`git config user.name` / `user.email`). Do not hardcode a personal name or email in commits, code, or docs.
- Work directly on `main`. One logical change per commit. **Do not push** unless asked.
- Backlog-task commits: subject `TECH-<ID>: <short summary>`. Other commits follow `fix(scope): …` / `feat(scope): …` / `chore(scope): …` — match the existing style for the kind of change.
- **No em-dashes** in any output (code, commits, docs). Hyphens, commas, or rewrite. Match the existing style of files you don't touch.
- Don't add dependencies without asking first.

## Quick reference

- **Where things live:** `ARCHITECTURE.md` "Where files live on disk" table.
- **Event log schema + adding actions:** `CONVENTIONS.md#event-log-schema`.
- **Sidecar (`<stem>.meta.json`) schema:** `CONVENTIONS.md#sidecar-schema-stem-metajson`. Swift writer and Python reader both have to agree — touch both sides + `test_workflow_overlay.py`.
- **Verbose run:** `MP_VERBOSE=1` is exported when `UISettings.verboseLogging` is on; the daemon also logs an info line at startup so you can confirm.

## Out of scope (user is the only user)

Anything tied to **selling** stays deferred: onboarding flows, license keys, telemetry, code signing / notarization / Sparkle, landing site, marketing copy, compliance docs. Don't add them unless a task explicitly calls for them. If the backlog marks a task **P3**, leave it alone. One exception, promoted in the q4 backlog: GitHub repo presence (README, LICENSE, repo metadata) and the app's visual identity are in scope, for contributor visibility.

## Memory hygiene

Worth saving as project memory across sessions: durable user preferences (commit style, no-em-dash), backlog-wide decisions (skip P3 entirely, …), surprising codebase facts that hurt to relearn.

Not worth saving: file paths (read `ARCHITECTURE.md`), git log state, the current branch's in-progress work (use a plan, not memory), anything in the doc set above (it's authoritative; memory drifts).
