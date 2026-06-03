# Conventions

Patterns this codebase uses consistently. Match them rather than inventing parallel ones. For terminology, see [`GLOSSARY.md`](./GLOSSARY.md). For the subsystem map, see [`ARCHITECTURE.md`](./ARCHITECTURE.md).

---

## Cross-cutting

### Comments policy

Default to no comments. Write one only when:

- A surprising constraint isn't visible from the code (a macOS-specific quirk, a race-condition workaround, a deliberately-non-obvious choice).
- An invariant must be preserved by the reader and isn't enforced by types.

Don't write what the code does (the names already do that). Don't reference the current task (`// TECH-E5 fix`), the bug ticket, or "added by …". Those rot.

### No em-dashes

Use hyphens, commas, or rewrite. Applies to code, commit messages, docs, PR bodies, anything you produce here.

Two enforcement points, both diff-based (existing em-dashes in untouched lines aren't flagged, only newly added ones):

- CI: the `conventions` job in [`.github/workflows/ci.yml`](.github/workflows/ci.yml) fails the build on any em-dash introduced in a PR or push.
- Pre-commit (optional, local): [`scripts/pre-commit`](scripts/pre-commit) fires the same check on `git commit`. Install once with `ln -sf ../../scripts/pre-commit .git/hooks/pre-commit`.

### Commits

```
TECH-<ID>: <short summary>     # backlog tasks
fix(<scope>): <summary>        # bug fixes
feat(<scope>): <summary>       # features outside the backlog
chore(<scope>): <summary>      # tooling, docs, deps
perf(<scope>): <summary>       # perf work
test: <summary>                # test-only changes
```

One logical change per commit. Subject line is enough for most commits; add a body only when *why* isn't obvious from the subject. Body lines wrap at ~72 chars.

Git identity: commit with the repository's configured git identity (`git config user.name` / `user.email`). Do not hardcode a personal name or email.

### Logging: `Log.event` vs `Log.writeLine`

Two functions, two purposes. Don't mix them up.

| Use | When | Consumers |
|---|---|---|
| `Log.event(category:action:attributes:)` | Anything a script will grep — state transitions, lifecycle, errors with structured context. snake_case action names. | `events.jsonl`, `mp logs`, `mp analyze-detection`, the dogfood scripts. |
| `Log.writeLine(_:_:)` | Free-form narrative for a human tailing the file. Sentences, not key-value pairs. | The per-category text logs in `~/Library/Logs/MeetingPipe/<category>.log`. |
| `Log.main.info` / `.warning` / `.error` | os.Logger for the unified system log. Use sparingly; the jsonl + writeLine surfaces are usually enough. | Console.app, `log stream`. |

Most start/stop/error sites pair an event line (structured) with a writeLine (readable). Pipeline-side uses `mp.events.emit(...)` from `events.py`, same split.

### Error propagation

Throwing functions for in-module calls, `Result<T, Error>` at protocol/API boundaries. Each subsystem declares its own nested `enum X: Error, LocalizedError` (see `MeetingRecorder.RecorderError`, `PipelineLauncher.LaunchError`). There is no unified `MeetingPipeError`. `LocalizedError.errorDescription` is what the notifier surfaces, so write user-facing strings there.

### Test file naming

`<TypeUnderTest>Tests.swift` in `daemon/Tests/MeetingPipeTests/`. One test file per production type that has logic worth unit-testing. Suite class is `final class <TypeUnderTest>Tests: XCTestCase`. Pure-logic tests don't import AVFoundation / NSWorkspace — see the "Testability via clock and decision injection" pattern in Swift section.

Pipeline-side: `test_<module>.py` next to the module under `pipeline/tests/`.

### Dependencies

Don't add packages without asking. The dependency surface is deliberately small. Same for tools (don't pull in a new linter, formatter, or test runner).

---

## Swift — `daemon/`

### Testability via clock and decision injection

Pure logic lives in its own type with explicit inputs (a `Date`, a `Bool`, a function pointer) so XCTest can drive it without AVFoundation, NSWorkspace, or TCC. Examples in repo:

- `SilenceDetector.SilenceDecision` — `decide(at: Date, micRMS:, systemRMS:) → Action` with no AVAudioEngine dependency. Test feeds synthetic RMS sequences.
- `MicGate.decide(state:)` - pure precedence over the fused mute signals, no AX or CoreAudio dependency.
- `WorkflowMatcher.match(source:workflows:)` — pure function, full unit coverage.

