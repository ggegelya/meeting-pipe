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
| Mixing + write   | `AVAudioMixerNode` + `AVAudioFile`               | In-process. Mixer resamples to 16 kHz mono; AVAudioFile writes Int16 PCM WAV. |
| ASR              | mlx-whisper (Apple Silicon native MLX/Metal)     | ~5-10× faster than faster-whisper-CPU on M-series; emits word-level timestamps directly. faster-whisper kept as fallback for non-Apple-Silicon. |
| Diarization      | sherpa-onnx (CoreML / Apple Neural Engine)       | Replaces pyannote-on-CPU. Language-agnostic, no torch/HF-TOS pin pain, runs at ~0.1-0.3× realtime. |
| Summarization    | Anthropic Messages API direct, Claude Sonnet 4.6 | Headless, deterministic, structured outputs via tool-use schema. **Not Claude Code** — Claude Code is interactive; an unattended pipeline calls the API directly. |
| Publishing       | Notion REST API + integration token              | Robust unattended; idempotent; testable. **Not Notion MCP** — MCP is for interactive Claude. |
| Glue             | Python 3.11, single CLI with subcommands          | Each step debuggable in isolation. |
| Build            | Swift Package Manager + uv (Python)              | Reproducible. |

---

## 3. Architecture

```
            ┌─────────────────────────────────────────────────────┐
            │              MeetingPipe.app  (Swift)               │
            │  NSWorkspace ─┐                                     │
            │  AVCaptureDev ┼──> Detector ──> StateMachine        │
            │  Hotkey ──────┘                  │                  │
            │                                  ▼                  │
            │                              Notifier               │
            │                                  │                  │
            │                                  ▼                  │
            │                          MeetingRecorder            │
            │   SCStream ──┐                   │                  │
            │   (system    │   AVAudioEngine   │                  │
            │    audio)    └─►  ┌─────────┐    │                  │
            │                   │  Mixer  │ ──►│ AVAudioFile      │
            │   AVAudioEngine   └─────────┘    │ (16k mono WAV)   │
            │   .inputNode ────► (mic)         │                  │
            │   (system default)               ▼                  │
            └──────────────────────── $RECORDINGS_DIR/{ts}.wav ───┘
                                                  │
                                                  │ (PipelineLauncher invokes `mp run-all`)
                                                  │
                                                  │  In parallel during recording, a SECOND subprocess
                                                  │  (`mp transcribe-stream`) tails the daemon's growing
                                                  │  mic.wav / system.wav, runs mlx-whisper on 30 s chunks,
                                                  │  and runs the StreamDiarizer per chunk.
                                                  │  By the time the user hits Stop, {ts}.json is ~95 % done.
                                                  ▼
                                        ┌─────────────────────┐
                                        │   pipeline (Py)     │
                                        │  ┌───────────────┐  │
                                        │  │  transcribe   │  │  Skipped if streaming already wrote a
                                        │  │       +       │  │  usable {ts}.json (mlx + sherpa).
                                        │  └──────┬────────┘  │  → {ts}.json + {ts}.md (canonical)
                                        │         ▼           │
                                        │  guard: long?       │  → {ts}.READY_FOR_MANUAL.md
                                        │         │           │     (skip API; manual processing)
                                        │         ▼ (no)      │
                                        │  ┌───────────────┐  │
                                        │  │  summarize    │  │  Anthropic API (tool-use schema)
                                        │  └──────┬────────┘  │  → {ts}.summary.json + .summary.md
                                        │         ▼           │
                                        │  ┌───────────────┐  │
                                        │  │ publish_notion│  │  Notion REST
                                        │  └──────┬────────┘  │  → {ts}.notion.json (page id)
                                        └─────────┼───────────┘
                                                  ▼
                                             Notification:
                                        "Done — open in Notion"
```

Recording is fully in-process: ScreenCaptureKit and AVAudioEngine deliver
PCM directly into the daemon's mixer. The pipeline still runs
out-of-process so transcription doesn't block the daemon.

---

## 4. State machine

