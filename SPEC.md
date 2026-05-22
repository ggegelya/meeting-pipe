# meeting-pipe — Spec

The full design document lives in this file. The README documents how to use
and operate the system; this file documents *why* it's shaped the way it is.

> Source of truth for any implementation question. If the code disagrees with
> this spec, fix the code (or update the spec — but don't let them drift).

---

## 1. Goals & non-goals

### Goals
- Detect meeting start across Zoom, Teams, Slack huddles, Google Meet, Webex
  (native + browser).
- Prompt to record with a notification — single click to start.
- Auto-stop on meeting end, notify when ready.
- Preconfigured output location for raw audio.
- On-device transcription with speaker diarization.
- Summary + extracted action items pushed to Notion.
- Manual hotkey override always available.

### Non-goals
- Video capture.
- Real-time live transcript display.
- Team / multi-user sharing.
- Cross-platform.
- Mobile companion.

---

## 2. Stack

| Layer            | Choice                                          | Why |
|------------------|-------------------------------------------------|-----|
| Daemon           | Swift menu-bar app, no Dock icon                | Native NSWorkspace, AVCaptureDevice KVO, UNUserNotificationCenter. |
| System audio     | ScreenCaptureKit (`SCStream` w/ `capturesAudio = true`) | Apple-recommended since macOS 13. No aggregate devices, no BlackHole, no ffmpeg subprocess. Excludes our own process audio so notifications don't loop back. |
| Microphone       | `AVAudioEngine.inputNode`                        | Auto-tracks the macOS default input. User changes input in System Settings ▸ Sound → next recording adapts. |
| Mixing + write   | `AVAudioEngine` + `AVAudioFile`                  | In-process. Mic and system audio are written as a stereo WAV (mic left, system right) so diarization and silent-system detection stay possible; see ADR 0009. |
| ASR              | FluidAudio (Parakeet TDT), Apple Neural Engine   | Swift-native, runs in the daemon after the recording stops. No Python ASR process. Replaced mlx-whisper (TECH-P1/P2). |
| Diarization      | FluidAudio (pyannote-community-1), Apple Neural Engine | Swift-native, runs alongside ASR in the daemon. Replaced sherpa-onnx (TECH-P3). `mp.diarize` keeps a channel-aware speaker fallback for the rare FluidAudio miss. |
| Summarization    | Anthropic Messages API direct, Claude Sonnet 4.6 | Headless, deterministic, structured outputs via tool-use schema. **Not Claude Code** — Claude Code is interactive; an unattended pipeline calls the API directly. |
| Publishing       | Notion REST API + integration token              | Robust unattended; idempotent; testable. **Not Notion MCP** — MCP is for interactive Claude. |
| Glue             | Python 3.11, single CLI with subcommands          | Each step debuggable in isolation. |
| Build            | Swift Package Manager + uv (Python)              | Reproducible. |

---

## 3. Architecture

The daemon (`MeetingPipe.app`, Swift) owns detection, recording, and
on-device transcription end to end. The Python pipeline is a short-lived
subprocess that only summarizes and publishes.

Flow: the `MeetingPipeCore` lifecycle subsystem detects the meeting and
drives the `Coordinator` state machine. `MeetingRecorder` captures the mic
(`AVAudioEngine`) plus system audio (ScreenCaptureKit) into a stereo WAV,
with `MicGate` deciding per buffer whether the mic channel is audible. On
Stop, `SinkDispatcher` runs FluidAudio ASR + diarization on-device, then
spawns `mp run-all`, which summarizes and publishes.

Recording and transcription are both in-process in the daemon; the Python
pipeline runs out-of-process so summarize + publish does not block the
daemon. See [`ARCHITECTURE.md`](./ARCHITECTURE.md) for the subsystem map
and sequence diagrams.

---

## 4. State machine

```
IDLE
  │  (lifecycle verdict: meeting started, debounced)
  ▼
PROMPTING ──(timeout / "Skip")──> SUPPRESSED ──(lifecycle verdict: ended)──> IDLE
  │
  │  (user: "Record" or auto-consented bundle)
  ▼
RECORDING
  │  (lifecycle verdict: meeting ended)
  │  (or user: hotkey / "Stop")
  ▼
STOPPING ─(recorder flushed)─> IDLE
                                 │
                                 │  (concurrently, does not block recording)
                                 ▼
                          ProcessingJobs queue (FIFO)
                                 │  FluidAudio transcribe, then `mp run-all`,
                                 │  one job at a time; a new meeting can start
                                 │  recording at any point
                                 ▼
                          notification on done
```

`.handoff` used to be a state; it lived inside `AppState` and blocked the
daemon from starting a new recording while the previous transcription was
running. It now lives in a separate `ProcessingJob` queue on `Coordinator`
so recording stays unblocked while jobs run in the background.

---

## 5. Detection logic

Detection is the `MeetingPipeCore` lifecycle subsystem. It replaced the
old two-signal `Detector` in TECH-C13. See [`ARCHITECTURE.md`](./ARCHITECTURE.md)
for the subsystem map; this section is the *why*.

### Verdict fusion, not a single signal

A meeting recorder cannot trust one signal. A meeting app being open does
not mean a call is live; the mic being held does not survive the user
joining muted; a window title can flicker. So the lifecycle subsystem
fuses several signals per meeting client into one `MeetingLifecycleVerdict`
(`.idle`, `.starting`, `.inMeeting`, `.endingProvisional`, `.ended`).

PRIMARY signals: per-process audio activity, ScreenCaptureKit
shareable-content windows, and the Accessibility "Leave" button.
`PromotionEngine` is the pure fusion rule: a signal raises a provisional
verdict, and a second corroborating signal or a debounce confirms it.
Each meeting client (Teams, Zoom, Webex, Slack, browser) has an adapter
that wires the right signals with locale-tolerant window-title patterns.

### Start-side scoring

A user can have Teams open for chat while actually in a Google Meet tab,
so start detection does not take the first matching app. `MeetingSourceScanner`
enumerates every concurrent candidate, `MeetingSourceScorer` scores each on
"I am in a meeting" evidence (calling-controls toolbar, leave / mute
buttons, process audio, window title), and the strongest candidate wins.
Once a recording starts the attribution is locked; it is not re-evaluated
mid-call.

### Mute-aware capture

`MicGate`, the per-buffer mute verdict-fusion subsystem, decides whether
the recorded mic channel carries audio or zero-amplitude frames, so the
transcript does not contain the user's voice while they are muted in the
meeting client. The system mix is always recorded in full.

### Silence safety nets

`SilenceDetector` watches mic + system RMS during a recording and fires a
"Still meeting?" notification, then an auto-stop, after sustained silence.
`MicOnlySilenceBackstop` force-stops a recording that has been mic-only and
silent past a configured window (`mic_only_silence_seconds`, default 480).
Both catch the case where end detection missed and the user walked away.

### Manual override

Two global hotkeys, both configurable in Preferences. Manual record
(default `⌃⌥M`) toggles recording: idle starts, recording stops. Force stop
(default `⌃⌥⇧M`) only stops a running recording, so it can never accidentally
start one. Force stop is logged via the `coordinator.force_stop` event.

---

## 6. Repo layout

```
meeting-pipe/
├── README.md  SPEC.md  ARCHITECTURE.md  CONVENTIONS.md  GLOSSARY.md
├── config.example.toml
├── daemon/                          Swift menu-bar app
│   ├── Package.swift                two targets: MeetingPipe + MeetingPipeCore
│   ├── Sources/MeetingPipe/         app target: Coordinator + state machine,
│   │                                recording, transcription, workflows, all UI
│   ├── Sources/MeetingPipeCore/     library target: the Lifecycle and MicGate
│   │                                verdict-fusion subsystems, plus Infra
│   └── Tests/                       MeetingPipeTests + MeetingPipeCoreTests
├── pipeline/                        Python `mp` CLI: summarize + publish only
│   ├── pyproject.toml  uv.lock
│   ├── src/mp/                      one module per subcommand (run-all,
│   │                                summarize, publish-*, doctor, logs,
│   │                                dogfood, corrections-stats, analyze-detection)
│   └── tests/
├── scripts/                         install.sh, rebuild.sh, uninstall.sh, dev tools
└── docs/                            decisions/ (ADRs), test-coverage.md
```

[`ARCHITECTURE.md`](./ARCHITECTURE.md) carries the per-file subsystem map and
is kept current as code moves; treat it as the accurate index.

---

## 7. Configuration

See [`config.example.toml`](./config.example.toml) for the live default. The
file is copied to `~/.config/meeting-pipe/config.toml` on install. Secrets
live separately in `~/.config/meeting-pipe/secrets.env` (mode 0600) — never
written to TOML.

```env
ANTHROPIC_API_KEY=sk-ant-...
NOTION_TOKEN=ntn_...
```

Daemon and pipeline both source `secrets.env` on startup.

---

## 8. Permissions

| Permission       | Why                                                                | Granted via                          |
|------------------|--------------------------------------------------------------------|--------------------------------------|
| Microphone       | `AVAudioEngine.inputNode` — captures user voice                    | First launch prompt                  |
| Screen Recording | `SCStream.capturesAudio` — gates system-audio capture in TCC        | System Settings → Privacy & Security |
| Accessibility    | Lifecycle detection reads the Leave button and window titles; MicGate reads the meeting client's Mute button | System Settings, Privacy & Security |
| Notifications    | Prompts and completion alerts                                       | First launch prompt                  |

macOS TCC keys these grants on the bundle id (`com.meetingpipe.daemon`).
A reinstall reuses the same bundle id, so a previously-denied grant
stays denied across reinstalls. Use `scripts/uninstall.sh --reset-tcc`
(or `--all`) to reset Microphone / ScreenCapture / Accessibility /
AppleEvents / SystemPolicyAllFiles for the bundle so the next install
re-prompts cleanly.

---

## 8.4. Performance: on-device transcription

ASR and diarization run in the Swift daemon via FluidAudio (Parakeet TDT
for ASR, pyannote-community-1 for diarization), both on the Apple Neural
Engine. `SinkDispatcher` runs them after the recorder closes the WAV, then
spawns `mp run-all` for summarize + publish.

This replaced an earlier Python streaming pipeline (`mp transcribe-stream`,
mlx-whisper, sherpa-onnx) in TECH-P1 through TECH-P4. The Swift / ANE path
is fast enough that a streaming-during-the-call architecture was no longer
worth its complexity: transcription now happens once, after Stop, on the
canonical merged WAV. The Python pipeline no longer transcribes at all,
which is why it ships no torch / whisperx dependency.

Long meetings still skip the Anthropic call above
`summarization.skip_above_chars` (see section 11).

---

## 8.5. Multilingual support

| Stage | Multilang behavior |
|---|---|
| ASR (FluidAudio / Parakeet TDT) | Parakeet TDT v3 is multilingual; quality on the user's languages was validated in the TECH-P0 benchmark (`bench/parakeet-vs-whisperx/`). Runs on the Apple Neural Engine in the daemon. |
| Diarization (FluidAudio / pyannote) | Language-agnostic. Speaker identity is acoustic, not lexical, so it transfers across languages with no per-language model. |
| Summarization | The Anthropic prompt detects the transcript language and writes the summary in that same language by default. `summarization.summary_language` in config can force a specific output language regardless. |
| Notion title | Inherits the summary language (or, when present, the meeting-name sidecar from the daemon — that name lives in whatever the source app exposed). |

Code-switched calls (e.g. UA/EN, RU/EN): Whisper picks the dominant
language; the summary follows.

---

## 9. Summarization schema (locked-in)

See `pipeline/src/mp/schemas.py`. Pydantic models:

```python
class ActionItem(BaseModel):
    task: str
    owner: str | None
    due: str | None              # ISO date if extractable
    confidence: Literal["low", "medium", "high"]

class MeetingSummary(BaseModel):
    title: str                   # ≤120 chars
    summary: list[str]           # ≤5 bullets, ≤30 words each
    decisions: list[str]         # explicit commitment language only
    actions: list[ActionItem]
    questions: list[str]         # unresolved
    attendees: list[str]
    detected_language: str       # ISO 639-1
```

Enforced via Anthropic tool-use with `tool_choice` forcing exactly one call to
`emit_meeting_summary`. The system prompt
(`pipeline/src/mp/prompts/meeting_summary.md`) forbids invented action items
and includes the configured `team_context` so domain terms aren't misclassified.

---

## 10. Risks & open decisions

| Risk                                                          | Mitigation |
|---------------------------------------------------------------|------------|
| A single detection signal misfires (app open but no call, title flicker) | The lifecycle subsystem fuses several signals per client via `PromotionEngine`; no lone signal starts or ends a recording. |
| Native meeting-app title format drift (Teams/Zoom UI rename)        | Title patterns live in the per-app lifecycle adapters and `meeting_apps.toml`, not compiled constants. The detection corpus (TECH-C6) replays captured traces to catch regressions. |
| Browser tab title patterns drift                                    | Patterns in TOML, not compiled. Easy to tweak. |
| Diarization quality variance per language                           | FluidAudio's pyannote model is acoustic and language-agnostic; a channel-aware fallback in `mp.diarize` covers a hard FluidAudio miss on a stereo recording. |
| Apple Silicon requirement                                           | FluidAudio runs on the Apple Neural Engine; the daemon is Apple-Silicon, macOS 14+ only by design. There is no Intel fallback. |
| Long meetings burning Anthropic tokens silently                     | `summarization.skip_above_chars` (default 80 000) writes a manual-processing bundle instead of calling the API. |
| Anthropic API cost creep                                            | ≈$0.05/meeting on Sonnet 4.6 at typical 5k in / 2k out. Local backend (P2) brings it to $0. |
| Compliance for client/regulated calls                               | `regulated_mode=true` skips Notion. Pair with `summarization.backend = "local"` for full zero-egress (test_summarize_backend locks this in). |
| Local model output drifts from JSON schema                          | 3-layer extractor in `summarize_local._extract_summary` (raw / fenced / largest balanced object) + a corrective retry that replays with the Pydantic error in-context. Failure surfaces as `LocalSummaryError`, not a silent bad summary. |
| Local model quality varies by call                                  | `mp dogfood <transcript.md>` runs Anthropic + local side-by-side and writes a hand-fillable scorecard. `mp dogfood --report` aggregates and gates the ship decision (≥80% capture, ≤5% hallucination). Today's read on the default Qwen2.5-14B-4bit: not ship-ready (see the dogfood report). |
| TCC permission stuck in "denied" after reinstall                    | `uninstall.sh --reset-tcc` (or `--all`) clears Microphone / ScreenCapture / Accessibility / AppleEvents per bundle id so the next install re-prompts cleanly. |

---

## 11. Long-meeting guard

The Anthropic API charges per token. A 1+ hour meeting can produce a
transcript that runs many tens of thousands of tokens, which is real money
to summarize automatically. To avoid that:

- After the daemon's FluidAudio transcription produces `<stem>.md`, the
  orchestrator checks `len(md) > summarization.skip_above_chars` (default
  `80000` ≈ 20 000 tokens ≈ ~1 hour of speech).
- On hit: stages 2 and 3 are skipped. Anthropic and Notion are not called.
- A sidecar `<stem>.READY_FOR_MANUAL.md` is written. It contains:
  - A short header explaining what's going on.
  - The path to the transcript (so the user can attach it).
  - The exact system prompt that the pipeline would have used (copied from
    `pipeline/src/mp/prompts/meeting_summary.md`).
- The user pastes both into Claude Code (or any LLM frontend) and processes
  the meeting locally. No API charges.
- Setting `summarization.skip_above_chars = 0` disables the guard.

---

## 12. Definition of done

- All phases merged with green CI.
- README walks a fresh user from clone to first auto-published Notion page.
- LaunchAgent loaded; survives logout/login.
- Uninstall script leaves no residue when run with `--purge`.

---

## 13. Summarization backend selection

`summarization.backend` (TOML) selects which `SummaryClient` the
pipeline builds for the summarize stage. Three modes:

| Mode | Selector returns | Network behaviour | When to use |
|---|---|---|---|
| `"anthropic"` | `AnthropicSummaryClient` | Calls `api.anthropic.com`. Requires `ANTHROPIC_API_KEY`. | Default. Best output today. |
| `"local"` | `LocalSummaryClient` | Lazy-spawns `mlx_lm.server` on `http://127.0.0.1:8765`; never calls Anthropic. | Privacy-first / regulated meetings. |
| `"auto"` | `_AutoFallbackClient` wrapper | Tries Anthropic, falls back to Local on `APIConnectionError` / `APITimeoutError` / `AuthenticationError` / `PermissionDeniedError` or missing key. | Resilience for offline laptops. |

The pipeline reads the TOML fresh per `mp` invocation, so a backend
flip via the Preferences → Pipeline tab takes effect on the next
recording without a daemon restart.

`LocalSummaryClient` lifecycle ([`summarize_local.py`](pipeline/src/mp/summarize_local.py)):

- First `summarize()` call lazy-spawns `mlx_lm.server` in its own
  process group (so a Ctrl-C in the daemon doesn't kill it before
  cleanup), polls `/v1/models` until ready (configurable timeout),
  forwards a chat completion. Subsequent calls reuse the running
  server.
- A 5-min idle timer (configurable) shuts the server down to free
  RAM. Spawn / shutdown are serialized via a per-instance lock.
- Default model: `mlx-community/Qwen2.5-3B-Instruct-4bit` (~2 GB,
  ~10 s per meeting). Smaller-default-by-default so first-time local
  users do not pay an 8 GB download. Preferences → Pipeline exposes
  three curated presets (Small / Recommended / Large) that map to
  3B-4bit / 14B-4bit / 32B-4bit, plus a Custom slot for any
  HuggingFace MLX repo id. The picker rewrites
  `summarization.local_model`; the picker reads it back and shows
  "Custom" when the value is not a known preset.

Pre-fetch on backend switch ([`ModelDownloadSupervisor.swift`](daemon/Sources/MeetingPipe/ModelDownloadSupervisor.swift)
+ [`mp prefetch-model`](pipeline/src/mp/prefetch_model.py)):

- Whenever the configured backend becomes `"local"` or `"auto"` (on
  Coordinator launch or whenever the user persists a Preferences
  change), the daemon spawns `mp prefetch-model <repo_id>` if the
  model is not already cached. This turns the multi-minute first-call
  stall inside `mlx_lm.server` into a visible menu-bar progress state.
- Stdout from `prefetch-model` is one JSON event per line: `started`
  / `progress` / `complete` / `failed`. The supervisor tails the
  stream, updates an internal `State`, and the StatusBar reflects it
  as a title suffix (`↓ 42%`) plus a dedicated menu row showing the
  byte breakdown.
- Switching the configured model mid-download terminates the in-flight
  subprocess and starts a new one for the new repo. Switching back to
  `"anthropic"` cancels the in-flight prefetch entirely.

JSON discipline (the locally-running model has no `tool_choice`
forcing):

1. `_augment_with_schema` appends the `MeetingSummary` JSON Schema
   plus a "before you reply" reinforcement (decision-vs-intent rule,
   per-task owner rule, questions discipline) to the system prompt.
2. Request payload carries `response_format: { type: "json_schema",
   strict: true }`. Newer mlx-lm builds wire this through to outlines
   for token-level constraint; older builds ignore it.
3. On schema-violation, the call replays once with a corrective user
   message that includes the Pydantic error and the prior assistant
   reply.
4. Each attempt's body still passes through the 3-layer extractor:
   raw → fenced → largest balanced JSON object scan (string-aware,
   so braces inside strings don't break depth tracking).

Regulated zero-egress contract: `summarization.backend = "local"` AND
`modes.regulated_mode = true` produces a pipeline that makes no
outbound HTTP request. Locked in by
`tests/test_summarize_backend.py::test_regulated_local_zero_egress`,
which patches every `httpx.Client` transport through an `EgressBlocker`
that asserts on any non-localhost URL and poisons the `Anthropic`
constructor for good measure.

---

## 14. Multi-sink output

`output.sinks` (TOML) is an ordered list of publisher names. Default
is `["notion"]` (back-compat). Each name maps to one
`MeetingPublisher` implementation. Built once per `mp run-all`
invocation by `publish_router.build_publishers()`; iterated
sequentially by `publish_router.fanout()`.

| Sink | Bundle | Sidecar | Idempotency |
|---|---|---|---|
| `notion` | `NotionRestPublisher` | `<stem>.notion.json` | Update vs create by stored `page_id`. |
| `obsidian` | `ObsidianPublisher` | `<stem>.obsidian.json` | SHA-256 of the rendered note body; same body → no-op, no mtime touch. |
| `filesystem` | `FilesystemPublisher` | `<stem>.filesystem.json` | SHA-256 of the (summary + transcript + actions) payload. |

Failure isolation: a sink raising propagates as a `sink_failed`
JSONL event but does not abort the others. Per-sink results land in
`fanout()`'s `sinks: { ... }` map so the orchestrator and the doctor
can inspect what published and what didn't.

The `MeetingPublisher` protocol (renamed from `NotionPublisher` in
P3.1; old name kept as an alias) requires a `name: str` attribute so
two sinks can never collide on disk. Add a new sink by implementing
the protocol and adding a branch to `publish_router._build_one`.

---

## 15. Event log (JSONL)

Two append-only JSONL streams alongside the human-readable text logs:

- `~/Library/Logs/MeetingPipe/events.jsonl`: Swift daemon
  (`Log.event(category:, action:, attributes:)`).
- `~/Library/Logs/MeetingPipe/pipeline_events.jsonl`: Python pipeline
  (`mp.events.emit`).

Each line is one JSON object with `ts`, `category`, `action`, plus
free-form attributes. Categories emitted today:

| Category | Actions |
|---|---|
| `lifecycle` | `idle`, `starting`, `in_meeting`, `ending_provisional`, `ended` |
| `coordinator` | `state_change`, `prompt_shown`, `prompt_timeout`, `user_skipped`, `user_consented_always`, `auto_consent`, `recording_started`, `recording_stopped`, `pipeline_queued`, `pipeline_started`, `pipeline_succeeded`, `pipeline_failed`, `dry_run_enabled`, `dry_run_would_record` |
| `pipeline` | `run_started`, `stage_started`, `stage_completed`, `run_completed`, `run_skipped` (`no_speech` / `byo` / `too_long`), `run_failed` |
| `publisher` | `sink_started`, `sink_completed`, `sink_failed` |
| `correction` | `saved`, `failed` (Phase 2; see §17) |

Failures during emit are swallowed: an empty event log is preferable
to a crashed daemon or pipeline. The text logs already capture
human-readable trail.

Filter and pretty-print with `mp logs`:

```bash
mp logs --since 1h --category detector --action ended
mp logs --since 30m --json | jq 'select(.bundle_id == "us.zoom.xos")'
```

`--since` accepts both ISO timestamps and short relative offsets
(`1h`, `30m`, `2d`, `45s`).

---

## 16. Dry-run + dogfood

**Dry-run mode** (`MEETING_PIPE_DRY_RUN=1`): detection, recognizer,
state machine, and event log run end-to-end; `Coordinator.beginRecording`
short-circuits before `MeetingRecorder.start` so no audio is captured
and no pipeline jobs spawn. Use case: leave the daemon on through a
normal workday and grep `events.jsonl` after the fact to verify
detection accuracy across the real distribution of apps and call
patterns, without producing `.wav` files. Read once at Coordinator
init; flipping the env var requires a daemon restart.

**Dogfood harness** (`mp dogfood`):

```bash
mp dogfood <transcript.md>           # writes runs/<stem>.dogfood.md
mp dogfood --report                   # aggregates -> docs/local-llm-quality.md
```

Per-meeting comparison file holds both summaries side-by-side plus a
hand-fillable YAML-ish scorecard:

```yaml
scores:
  actions_capture:    # 0.0 to 1.0
  decisions_capture:  # 0.0 to 1.0
  hallucination_rate: # 0.0 to 1.0 (lower is better)
notes: ""
```

`--report` walks the runs dir, parses scorecards, aggregates, and
writes a ship/no-ship report. Ship gate matches the roadmap acceptance:
`actions_capture ≥ 0.80`, `decisions_capture ≥ 0.80`,
`hallucination_rate ≤ 0.05`. Exit 0 on ship, exit 1 otherwise (suitable
for CI gating once the corpus is large enough).

The grading is by hand by design: LLM-as-judge for "is the local
model good enough to be the privacy-preserving default" is
self-referential in a way that defeats the exercise.

---

## 17. Correction loop

Phase 2 of the local-LLM productisation. Every published meeting
offers the user an in-flow chance to grade the summary. Verdicts and
edits accumulate locally; Phase 3 reads the corpus to fine-tune a
per-user LoRA adapter.

### Two on-disk artifacts

**Run sidecar.** `<recordings>/<stem>.run.json`, written by
`mp run-all` at the end of the summarize stage. Snapshots the
runtime that produced `<stem>.summary.json` so a later correction is
attributed to the right backend even if the user flips backends in
between:

```json
{
  "stem":               "20260508-1500",
  "transcript_path":    "/abs/.../20260508-1500.md",
  "transcript_chars":   12345,
  "summary_json_path":  "/abs/.../20260508-1500.summary.json",
  "backend":            "local",
  "model":              "mlx-community/Qwen2.5-3B-Instruct-4bit",
  "ts":                 "2026-05-08T14:33:00Z"
}
```

Best-effort write; a failure is logged but does not block publish.

**Correction record.**
`~/Library/Application Support/MeetingPipe/corrections/<stem>.json`,
written by the daemon when the user grades a meeting. One file per
meeting, overwritten on re-correction (so the user can revise their
own verdict cleanly):

```json
{
  "transcript_path":   "/abs/.../<stem>.md",
  "summary_json_path": "/abs/.../<stem>.summary.json",
  "model_id":          "mlx-community/Qwen2.5-3B-Instruct-4bit",
  "backend":           "local",
  "ts":                "2026-05-08T14:33:00Z",
  "verdict":           "good" | "bad" | "edited",
  "original_summary":  { ... full MeetingSummary JSON ... },
  "corrected_summary": { ... only present when verdict == "edited" ... },
  "notes":             "free-form text, optional"
}
```

JSON-per-file (not JSONL) so re-grading is a single rewrite; the
Phase 3 trainer just globs the directory.

### UI surfaces

Both surfaces route through `CorrectionWindow.present(stem:, recordingsDir:)`.

1. **Done-meeting notification.** `Notifier` adds two action buttons
   to the published-meeting banner (`MP_DONE_CORRECTABLE` /
   `MP_DONE_CORRECTABLE_LOCAL` categories), gated on the run sidecar
   existing on disk:
   - **Looks good** writes a verdict-good record inline. No window opens.
   - **Edit summary** opens `CorrectionWindow`.
2. **Recent meetings… menu.** A status-bar submenu lists the last 10
   meetings with a run sidecar, newest first. Each child opens
   `CorrectionWindow` for that stem. Useful for grading meetings the
   user dismissed the notification for.

`CorrectionWindow` (`daemon/Sources/MeetingPipe/CorrectionWindow.swift`)
is a single-instance SwiftUI sheet that loads
`<stem>.summary.json` + `<stem>.run.json`, lets the user edit the
seven `MeetingSummary` fields plus a free-form notes block, and
persists via `CorrectionStore.write` with `verdict = .edited`. A
"Mark as unusable" footer button writes `verdict = .bad` without any
edits.

### `mp corrections-stats`

Markdown report (or `--json`) over the corrections directory.
Per-backend / per-model verdict breakdown plus per-field mean
normalized Levenshtein distance between `original_summary` and
`corrected_summary`. The Phase 3 readiness gate is two-part:

- `count >= 20` corrections, AND
- `sum(transcript_chars) >= 200_000` (≈200 minutes of speech).

Both must hold before the trainer is willing to start. Twenty 20-min
meetings, fifty 4-min meetings, or any mix that clears the chars
threshold all qualify.

### Event log

Daemon emits one of:

```json
{ "category": "correction", "action": "saved",
  "stem": "...", "verdict": "good|bad|edited",
  "backend": "...", "model_id": "..." }
{ "category": "correction", "action": "failed",
  "stem": "...", "verdict": "...", "error": "..." }
```

so the corpus growth (and any IO error) is grep-able from
`mp logs --category correction`.
