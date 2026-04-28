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
| Daemon           | Swift menu-bar app, no Dock icon                | Native NSWorkspace, AVCaptureDevice KVO, UNUserNotificationCenter. ~500 LOC. |
| Audio capture    | BlackHole 2ch + Aggregate Device + ffmpeg       | Already validated. Scriptable. |
| Transcription    | WhisperX (faster-whisper + pyannote.audio)       | Best on-device diarization quality for free. |
| Summarization    | Anthropic Messages API direct, Claude Sonnet 4.6 | Headless, deterministic, structured outputs via tool-use schema. **Not Claude Code** — Claude Code is interactive; an unattended pipeline calls the API directly. |
| Publishing       | Notion REST API + integration token              | Robust unattended; idempotent; testable. **Not Notion MCP** — MCP is for interactive Claude. |
| Glue             | Python 3.11, single CLI with subcommands          | Each step debuggable in isolation. |
| Build            | Swift Package Manager + uv (Python)              | Reproducible. |

---

## 3. Architecture

```
            ┌─────────────────────────────────────────────┐
            │          MeetingPipe.app  (Swift)           │
            │   NSWorkspace ─┐                            │
            │   AVCaptureDev ┼──> Detector ──> StateMachine
            │   Hotkey ──────┘                  │         │
            │                                   ▼         │
            │                               Notifier      │
            │                                   │         │
            │                                   ▼         │
            │                               Recorder ──┐  │
            └──────────────────────────────────────────┼──┘
                                                       │
                            ┌──────────────────────────┘
                            │ (ffmpeg subprocess: BlackHole+mic → WAV)
                            ▼
                  $RECORDINGS_DIR/{ts}.wav
                            │
                            │ (PipelineLauncher invokes `mp run-all`)
                            ▼
                  ┌─────────────────────┐
                  │   pipeline (Py)     │
                  │  ┌───────────────┐  │
                  │  │  transcribe   │  │  WhisperX + pyannote
                  │  └──────┬────────┘  │  → {ts}.json + {ts}.md
                  │         ▼           │
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

The pipeline runs out-of-process — daemon doesn't block on transcription.

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
STOPPING                           
  │  (ffmpeg flushed)
  ▼
HANDOFF ──(spawn `mp run-all`)──> IDLE
```

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
│       ├── App.swift                @main, AppDelegate, status bar
│       ├── Coordinator.swift        State machine
│       ├── Detector.swift           NSWorkspace + AVCaptureDevice + Accessibility
│       ├── Recorder.swift           ffmpeg subprocess management
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
│   │   ├── transcribe.py
│   │   ├── summarize.py
│   │   ├── publish_notion.py
│   │   ├── orchestrate.py           `run-all`
│   │   ├── config.py                Pydantic settings
│   │   ├── schemas.py               Pydantic models for summary JSON
│   │   └── prompts/
│   │       └── meeting_summary.md
│   └── tests/
│       ├── test_schemas.py
│       ├── test_transcribe.py       Renderer tests (no ML dep)
│       ├── test_summarize.py        Mocked Anthropic SDK
│       └── test_publish_notion.py   httpx MockTransport
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
HF_TOKEN=hf_...
```

Daemon and pipeline both source `secrets.env` on startup.

---

## 8. Permissions

| Permission       | Why                                              | Granted via                          |
|------------------|--------------------------------------------------|--------------------------------------|
| Microphone       | ffmpeg recording                                 | First launch prompt                  |
| Screen Recording | ffmpeg avfoundation on some macOS versions       | System Settings → Privacy & Security |
| Accessibility    | Reading browser window titles                    | System Settings → Privacy & Security |
| Notifications    | Prompts and completion alerts                    | First launch prompt                  |

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
| pyannote diarization weak on Ukrainian                        | `disable_diarization=true` → label all as "Speaker". |
| MPS backend instability in faster-whisper                     | Default `compute_type="int8"` (CPU). |
| BlackHole Aggregate Device renames                            | Config uses **name**, not index. README warns. |
| Anthropic API cost creep                                      | ≈$0.05/meeting on Sonnet 4.6 at typical 5k in / 2k out. |
| Compliance for client/regulated calls                         | `regulated_mode=true` skips Notion entirely. |
| HuggingFace TOS gating                                        | `install.sh` prints exact URLs to accept; pipeline fails-fast on 401. |

---

## 11. Definition of done

- All phases merged with green CI.
- README walks a fresh user from clone to first auto-published Notion page.
- LaunchAgent loaded; survives logout/login.
- Uninstall script leaves no residue when run with `--purge`.