```
IDLE
  │  (detector: meeting started, debounced)
  ▼
PROMPTING ──(timeout / "Skip")──> SUPPRESSED ──(detector: end)──> IDLE
  │
  │  (user: "Record" or auto-consented bundle)
  ▼
RECORDING
  │  (detector: meeting ended, debounced)
  │  (or user: hotkey / "Stop")
  ▼
STOPPING ─(recorder flushed)─> IDLE
                                 │
                                 │  (concurrently — does not block recording)
                                 ▼
                          ProcessingJobs queue (FIFO)
                                 │  one whisper.cpp at a time so the CPU isn't thrashed,
                                 │  but recording can start a new meeting at any time
                                 ▼
                          spawn `mp run-all` per job → notification on done
```

`.handoff` used to be a state; it lived inside `AppState` and blocked the
daemon from starting a new recording while the previous transcription was
running. It now lives in a separate `ProcessingJob` queue on `Coordinator`
so recording stays unblocked while jobs run in the background.

---

## 5. Detection logic

**Two-signal AND, debounced.** Both must hold for ≥`debounce_start_sec`
(default 5s) before transitioning to PROMPTING.

### Signal A — meeting app active

- Native: `NSWorkspace.shared.runningApplications` contains a known bundle ID.
  The list lives in `daemon/Sources/MeetingPipe/Resources/meeting_apps.toml`.
- Browser: Accessibility API reads frontmost browser tab title against
  substring patterns (also in `meeting_apps.toml`).

### Signal B — microphone in use

- Primary: KVO on `AVCaptureDevice.default(for: .audio)?.isInUseByAnotherApplication`.
- Fallback: poll Core Audio `kAudioDevicePropertyDeviceIsRunningSomewhere`
  every 3s across all input devices.
- **Post-start gating** (`Detector.micInUse()`): once `hasFiredStart` is
  true, the broad Core Audio probe is skipped. Reason: the daemon's own
  `AVAudioEngine.inputNode` tap holds the input device while recording,
  which would keep `kAudioDevicePropertyDeviceIsRunningSomewhere` true
  forever and mask the meeting app releasing the mic.
  `isInUseByAnotherApplication` excludes self by Apple's design and is
  the correct signal for end detection.

### Signal C: meeting window still open (end-detection only)

A per-app window recognizer runs the AX query for the recording
source's PID and checks each window title against
`Detector.isActiveMeetingWindow(bundleID:, kind:, title:)`. The
recognizer has explicit positive and negative anchors per known shape:

- **Zoom** (`us.zoom.xos`): title contains `"zoom meeting"`.
  Rejects `"Zoom"` (launcher), `"Schedule Meeting"`, `"Join Meeting"`.
- **Teams** (`com.microsoft.teams2`, `com.microsoft.teams`): title ends
  with `"| microsoft teams"` AND the lead segment is exactly `"meeting"`,
  starts with `"meeting in "` / `"meeting with "` / `"call with "`,
  equals `"calling"` / starts with `"calling "`, or contains
  `"huddle"` / `"breakout"`. Prefix-match (not substring) so chat
  threads with subjects like `"Sprint planning meeting"` don't
  false-positive.
- **Webex** (`com.cisco.webexmeetingsapp`): title contains `"webex meeting"`.
- **Slack** (`com.tinyspeck.slackmacgap`): title matches `\bhuddle\b`
  as a whole word. `"team-huddles"` channel name correctly fails the
  trailing word boundary.
- **Skype** / **Google Meet**: dedicated checks; documented in source.
- **Unknown bundle**: probe short-circuits to `nil` (inconclusive),
  composer treats as "still open", mic-release alone drives end.

For **browser** sources, the probe walks each window's AX subtree to
locate the tab strip (`AXTabGroup`) and collects every open tab's title.
Switching tabs in the same window therefore doesn't end the meeting:
the Meet tab stays detectable in the background. Only closing the tab
(no fragment match across any window's tab list) ends the recording.
If the tab strip can't be located (Safari multi-window layouts, Edge
PWAs without tabs), the probe falls back to window titles — losing the
in-window tab-switch fidelity but still catching the "last browser
window closed" case.

### End-detection composition

`SignalDecision.decide()` in [`Detector.swift`](daemon/Sources/MeetingPipe/Detector.swift)
runs after `hasFiredStart`:

