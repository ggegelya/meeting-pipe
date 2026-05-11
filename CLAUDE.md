# meeting-pipe — operating notes for Claude

## Shape

Personal macOS product (single-user, not for sale). Two trees:

- `daemon/` — Swift menu-bar app. Detection, recording, HUD, hotkeys.
- `pipeline/` — Python ASR + summarize + publish, invoked as `mp <subcommand>`.

`SPEC.md` is the architectural source-of-truth (the *why*). `README.md` is the
operating guide (the *how*). Edit both when behaviour or surfaces change. The Q2
backlog with task IDs like `TECH-CN` lives at `~/Downloads/meetingpipe-q2-backlog.md`.

## Verify before declaring done

| Step | Command (from repo root unless noted) |
|---|---|
| Pipeline lint | `cd pipeline && uv run --extra dev ruff check src tests` |
| Pipeline tests | `cd pipeline && uv run --extra dev pytest -q` |
| Daemon build (debug) | `cd daemon && swift build` |
| Daemon build (release) | `cd daemon && swift build -c release` |
| Daemon tests | `cd daemon && swift test` — needs full Xcode; Command Line Tools alone errors on `import XCTest`. Write tests anyway; CI (macos-14) runs them. |

**CI enforces ruff strictly** — any F401 unused import fails the pipeline job. Run
ruff locally before committing. CI config: `.github/workflows/ci.yml`. CI deliberately
installs only light deps and bypasses `uv sync` so torch/whisperx don't download; the
heavy imports live inside function bodies.

## Git workflow

- Identity for these tasks: `Georgy <g.gegelya@icloud.com>` (use `git -c user.name=Georgy -c user.email=g.gegelya@icloud.com commit ...`).
- Work directly on `main`. One logical change per commit. **Do not push** unless asked.
- Backlog-task commits: subject `TECH-CN: <short summary>`. Other commits in this repo
  follow `fix(scope): ...` / `feat(scope): ...` — match the existing style for the kind
  of change.
- **No em-dashes** in any output (code, commits, docs). Hyphens, commas, or rewrite.
- Don't add dependencies without asking first.

## Conventions worth knowing

- **Python**: stdlib first. Heavy deps (whisperx, torch, mlx-whisper, mlx-lm) are imported
  lazily inside function bodies so the CLI stays fast and CI can run without them.
- **Subcommand pattern**: one module per command at `pipeline/src/mp/<name>.py` exposing
  `def main(argv: list[str]) -> int`. Register it in `pipeline/src/mp/__main__.py` (lazy
  import + alias for the dash form). Mirror `mp logs` / `mp doctor` for shape.
- **Swift**: lift pure logic into its own type with an injected clock (`at: Date`) or a
  `decide()`-style entry point, so XCTest can drive it without AVFoundation / NSWorkspace /
  TCC. See `SignalDecision`, `SilenceDetector`.
- **Event log schema**: one JSON object per line, fields `{ts, category, action, ...attrs}`.
  Swift writes `~/Library/Logs/MeetingPipe/events.jsonl` via `Log.event(...)`; Python writes
  `pipeline_events.jsonl` via `mp.events.emit(...)`. Add new actions there, not in ad-hoc files.
- **Tests**: pytest + monkeypatch. No live HTTP. VCR cassettes exist for Notion / Anthropic.

## Out of scope (user is the only user)

Per the Q2 backlog, anything tied to **selling** is deferred: onboarding flows, license
keys, telemetry, code signing / notarization / Sparkle, landing site, marketing copy,
compliance docs. Don't add them unless a task explicitly calls for them.
