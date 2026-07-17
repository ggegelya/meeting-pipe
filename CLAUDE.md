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
| [`ARCHITECTURE.md#glossary`](./ARCHITECTURE.md#glossary) | Project terms (workflow, lockon, BYO, regulated, sidecar, RMS fallback, …). Skim when a term is unfamiliar. |
| [`docs/decisions/`](./docs/decisions/) + README [Why it is shaped this way](./README.md#why-it-is-shaped-this-way) | Architectural *why* (ADRs are the long form, the README section the short). Read when the question is "why is it shaped this way?" |
| [`README.md`](./README.md) | Operating guide (the *how*). Edit when user-visible behaviour or surfaces change. |
| [`PRODUCT.md`](./PRODUCT.md) | Strategic UX context: register, users, brand personality (local-first, quiet, deliberate), anti-references, design principles, a11y floor. Read before any UI work or design judgement call. |
| [`design/`](./design/) | Visual system: `colors_and_type.css` (tokens), `README.md` (voice + visual rules + iconography), `ui_kits/macos_app/` (JSX recreations of surfaces). The "match this" doc for chrome. |
| `daemon/CLAUDE.md` | Auto-loads when you touch Swift. Short Swift-specific gotchas. |
| `daemon/Sources/MeetingPipeCore/CLAUDE.md` | Auto-loads inside the Core target. The island rules (strict concurrency, dependency floor, pure `decide()`). |
| `pipeline/CLAUDE.md` | Auto-loads when you touch Python. Short Python-specific gotchas. |

The active backlog lives in [`docs/backlog/`](./docs/backlog/): the highest-numbered `meetingpipe-q<N>-backlog.md` (currently `meetingpipe-q6-backlog.md`; earlier quarters are archived beside it) holds the index table and process rules, and each task's full spec lives in `docs/backlog/tasks/<ID>.md`. Task IDs look like `E5` (no `TECH-` prefix; historical code/ADR references keep the old `TECH-` form as provenance). The `/tech-task <ID>` slash command is the codified delegation contract; `/file-task` is its intake mirror (dedupe, next free ID, band, ToC row + `tasks/<ID>.md` spec, one commit); `/spike <ID>` ships the probe-first spike shape (analysis doc + owner-run read-only probe, verdict thresholds pre-registered); `/audit` runs the multi-angle assessment (parallel finders, adversarial verification of critical/high findings, owner-gated filing).

## Verify before declaring done

| Step | Command (from repo root unless noted) |
|---|---|
| Pipeline lint | `cd pipeline && uv run --extra dev ruff check src tests` |
| Pipeline typecheck | `cd pipeline && uv run --extra dev pyright` — pyright basic over `src/` (TYPE1); CI fails on a type regression |
| Pipeline tests | `cd pipeline && uv run --extra dev pytest -q` |
| Daemon build (debug) | `cd daemon && swift build` |
| Daemon build (release) | `cd daemon && swift build -c release` |
| Daemon tests | `cd daemon && swift test` — needs full Xcode; Command Line Tools alone errors on `import XCTest`. Write tests anyway; CI (macos-14) runs them. |
| Fast rebuild + relaunch | `./scripts/rebuild.sh` — for live-testing daemon changes against a running install. |

CI enforces ruff strictly (any F401 unused import fails). Run ruff locally before committing. CI deliberately installs only light deps and bypasses `uv sync`, so the darwin/arm64-only packages (`mlx-lm`, `mlx-embeddings`) and the heavy `soundfile` / `numpy` pair never download on the Linux runner; their imports live inside function bodies (see `pipeline/CLAUDE.md`). ASR and diarization moved to Swift/FluidAudio long ago; there is no torch or whisperx in this repo.

## Git workflow

- Commit with the repository's configured git identity (`git config user.name` / `user.email`). Do not hardcode a personal name or email in commits, code, or docs.
- Work directly on `main`. One logical change per commit. **Do not push** unless asked.
- Backlog-task commits: subject `<ID>: <short summary>` (e.g. `FEAT3-ROSTER: ...`). Other commits follow `fix(scope): …` / `feat(scope): …` / `chore(scope): …`. Match the existing style for the kind of change.
- **No em-dashes** in any output (code, commits, docs). Hyphens, commas, or rewrite. Match the existing style of files you don't touch.
- Don't add dependencies without asking first.

## Quick reference

- **Where things live:** `ARCHITECTURE.md` "Where files live on disk" table.
- **Event log schema + adding actions:** `CONVENTIONS.md#event-log-schema`.
- **Sidecar (`<stem>.meta.json`) schema:** `CONVENTIONS.md#sidecar-schema-stem-metajson`. Swift writer and Python reader both have to agree — touch both sides + `test_workflow_overlay.py`.
- **Publish result (`<stem>.publish.json`) + the exit-3 contract:** `CONVENTIONS.md#publish-result-stempublishjson`. Python writes, Swift reads. An all-sinks-failed publish exits 3, never 0.
- **Verbose run:** `MP_VERBOSE=1` is exported when `UISettings.verboseLogging` is on; the daemon also logs an info line at startup so you can confirm.

## Out of scope (user is the only user)

Anything tied to **selling** stays deferred: onboarding flows, license keys, telemetry, code signing / notarization / Sparkle, landing site, marketing copy, compliance docs. Don't add them unless a task explicitly calls for them. If the backlog marks a task **P3**, leave it alone. One exception, promoted in the q4 backlog: GitHub repo presence (README, LICENSE, repo metadata) and the app's visual identity are in scope, for contributor visibility.

## Memory hygiene

Worth saving as project memory across sessions: durable user preferences (commit style, no-em-dash), backlog-wide decisions (skip P3 entirely, …), surprising codebase facts that hurt to relearn.

Not worth saving: file paths (read `ARCHITECTURE.md`), git log state, the current branch's in-progress work (use a plan, not memory), anything in the doc set above (it's authoritative; memory drifts).