```
shouldEnd if (mic released) OR (window recognizer says no)
```

Both signals are debounced by `debounce_end_sec` (default 5s). Mic
release is the primary path; the window recognizer covers the few-second
tail where the meeting app holds the input device past hangup, plus the
case where AX permission is missing on the meeting app but not the mic.

**Per-app debounce (TECH-C4).** The end-debounce can be tuned per
bundle ID via `[detection.debounce_end_per_bundle]` in `config.toml`.
Browser sources without an explicit override get a built-in 12 s
default — browser window/tab state flickers more during a call than
native meeting apps, and the global 5 s produced premature stops.
Lookup precedence: explicit override > browser default > global.

### Re-prompt cooldown after a recording ends

When a recording for app X finishes (or its prompt is skipped / times
out), the Coordinator arms a per-bundle cooldown via `RepromptCooldown`.
Detector-driven `.started` events for the same bundle within
`reprompt_cooldown_sec` (default 60 s) are dropped with a
`prompt_suppressed_cooldown` event and never reach the prompt window.

The cooldown catches the post-call surface that Teams (and similar
clients) keep open after the meeting window dies — a chat tab that
briefly re-acquires the audio session is enough to make
`AVCaptureDevice.isInUseByAnotherApplication` flip true, producing a
stray "Record this meeting?" prompt 2-3 s after the previous stop.

The manual hotkey (`toggleManual`) and "Always for {App}" consent both
clear the cooldown entry so an explicit user-start is never blocked.

### Mute-aware mic capture

`MeetingMuteProbe` polls the active recording's meeting window once
per second and reads the client's mute control via Accessibility. The
recognised state flips `MeetingRecorder.micPaused`:

- `.muted` → recorder drops mic frames (`mic.wav` records silence for
  that interval); `mic_paused_due_to_mute` logged.
- `.unmuted` → recorder resumes writing; `mic_resumed` logged.
- `.unknown` → no change, last state is preserved.

This is needed because `AVAudioEngine.inputNode` taps the OS-level
microphone, which is independent of any meeting client's mute UI.
Without the probe, meeting-pipe captured the user's voice into the
transcript even while Teams said they were muted — surfaced in the
2026-05-13 17:25 test recording. Per-bundle predicates live in
`MeetingMuteProbe.recognize` (Teams, Zoom, Slack today). System-audio
capture is unaffected: the system mix continues to be recorded so the
transcript still contains everything the other participants said.

Opt-out via `recording.honor_app_mute = false` in `config.toml`. AX
denied / unrecognised label / browser sources keep the legacy
behaviour (record everything) without further configuration.

### Silence-based safety net

When the regular end-signal misses (browser-tab meetings where the call ended
but a leftover tab keeps the window probe firing, AX permission denied on the
meeting app), `SilenceDetector` is a post-recording fallback. It watches the
RMS level of mic + system audio during the recording. After 90 s of unbroken
silence on both channels (< -50 dBFS), it surfaces a "Still meeting?"
notification with a stop action. After 5 minutes of continuous silence it
auto-stops the recorder and emits an `auto_stop_silence` event. If Screen
Recording is denied the gate reduces to mic-only, which is still correct: a
mic-only recording is just the user, and a 5-minute mic silence means they
walked away.

### Manual override

Two global hotkeys, both configurable in Preferences → Detection:

- **Manual record (toggle)** — default `⌃⌥M`. IDLE → start, RECORDING → stop.
  Also functions as a force-stop when the detector misses end (`hasFiredStart`
  stays true, so the detector can't re-prompt for the same meeting; only a
  real `.ended` resets it).
- **Force stop (stop only)** — default `⌃⌥⇧M`. Stops a running recording;
  is a no-op when idle. Useful as a panic button that can never accidentally
  start a fresh recording. On PROMPTING, it dismisses the prompt and
  transitions to SUPPRESSED so the daemon doesn't re-prompt for the same call.
  Logged via the `coordinator.force_stop` event.

---

## 6. Repo layout

