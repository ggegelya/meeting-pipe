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
                                                  ▼
                                        ┌─────────────────────┐
                                        │   pipeline (Py)     │
                                        │  ┌───────────────┐  │
                                        │  │  transcribe   │  │  mlx-whisper (ASR)
                                        │  │       +       │  │  + sherpa-onnx (diarize)
                                        │  └──────┬────────┘  │  → {ts}.json + {ts}.md
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

### End detection

Either signal false for ≥`debounce_end_sec` (default 10s) → STOPPING.

### Manual override

Global hotkey (default `⌃⌥M`) toggles RECORDING ↔ IDLE regardless of detector
state. Wins over auto.

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
│   └── Sources/MeetingPipe/
│       ├── App.swift                @main, AppDelegate
│       ├── Coordinator.swift        State machine + recorder lifecycle
│       ├── Detector.swift           NSWorkspace + AVCaptureDevice + Accessibility
│       ├── MeetingRecorder.swift    AVAudioEngine + AVAudioFile WAV writer
│       ├── SystemAudioCapture.swift SCStream wrapper for system audio
│       ├── MeetingPromptWindow.swift On-screen "Record this meeting?" panel
│       ├── Notifier.swift           UNUserNotificationCenter + actions
│       ├── PipelineLauncher.swift   Spawns `mp run-all`
│       ├── HotkeyManager.swift      Carbon-based global hotkey
│       ├── Config.swift             Loads ~/.config/meeting-pipe/config.toml
│       ├── ConsentStore.swift       Persisted "Always for {App}" choices
│       ├── State.swift              Enums for the state machine
│       ├── StatusBarController.swift
│       ├── Logger.swift             os.Logger wrapper + file logger
│       └── Resources/
│           └── meeting_apps.toml
├── pipeline/
│   ├── pyproject.toml
│   ├── src/mp/
│   │   ├── __init__.py
│   │   ├── __main__.py              Subcommand dispatcher
│   │   ├── doctor.py                `mp doctor` preflight (secrets + ML runtimes + APIs)
│   │   ├── transcribe.py            mlx-whisper ASR (faster-whisper fallback)
│   │   ├── diarize.py               sherpa-onnx offline diarization (CoreML EP)
│   │   ├── summarize.py             Anthropic tool-use, multilang prompt
│   │   ├── publish_notion.py
│   │   ├── publish_from_paste.py    BYO summary mode
│   │   ├── orchestrate.py           `run-all` + long-meeting guard
│   │   ├── config.py                Pydantic settings
│   │   ├── schemas.py               Pydantic models for summary JSON
│   │   └── prompts/
│   │       ├── __init__.py
│   │       └── meeting_summary.md
│   └── tests/
│       ├── test_schemas.py
│       ├── test_transcribe.py       Renderer + speaker assignment (no ML dep)
│       ├── test_summarize.py        Mocked Anthropic SDK + multilang directive
│       ├── test_publish_notion.py   httpx MockTransport
│       ├── test_publish_from_paste.py
│       ├── test_orchestrate.py
│       ├── test_doctor.py
│       └── test_endpoints.py
├── scripts/
│   ├── install.sh
│   ├── uninstall.sh
│   └── launchd.plist.template
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
| Accessibility    | Reading browser window titles                                       | System Settings → Privacy & Security |
| Notifications    | Prompts and completion alerts                                       | First launch prompt                  |

---

## 8.5. Multilingual support

| Stage | Multilang behavior |
|---|---|
| ASR (mlx-whisper) | All 99 Whisper languages. `language="auto"` auto-detects from the first 30 s; an explicit ISO 639-1 code (`"en"`, `"uk"`, `"ru"`, `"de"`) skips detection. |
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
| `isInUseByAnotherApplication` flakiness across macOS versions | Core Audio `DeviceIsRunningSomewhere` fallback + 3s poll. |
| Browser tab title patterns drift                              | Patterns in TOML, not compiled. Easy to tweak. |
| Diarization quality variance per language                     | sherpa-onnx with NeMo TitaNet generalizes well across languages, but `disable_diarization=true` is the escape hatch. |
| Apple Silicon MLX requirement for fast path                   | Pipeline auto-falls-back to faster-whisper on non-arm64 hosts; daemon is macOS-only anyway. |
| Long meetings burning Anthropic tokens silently                | `summarization.skip_above_chars` (default 80 000) writes a manual-processing bundle instead of calling the API. |
| Anthropic API cost creep                                      | ≈$0.05/meeting on Sonnet 4.6 at typical 5k in / 2k out. |
| Compliance for client/regulated calls                         | `regulated_mode=true` skips Notion entirely. |

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
