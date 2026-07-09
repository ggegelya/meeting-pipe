# Conventions

Patterns this codebase uses consistently. Match them rather than inventing parallel ones. For terminology, see the [Glossary](./ARCHITECTURE.md#glossary). For the subsystem map, see [`ARCHITECTURE.md`](./ARCHITECTURE.md).

---

## Cross-cutting

### Comments policy

Default to no comments. Write one only when:

- A surprising constraint isn't visible from the code (a macOS-specific quirk, a race-condition workaround, a deliberately-non-obvious choice).
- An invariant must be preserved by the reader and isn't enforced by types.

Don't write what the code does (the names already do that). Don't reference the current task (`// E5 fix`), the bug ticket, or "added by …". Those rot.

### No em-dashes

Use hyphens, commas, or rewrite. Applies to code, commit messages, docs, PR bodies, anything you produce here.

Two enforcement points, both diff-based (existing em-dashes in untouched lines aren't flagged, only newly added ones):

- CI: the `conventions` job in [`.github/workflows/ci.yml`](.github/workflows/ci.yml) fails the build on any em-dash introduced in a PR or push.
- Pre-commit (optional, local): [`scripts/pre-commit`](scripts/pre-commit) fires the same check on `git commit`. Install once with `ln -sf ../../scripts/pre-commit .git/hooks/pre-commit`.

### Commits

```
<ID>: <short summary>          # backlog tasks
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

### Secrets (macOS Keychain, SEC8)

The API tokens (`ANTHROPIC_API_KEY`, `NOTION_TOKEN`, plus optional `HF_TOKEN`) live in the macOS login Keychain, not a file. Three trees touch the same items and must agree on the naming:

- Swift daemon: `KeychainSecrets` / `SecretsStore` (reads at startup + on each Preferences save).
- Python pipeline: `mp.config.load_secrets` / `_keychain_get`.
- `scripts/install.sh` (prompt + migrate a legacy `secrets.env`) and `scripts/uninstall.sh --purge` (delete).

Contract: generic-password items, **service `com.meetingpipe.daemon`**, **account = the env-var name**. Every tree shells out to `/usr/bin/security` (never the native `SecItem` API), so a single stable accessor owns the item ACL: no per-access Keychain prompt, no per-rebuild cdhash churn.

```sh
security add-generic-password -U -s com.meetingpipe.daemon -a ANTHROPIC_API_KEY -w <value>
security find-generic-password    -s com.meetingpipe.daemon -a ANTHROPIC_API_KEY -w
security delete-generic-password  -s com.meetingpipe.daemon -a ANTHROPIC_API_KEY
```

The daemon seeds the tokens into its process env at launch + on each Preferences save, so pipeline subprocesses inherit them with no per-spawn secret read; a hand-run `mp` reads the Keychain directly. The pipeline egress guard stays the authoritative zero-egress backstop, so a token stripped from a subprocess env for a regulated/NDA run and re-read here still cannot egress.

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
| `schema_version` | int | sidecar shape version (CI2), currently `1`. Stamped on every non-empty sidecar; the reader is fail-open on it (unknown values are ignored, not rejected). Bump when the key set or a key's semantics change |

Absence of the sidecar (`<stem>.meta.json` missing) is valid — the pipeline falls back to global config + LLM-derived title.

A golden-fixture contract test pins these keys across both suites (CI2): three committed sidecar shapes in `daemon/Tests/MeetingPipeTests/Fixtures/meta-contract/` are built and verified by `MetaContractFixtureTests` (Swift) and read through `apply_overrides` by `test_workflow_overlay.py` (Python). A key rename on either side breaks one suite, so drift can't pass CI unnoticed.

---

## Flagged-moment markers (`<stem>.markers.json`)

The moments the user flagged mid-recording with the flag-moment hotkey (FEAT8). A Swift-to-Python surface like `<stem>.meta.json`, but simpler. `MarkerFile.write` (Swift) writes it at stop, and two readers consume it: the pipeline (`mp.markers`, where the transcript segments spanning each marker become user-flagged excerpts fed to the summarizer and listed in the BYO / long-meeting paste bundles) and the Library transcript tab (`MarkerFile.read`, rendering anchor chips that seek). Shape:

```json
{ "schema_version": 1, "markers": [ { "t_seconds": 42.5 } ] }
```

`t_seconds` is the offset in seconds from recording start, the same clock the transcript segments use. Written only when at least one moment was flagged, so an unflagged meeting leaves no sidecar. Both sides are fail-open: a missing or malformed file yields no flagged moments, never an error. Capture is deterministic (the daemon stamps offsets, the pipeline maps them to segments); the emphasis is model-side (a trusted system-prompt instruction), so a flag adds no new egress class, the excerpts travel to whichever backend already summarizes the transcript.

---

## Daemon-internal recording artifacts

Four artifacts the daemon both writes and reads. Unlike `<stem>.meta.json`, none is part of the Swift-to-Python contract: the redactor and orphan recovery consume them before any pipeline run, so the pipeline never reads them directly (recovery does *rebuild* `<stem>.meta.json` from the manifest below). The MIC4/MIC5 capture-first work introduced the first three; REC2 added the recovery manifest. Documented here per DOC6.

**`<stem>.mute-timeline.json`** (TECH-MIC4), next to `<stem>.wav`. The muted spans the offline redactor (TECH-MIC5) zero-fills, written at stop only under capture-first-redact (an opt-in workflow). Shape:

```json
{ "version": 1, "spans": [ { "start_sec": 1.5, "end_sec": 3.2 } ] }
```

Seconds from recording start, half-open `[start_sec, end_sec)`. Only genuine app/hardware-mute spans are recorded, never `silentByRMS` (quiet) or `uncertain`, so redaction can never drop quiet-but-real speech. Written by `MuteTimelineFile.write`, read by `MuteRedactor`, and reaped after a successful redaction. Absent for default capture-first, regulated, and pre-MIC4 recordings.

**`<stem>.capturemode`** (TECH-MIC5 review), next to `<stem>.wav`. A one-line plain-text marker written at recording **start** so orphan recovery, after a crash where `stop()` never ran, can still apply the right privacy posture. One token (`CaptureMode.marker`): `capture_first`, `capture_first_redact`, or `regulated_gate`. Read by `OrphanRecordingRecovery.shouldQuarantine` (a capture-first-redact orphan with no timeline is quarantined, not auto-published). Removed at a clean stop that produced a final.

**`<stem>.recovery.json`** (REC2), next to `<stem>.wav`. The start-time identity manifest: it persists the routing intent a crash would otherwise lose, so the orphan sweep never auto-egresses a BYO / NDA / regulated meeting that was interrupted mid-call. Written at recording **start** by `RecordingManifest.write`, shape:

```json
{ "schema_version": 1, "summary_mode": "auto" | "byo", "meta": { /* the MeetingMetaSidecar.build payload */ } }
```

`summary_mode` routes the recovered enqueue (a `byo` orphan produces a paste bundle, not an Anthropic+Notion auto-summary); `meta` is replayed into a rebuilt `<stem>.meta.json` (skipped if one already exists) so the pipeline arms its egress guard for an NDA / regulated orphan and keeps the meeting title. Read by `OrphanRecordingRecovery.recover`. Removed at a clean stop that produced a final (kept, like `.capturemode`, when the merge failed so the next-launch sweep can still route it). Absent for pre-REC2 orphans, which recover on the legacy `.auto` default.

**`originals/<stem>.wav`** (ADR 0016), in `~/Library/Application Support/MeetingPipe/originals/`, NOT in the recordings dir. The kept full (un-redacted) recording, moved aside when `MuteRedactor` redacts the canonical `<stem>.wav`, and the quarantine destination for capture-first-redact orphans whose timeline was lost. Deliberately outside the Library-scanned `raw/` tree and the Raw Files tab's reach: mode `0600`, excluded from Time Machine and iCloud. The redacted artifact is what every consumer reads; this is the recovery source only. ADR 0016's mandated retention policy + reaper ships as `OriginalsReaper` (age + size bounded: 30 days / ~10 GB, reaped at launch and after each pipeline job), and meeting deletion cascades into it via `MeetingLibraryService.softDeleteMeeting` (MIC13).

`schema_version` (CI2): `<stem>.meta.json` and every JSON sidecar writer that lacked one now stamp `schema_version: 1` (the `<stem>.error.json` failure sidecar and the pipeline publish receipts `<stem>.notion.json` / `.obsidian.json` / `.filesystem.json` / `.lan.json` / `.run.json` / `.empty.json` / `.apple_pending.json`). Two deliberate exceptions: `<stem>.mute-timeline.json` already carries its own `version: 1` (above), and `<stem>.summary.json` is the pydantic `MeetingSummary` data schema rather than a marker sidecar, so it is versioned through the model, not a stamp.

---

## Audio retention (STOR1)

**The recording's extension is not a constant.** A meeting's final recording is `<stem>.wav` as the recorder wrote it, `<stem>.flac` after a `compress` retention policy has run, or absent entirely after a `drop` policy. `MeetingStore.finalRecordingExtensions` is the single list, `MeetingStore.finalRecordingURL(stem:in:)` the single resolver, and `Meeting.audioURL` is `URL?` so the compiler forces every audio affordance to handle absence. Don't reconstruct `"\(stem).wav"` by hand. The one exception is `MeetingStore.sidecarAnchorURL(stem:in:)`, for the two callers (`mp roster enroll --wav`, `PipelineLauncher.appleContext`) that only derive sibling sidecar paths from the URL and never open it.

FLAC and not AAC, because `diarize.py` reads channels through `soundfile` (libsndfile), which decodes FLAC and not AAC: a lossy transcode would make a retried or regenerated meeting unreadable to the pipeline, on top of being irreversible in an archive.

**`[retention]` in `~/.config/meeting-pipe/workflows/<uuid>.toml`.** Written by `WorkflowStore.encode`, read by `.decode`. The table is **omitted entirely** while the workflow keeps its audio forever, so a workflow that never opted in stays byte-unchanged on disk:

```toml
[retention]
policy = "keep" | "compress" | "drop"
after_days = 30
```

Two fail-safes, because the policy deletes irreplaceable audio: a missing table decodes to `keep`, and so does a `policy` value this build doesn't recognise (one a newer build wrote).

**One reaper, two scopes.** `Coordinator.reapStorage()` runs at launch and after every pipeline job, off-main, and calls two sweeps that share a scheduler and the `coordinator` event category but not an algorithm. `OriginalsReaper` is bounded-cache eviction over `originals/` (age, then oldest-first under a byte ceiling). `AudioRetentionSweep` applies each workflow's policy to settled meetings in `raw/`, deciding through the pure `AudioRetention.decide`. Neither ever touches the live recording.

A meeting is eligible only when **settled**: `.done` and not a member of the Library's `Needs you` scope. `AudioRetention.isSettled` and `LibraryScope.needsYou.includes` have to agree, and a test pins that. A meeting whose workflow carries no policy, whose workflow was deleted, or which has no workflow at all keeps its audio forever.

`compress` writes `<stem>.flac.writing`, moves it into place, reopens it with `AVAudioFile` and compares durations, and only then deletes the WAV. Every failure path leaves the WAV untouched. The waveform peaks cache is keyed on the stem but validated on the recording's size + mtime, so a transcode invalidates it in place; `drop` and `softDeleteMeeting` purge it outright, since nothing will re-derive it.

Events: `audio_compressed`, `audio_dropped`, `audio_retention_swept` (category `coordinator`).

---

## Speaker enrollment (FEAT3-VOICEPRINT / FEAT3-ROSTER)

Speaker enrollment learns voices so "me vs them" holds on the mono / merged recordings where the stereo mic-channel trick can't, and recurring named people surface by name. Four artifacts:

**`speaker_embeddings`** on the draft `<stem>.json`. The daemon (`FluidAudioRunner`) writes a 256-d L2-normalized embedding per diarized speaker (a duration-weighted mean of that speaker's per-segment embeddings), keyed by the diarization speaker id. It rides the transcript sidecar but is **transient**: `orchestrate._finalize_streamed_transcript` pops it (voiceprint enroll/match + roster match), then strips it from the final `<stem>.json` and re-persists it keyed by final label to `<stem>.embeddings.json` (below). So it never reaches the Library-facing transcript. Omitted when diarization produced no speakers.

**`<stem>.embeddings.json`** next to `<stem>.wav`: `{schema_version: 1, embeddings: {<final label>: [256 floats]}}`. The per-meeting per-speaker embeddings, keyed by the FINAL label the transcript shows (the "me" name, a roster name, or a `THEM-A` cluster) so the Library naming affordance can look up a speaker's embedding by the label it renames. Read by `mp roster enroll`, which folds the named speaker's embedding into the roster and relabels the transcript. Persists after the run (post-meeting naming needs it). Not read by the Library directly.

**`voiceprint.json`** at `~/.config/meeting-pipe/voiceprint.json`, sibling of `config.toml`. The pipeline-owned running-average self-voiceprint: `{schema_version: 1, embedding: [256 floats], meetings: N}`. `mp.voiceprint.VoiceprintStore` writes it (auto-enrolls from the mic-channel user of stereo recordings, capped after a few meetings) and `mp.diarize.match_voiceprint` reads it to identify "me". The daemon reads it **read-only** for the Preferences "Voice profile" status + Reset (`VoiceprintProfile`); not part of the `<stem>.meta.json` contract, but display-only surfacing of shared per-user state, like the daemon reading `config.toml`.

**`roster.json`** at `~/.config/meeting-pipe/roster.json`: `{schema_version: 1, people: [{name, samples, centroids}]}`. Named third-party voiceprints: each person keeps a capped set of enrolled sample embeddings reduced to up to three k-means centroids. `mp.roster.RosterStore` matches a speaker to a name with a two-gate rule (top cosine >= 0.65 AND runner-up margin >= 0.07, biasing to leave-unknown over a wrong name); `mp roster enroll/list/forget` manage it, and `orchestrate` applies matches at finalize (`diarize.resolve_speaker_labels`: unmatched voices become stable `THEM-A/B` clusters). The daemon triggers enrollment (Library "Name this speaker") by spawning `mp roster enroll`; it does not read roster.json directly.

---

## Backlog and task delegation

The active backlog lives in `docs/backlog/`: the highest-numbered `meetingpipe-q<N>-backlog.md` (currently `meetingpipe-q6-backlog.md`), with earlier quarters archived beside it. Task IDs follow `<letter><number>` (`C2`, `E5`, …); the `TECH-` prefix was dropped from the active backlog and the `/tech-task` command, and historical code/ADR references keep the old form as provenance. When marking a task done, set its `Status` column to `done` in the Table of contents (the sadok six-column form Q6 adopted, with Status split out from Priority) rather than deleting the row, so the trail of decisions stays readable; a shipped item rolls into the next `q<N>-final.md` archive at the quarter roll.

The delegation section at the top of the active backlog is the canonical entry contract. The `/tech-task` slash command in `.claude/commands/tech-task.md` is the codified version of it.

---

## What NOT to do

- Don't pull pipeline-side logic into the daemon (or vice versa). They communicate via `<stem>.meta.json` and `events.jsonl`, not in-process.
- Don't add fields to `MeetingMetaSidecar.swift` without also updating `mp.workflow.apply_overrides` and its test (`test_workflow_overlay.py`).
- Don't add Anthropic or Notion calls in the daemon. The daemon stays offline; outbound HTTP is the pipeline's job.
- Don't introduce a new TOML section without round-trip test coverage in `ConfigStoreTests` — the unknown-keys-survive guarantee depends on `ensureTable` working for fresh sections.
- Don't bypass `Log.event`. Ad-hoc print / log statements break `mp logs` and `mp analyze-detection`.