```
meeting-pipe/
├── README.md
├── SPEC.md
├── LICENSE
├── .gitignore
├── config.example.toml
├── daemon/                          Swift menu bar app
│   ├── Package.swift
│   ├── Sources/MeetingPipe/
│   │   ├── App.swift                @main, AppDelegate
│   │   ├── Coordinator.swift        State machine + recorder lifecycle + dry-run gate
│   │   ├── Detector.swift           NSWorkspace + AVCaptureDevice + AX, 3-signal composer,
│   │   │                            per-app window recognizer (isActiveMeetingWindow)
│   │   ├── MeetingRecorder.swift    AVAudioEngine + AVAudioFile WAV writer
│   │   ├── SystemAudioCapture.swift SCStream wrapper for system audio
│   │   ├── MeetingPromptWindow.swift On-screen "Record this meeting?" panel (P4.1 redesign)
│   │   ├── RecordingHUDWindow.swift Top-right pulse + elapsed timer + stop affordance
│   │   ├── Notifier.swift           UNUserNotificationCenter + actions
│   │   ├── PreferencesWindow.swift  SwiftUI tabs (Recording/Detection/Integrations/
│   │   │                            Pipeline/Modes); backend selector lives on Pipeline
│   │   ├── ConfigStore.swift        TOML round-trip for the UI-bound subset
│   │   ├── PipelineLauncher.swift   Spawns `mp run-all`
│   │   ├── StreamingTranscriber.swift  Spawns/manages `mp transcribe-stream` (Tier 2)
│   │   ├── HotkeyManager.swift      Carbon-based global hotkey
│   │   ├── Config.swift             Loads ~/.config/meeting-pipe/config.toml
│   │   ├── ConsentStore.swift       Persisted "Always for {App}" choices
│   │   ├── SecretsStore.swift       Reads ~/.config/meeting-pipe/secrets.env
│   │   ├── State.swift              Enums for the state machine
│   │   ├── StatusBarController.swift
│   │   ├── DoctorRunner.swift       In-process `mp doctor` invocation
│   │   ├── Endpoints.swift          Bundle id, paths, log subsystem constants
│   │   ├── Logger.swift             os.Logger + tail-able text logs + JSONL events
│   │   ├── MeetingPromptWindow.swift / RecordingHUDWindow.swift / ...
│   │   ├── Design/                  Tokens.swift, MPButton, AppGlyphView,
│   │   │                            DismissProgressView, LiveWaveformView, MicLevelMonitor
│   │   └── Resources/
│   │       └── meeting_apps.toml
│   └── Tests/MeetingPipeTests/
│       ├── SignalDecisionTests.swift              Composer rules (start/end semantics)
│       ├── WindowRecognizerTests.swift            Per-app must-recognize/must-reject matrix
│       ├── WindowRecognizerFixtureTests.swift     Audits recognizer against captured titles
│       ├── ConfigTests.swift, ConfigStoreTests.swift, ConsentStoreTests.swift,
│       ├── HotkeyManagerTests.swift, PipelineLauncherTests.swift, SecretsStoreTests.swift,
│       ├── StateTests.swift
│       └── Fixtures/
│           └── window_titles.json   (bundle_id, state, expected, titles) per row
├── pipeline/
│   ├── pyproject.toml               (mlx-lm declared with arm64 marker)
│   ├── uv.lock
│   ├── src/mp/
│   │   ├── __init__.py
│   │   ├── __main__.py              Subcommand dispatcher (run-all / transcribe /
│   │   │                            transcribe-stream / summarize / publish-notion /
│   │   │                            publish-from-paste / doctor / logs / dogfood)
│   │   ├── doctor.py                Preflight (secrets + ML runtimes + APIs + sinks)
│   │   ├── transcribe.py            mlx-whisper ASR (faster-whisper fallback)
│   │   ├── transcribe_stream.py     Long-running streaming sidecar (Tier 2)
│   │   ├── diarize.py               sherpa-onnx offline diarization (CoreML EP) +
│   │   │                            StreamDiarizer for online clustering (Tier 2.5)
│   │   ├── summarize.py             Backend selector → AnthropicSummaryClient /
│   │   │                            LocalSummaryClient / _AutoFallbackClient
│   │   ├── summarize_local.py       MLX backend: lazy mlx_lm.server, response_format
│   │   │                            hint, corrective retry, 3-layer JSON extractor
│   │   ├── publish_notion.py        NotionRestPublisher (name="notion"); P4.3 page
│   │   │                            layout (callout, bold opener, owner pill, chips)
│   │   ├── publish_obsidian.py      ObsidianPublisher (name="obsidian"); content-hash
│   │   │                            idempotent, optional audio attachment + daily-note
│   │   ├── publish_fs.py            FilesystemPublisher (name="filesystem"); summary +
│   │   │                            transcript + actions JSON
│   │   ├── publish_router.py        fanout(): builds publishers from output.sinks,
│   │   │                            iterates with per-sink failure isolation
│   │   ├── publish_from_paste.py    BYO summary mode
│   │   ├── orchestrate.py           `run-all` + long-meeting guard + JSONL events
│   │   ├── events.py                pipeline_events.jsonl emitter
│   │   ├── logs_cmd.py              `mp logs` filter / pretty-print
│   │   ├── dogfood.py               A/B harness + ship-decision report (Anthropic vs
│   │   │                            local; hand-graded scorecards)
│   │   ├── config.py                Pydantic settings (incl. backend, output.sinks,
│   │   │                            obsidian, filesystem)
│   │   ├── schemas.py               Pydantic models for summary JSON
│   │   ├── services.py              MeetingPublisher / SummaryClient / Diarizer protocols
│   │   │                            (NotionPublisher kept as back-compat alias)
│   │   └── prompts/
│   │       ├── __init__.py
│   │       └── meeting_summary.md   Tightened decision/action rules + worked examples
│   └── tests/
│       ├── test_schemas.py, test_transcribe.py, test_summarize.py,
│       ├── test_publish_notion.py, test_publish_notion_blocks.py,
│       ├── test_publish_obsidian.py, test_publish_fs.py, test_publish_router.py,
│       ├── test_summarize_local.py, test_summarize_backend.py,
│       ├── test_dogfood.py,
│       ├── test_publish_from_paste.py, test_orchestrate.py,
│       ├── test_doctor.py, test_endpoints.py
├── scripts/
│   ├── install.sh
│   ├── uninstall.sh                 (--purge / --reset-tcc / --all)
│   ├── launchd.plist.template
│   ├── gen-icon.swift
│   └── dump_window_titles.swift     AX dump → fixture row for window_titles.json
└── .github/
    └── workflows/
        └── ci.yml
```