When a subsystem grows non-trivial conditional logic, lift the decision into a `decide(…)`-style entry point on its own type before adding the next branch.

### Lazy properties and `Self.`

```swift
// Wrong — fails on Swift 5.9+ "covariant 'Self' in stored property initializer".
private var icon = Self.makeIcon(size: Self.size)

// Right — fully-qualified class name.
private var icon = StatusBarController.makeIcon(size: StatusBarController.size)
```

The `lazy var` form (`private lazy var icon = …`) avoids the error too but defers init past the constructor — only use lazy when that's actually what you want.

### `ObservableObject` + Combine

- `@Published` properties auto-fire `objectWillChange`. Wire subscribers via Combine on `didPersist` / dedicated PassthroughSubjects rather than `objectWillChange` directly — fewer spurious rebuilds.
- Debounce writes (see `ConfigStore.scheduleSave` — 500 ms via `Timer.scheduledTimer`).
- Round-trip TOML through `TOMLTable` so unknown keys survive (`ConfigStore.rawDocument`). Don't model fields you don't need.

### Status bar / menu rebuilds

Build the menu once per state transition, not per property change. Filter Combine streams to actual value changes (`removeDuplicates`) before triggering `rebuildMenu`. The 2 s permission poll was previously rebuilding the menu twice a second; see the snapshot dedupe in `StatusBarController.init`.

### Tests need full Xcode

`swift test` from the command line errors on `import XCTest` if only Xcode Command Line Tools are installed. CI runs on `macos-14` with full Xcode. Write tests anyway; verify locally with the Xcode test runner, or `swift test` once full Xcode is set as the active developer dir (`sudo xcode-select -s …`).

---

## Python — `pipeline/`

### Stdlib first

Reach for `pathlib`, `dataclasses`, `argparse`, `subprocess`, `json` before pulling in a dep. The pipeline ships pydantic for schemas, anthropic + httpx for the API, mlx-lm for the local-summary backend, and soundfile + numpy for the channel-aware speaker fallback. That is it.

### Lazy heavy imports

Top-of-file imports stay stdlib + light deps. The heavier imports the pipeline still has (`mlx_lm` for the local-summary backend, `soundfile` and `numpy` for the channel-aware speaker fallback in `diarize.py`) live *inside* the function that uses them:

```python
def summarize(self, transcript: str) -> MeetingSummary:
    from mlx_lm import load  # heavy; defer until the local backend runs
    ...
```

Why: `mp --help` and `mp logs` shouldn't pay an import cost they do not need. Linux CI installs only a light dep set and bypasses `uv sync`, relying on these lazy boundaries to not blow up.

### Subcommand pattern

Each `mp <name>` lives in `pipeline/src/mp/<name>.py` exposing `def main(argv: list[str]) -> int`. Register in `pipeline/src/mp/__main__.py` with both the dash-form and snake-case alias:

```python
if cmd in {"my-cmd", "my_cmd"}:
    from .my_cmd import main as run
    return run(rest)
```

Use `argparse` inside `main`; don't share argparse instances across modules.

### Test discipline

- pytest + monkeypatch. No live HTTP, no network sockets.
- VCR cassettes live next to the test file (`tests/cassettes/`) for replaying Notion / Anthropic interactions. Re-record only when the upstream API changes.
- Services depend on `Protocol`s from `services.py`. Tests inject in-memory fakes, not vendor SDK mocks.

### Ruff is strict in CI

```bash
cd pipeline && uv run --extra dev ruff check src tests
```

Any F401 (unused import) fails CI. Run locally before committing. Config in `pipeline/pyproject.toml`.

---

## Event log schema

Two append-only JSONL files at `~/Library/Logs/MeetingPipe/`:

- `events.jsonl` — written by the daemon via `Log.event(category:action:attributes:)` in `Logger.swift`.
- `pipeline_events.jsonl` — written by the pipeline via `mp.events.emit(category, action, **attrs)` in `events.py`.

Every line is one JSON object with at least three fields:

```jsonc
{
  "ts": "2026-05-14T15:32:01.234Z",   // ISO8601 with millisecond precision, UTC
  "category": "coordinator",          // see below
  "action": "recording_started",
  // ...arbitrary JSON-serializable attributes
  "bundle_id": "us.zoom.xos",
  "summary_mode": "auto",
  "workflow_id": "0ac61f12-…"
}
```

### Categories

| Source | Categories |
|---|---|
| Daemon (`Log.event` / `EventLog.emit`) | `axbus`, `coordinator`, `correction`, `detector`, `doctor`, `halbus`, `library`, `lifecycle`, `main`, `micgate`, `recorder`, `signal`, `transcription`, `workflow` |
| Pipeline (`mp.events.emit`) | `pipeline`, `publisher` |

### Adding a new action

1. Pick the right category (don't invent one unless you're adding a new subsystem).
2. Use snake_case for the action (`recording_started`, not `RecordingStarted`).
3. Add it directly via `Log.event(...)` / `events.emit(...)`. There's no central registry.
4. If the pipeline's `mp logs` filter or `mp analyze-detection` cares about it, update them too.

### Non-serializable attributes

- Swift: a non-serializable value silently drops the event (per `Logger.swift`). Convert to a string / dict before passing.
- Python: `default=str` coerces silently rather than dropping. Same outcome: don't pass raw objects, convert first.

The principle is: a missing event line is preferable to a crashed daemon or a corrupted file. Don't add try/except scaffolding around emit calls.

---

## Sidecar schema (`<stem>.meta.json`)

Written by `MeetingMetaSidecar.build` in Swift, read by `mp.workflow.apply_overrides` in Python. **Both sides must agree.** Adding a key on one side without the other silently breaks the contract.

Current keys (May 2026):

| Key | Type | Notes |
|---|---|---|
| `source_bundle_id` | string | `"us.zoom.xos"` |
| `source_display_name` | string | `"Zoom"` |
| `source_kind` | `"native"` \| `"browser"` | influences end-detection probe |
| `meeting_title` | string? | best-effort from window title |
| `workflow_id` | UUID string | |
| `workflow_name` | string | |
| `workflow_color` | hex string | UI tint, not behavioural |
| `workflow_emoji` | string? | |
| `workflow_context_prompt` | string | injected into summarization system prompt |
| `workflow_backend` | (`"anthropic"` \| `"local"` \| `"auto"` \| `"apple_intelligence"`)? | per-workflow override; omitted when the workflow inherits the global default, so a global `apple_intelligence` setting stays reachable |
| `workflow_sinks` | array of strings | subset of `["notion", "obsidian", "filesystem"]` |
| `workflow_notion_database_id` | string? | per-workflow Notion DB |
| `workflow_nda_mode` | bool | forces backend=local + sinks=filesystem |
| `regulated_mode` | bool? | global zero-egress at record time (TECH-DSN6); top-level (not under a workflow), written only when true. Drives the Library "Local only" badge and is folded into the overlay fail-closed, same effect as `workflow_nda_mode` |

Absence of the sidecar (`<stem>.meta.json` missing) is valid — the pipeline falls back to global config + LLM-derived title.

---

## Backlog and task delegation

The active backlog lives in `docs/backlog/`: the highest-numbered `meetingpipe-q<N>-backlog.md` (currently `meetingpipe-q4-backlog.md`), with earlier quarters archived beside it. Task IDs follow `TECH-<letter><number>` (`TECH-C2`, `TECH-E5`, …). When marking a task done, prefix the line with `[DONE] ` rather than deleting it, so the trail of decisions stays readable.

The delegation section at the top of the active backlog is the canonical entry contract. The `/tech-task` slash command in `.claude/commands/tech-task.md` is the codified version of it.

---

## What NOT to do

- Don't pull pipeline-side logic into the daemon (or vice versa). They communicate via `<stem>.meta.json` and `events.jsonl`, not in-process.
- Don't add fields to `MeetingMetaSidecar.swift` without also updating `mp.workflow.apply_overrides` and its test (`test_workflow_overlay.py`).
- Don't add Anthropic or Notion calls in the daemon. The daemon stays offline; outbound HTTP is the pipeline's job.
- Don't introduce a new TOML section without round-trip test coverage in `ConfigStoreTests` — the unknown-keys-survive guarantee depends on `ensureTable` working for fresh sections.
- Don't bypass `Log.event`. Ad-hoc print / log statements break `mp logs` and `mp analyze-detection`.