---

## 7. Configuration

See [`config.example.toml`](./config.example.toml) for the live default. The
file is copied to `~/.config/meeting-pipe/config.toml` on install. Secrets
live separately in `~/.config/meeting-pipe/secrets.env` (mode 0600) — never
written to TOML.

```env
ANTHROPIC_API_KEY=sk-ant-...
NOTION_TOKEN=ntn_...
# HF_TOKEN is optional — only needed if you opt back into pyannote diarization.
# The default sherpa-onnx pipeline does not touch Hugging Face.
HF_TOKEN=
```

Daemon and pipeline both source `secrets.env` on startup.

---

## 8. Permissions

| Permission       | Why                                                                | Granted via                          |
|------------------|--------------------------------------------------------------------|--------------------------------------|
| Microphone       | `AVAudioEngine.inputNode` — captures user voice                    | First launch prompt                  |
| Screen Recording | `SCStream.capturesAudio` — gates system-audio capture in TCC        | System Settings → Privacy & Security |
| Accessibility    | Reads browser tab titles AND native meeting-app window titles for the per-app end-detection recognizer | System Settings → Privacy & Security |
| Notifications    | Prompts and completion alerts                                       | First launch prompt                  |

macOS TCC keys these grants on the bundle id (`com.meetingpipe.daemon`).
A reinstall reuses the same bundle id, so a previously-denied grant
stays denied across reinstalls. Use `scripts/uninstall.sh --reset-tcc`
(or `--all`) to reset Microphone / ScreenCapture / Accessibility /
AppleEvents / SystemPolicyAllFiles for the bundle so the next install
re-prompts cleanly.

---

## 8.4. Performance & streaming pipeline (Tier 1 / 2 / 2.5)

The pipeline used to run end-to-end after the user hit Stop. A 17-min
recording took ~38 min of post-stop wallclock under whisperx + pyannote
on CPU. Three tiers brought that to a few seconds:

| Tier | Change | What it gets you | After-stop wait for a 17-min meeting |
|---|---|---|---|
| 1 | mlx-whisper (Apple Silicon native) replaces faster-whisper-CPU; sherpa-onnx replaces pyannote. | ~7× faster end-to-end. | ~38 min → **~5 min** |
| 2 | `mp transcribe-stream` subprocess spawned at recording-start; tails the growing WAVs and transcribes 30-s chunks during the meeting. Orchestrator skips the offline transcribe stage at finalization. | Transcribe wallclock disappears into the meeting. | ~5 min → **~3 min** (just diarize + summarize + publish) |
| 2.5 | StreamDiarizer (silero-vad + NeMo TitaNet + online incremental clustering) runs per-chunk inside the streaming subprocess. Orchestrator skips offline diarize when ≥50% of segments already have a label. | Diarization wallclock also disappears into the meeting. | ~3 min → **~10-30 s** (just summarize + publish) |

Streaming details:

- **Chunking**: 30 s windows (Whisper's natural context) with 5 s
  overlap for context continuity at boundaries. Boundary-overlap
  duplicates get dropped by `_absorb_segments` (≤0.25 s difference).
- **Audio source**: the streaming sidecar tails the daemon's growing
  `<stem>.mic.wav` and (when present) `<stem>.system.wav` directly.
  AVAudioFile flushes PCM bytes to disk per `write(from:)` call; the
  RIFF header's `data` size is stale until close, which the sidecar
  ignores in favor of `os.stat()`-based byte tracking.
- **Termination**: daemon sends SIGTERM at recorder.stop(); 60 s grace
  to flush the final chunk; SIGKILL escalation. Failures fall through
  to the offline path so quality never silently degrades.
- **Fallback chain**: streaming JSON missing/empty → offline transcribe.
  Streaming JSON present but no speakers → offline diarize over the
  canonical merged WAV. Streaming JSON with speakers → straight to
  summarize.

---

## 8.5. Multilingual support

| Stage | Multilang behavior |
|---|---|
| ASR (mlx-whisper) | All 99 Whisper languages. Default is `language="en"`; an explicit ISO 639-1 code (`"en"`, `"uk"`, `"ru"`, `"de"`) skips detection. `language="auto"` opts back into per-meeting detection from the first 30 s of audio. Auto is intentionally opt-in: Whisper misfires on accented speech and silence-heavy openings (a Standup with Indian-English accents was classified as Spanish in the wild). The multilingual ASR still handles non-native accents fine when language is locked. |
| Diarization (sherpa-onnx + NeMo TitaNet) | Language-agnostic. Speaker identity is encoded in phoneme-level acoustic features that transfer across languages. No per-language model. |
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
| `isInUseByAnotherApplication` flakiness pre-start                  | Core Audio `DeviceIsRunningSomewhere` probe runs only before `hasFiredStart` (the daemon's own input tap would mask it post-start). |
| Native meeting-app title format drift (Teams/Zoom UI rename)        | `Tests/.../Fixtures/window_titles.json` + `WindowRecognizerFixtureTests` turn silent regressions into a red row in CI. `dump_window_titles.swift` captures fresh rows from the live app. |
| Browser tab title patterns drift                                    | Patterns in TOML, not compiled. Easy to tweak. |
| Diarization quality variance per language                           | sherpa-onnx with NeMo TitaNet generalizes well across languages, but `disable_diarization=true` is the escape hatch. |
| Apple Silicon MLX requirement for fast path                         | Pipeline auto-falls-back to faster-whisper on non-arm64 hosts; daemon is macOS-only anyway. |
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

- After `transcribe` produces `<stem>.md`, the orchestrator checks
  `len(md) > summarization.skip_above_chars` (default `80000` ≈ 20 000
  tokens ≈ ~1 hour of speech).
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
| `detector` | `started`, `ended` |
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
