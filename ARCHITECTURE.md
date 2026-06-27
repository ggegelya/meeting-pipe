# Architecture

Fast subsystem map for finding code. For the *why* behind shape decisions, see the README ["Why it is shaped this way"](./README.md#why-it-is-shaped-this-way) and the [ADRs](./docs/decisions/). For terminology, see the [Glossary](#glossary) below. For coding patterns, see [`CONVENTIONS.md`](./CONVENTIONS.md).

```
meeting-pipe/
├── daemon/      Swift menu-bar app (detection, recording, transcription, UI, hotkeys)
├── pipeline/    Python CLI invoked as `mp <subcommand>` (summarize, publish)
└── scripts/    install.sh, rebuild.sh, uninstall.sh, dev tools
```

The daemon records the WAV, writes the `.meta.json` sidecar, and transcribes on-device (FluidAudio); then it spawns the pipeline as a subprocess and forgets about it. The pipeline reads the transcript and the sidecar, decides what to do per workflow, and summarizes / publishes. The two processes share contracts via files on disk: `.meta.json` (per recording) and `events.jsonl` / `pipeline_events.jsonl` (append-only logs).

---

## Visual overview

Five diagrams for the high-level picture. Each answers one question; jump to the section that matches what you need.

### Subsystem map

Who-talks-to-whom across the whole system. The daemon is one Swift process that owns detection, recording, and routing; the pipeline is a short-lived Python subprocess invoked per meeting.

```mermaid
flowchart LR
    User([User])
    subgraph Daemon["MeetingPipe daemon (Swift, menu-bar)"]
        MLC["MeetingLifecycle<br/>Coordinator"]
        Coordinator
        MicGate
        Recorder["MeetingRecorder"]
        Transcribe["FluidAudio<br/>ASR + diarization"]
        Sinks["SinkDispatcher"]
        UI["Status bar + HUD<br/>+ Library + Preferences"]
    end
    subgraph FS["Filesystem (~/Documents/Meetings/raw/)"]
        WAV[".wav"]
        Meta[".meta.json"]
        Transcript[".json / .md"]
        Summary[".summary.json"]
        Notion[".notion.json"]
    end
    Pipeline["mp run-all<br/>(Python subprocess)"]
    Anthropic[(Anthropic API)]
    NotionAPI[(Notion API)]

    User -->|mic + system audio| Recorder
    User -->|joins / leaves call| MLC
    MLC --> Coordinator
    Coordinator --> UI
    Coordinator --> Recorder
    Coordinator --> MicGate
    MicGate -->|verdict per buffer| Recorder
    Recorder --> WAV
    Coordinator --> Meta
    Coordinator --> Sinks
    Sinks --> Transcribe
    Transcribe --> Transcript
    Sinks --> Pipeline
    Pipeline --> Anthropic
    Pipeline --> Summary
    Pipeline --> NotionAPI
    NotionAPI --> Notion
    UI --> WAV
    UI --> Meta
    UI --> Summary
```

### Meeting lifecycle

What happens between "you join a Teams call" and "the Notion page appears". MicGate runs in parallel with the recorder for the whole call; the pipeline subprocess runs after the recorder closes the WAV.

```mermaid
sequenceDiagram
    actor User
    participant LC as Lifecycle subsystem
    participant Coord as Coordinator
    participant Rec as MeetingRecorder
    participant Gate as MicGate
    participant Sink as SinkDispatcher
    participant Pipe as Pipeline (mp run-all)
    participant N as Notion

    User->>LC: opens Teams call
    LC->>Coord: verdict .starting
    Coord->>User: prompt panel (Record? Skip?)
    User->>Coord: Record
    Coord->>Rec: start(outputDir, voiceProcessing)
    Coord->>Gate: engage(handles)
    loop every audio buffer
        Rec->>Gate: per-buffer mic RMS
        Gate-->>Rec: MicGateVerdict
        Note right of Rec: MicGateWriter applies the<br/>verdict in place, 20 ms fade,<br/>frame parity preserved
    end
    User->>LC: clicks Leave
    LC->>Coord: verdict .ended
    Coord->>Rec: stop()
    Rec->>Rec: ffmpeg merge mic + system
    Coord->>Sink: enqueue(wav)
    Sink->>Sink: FluidAudio transcribe + diarize
    Sink->>Pipe: mp run-all
    Pipe->>Pipe: summarize
    Pipe->>N: publish
    N-->>User: notifier opens page URL
```

### Verdict-fusion stack

The post-detection layer that decides, every audio buffer, whether your mic should be audible or silent. Four probes feed `MicGate`; its verdict drives both the writer (shapes the recorded audio) and the silence backstop (auto-stops dead meetings).

```mermaid
flowchart TB
    subgraph Probes["Probes (MeetingPipeCore)"]
        HALMute["HAL system mute<br/>kAudioObjectPropertyMute"]
        HALVAD["HAL VAD<br/>VoiceActivityDetection*"]
        AXMute["AX mute observer<br/>MuteLabels.toml<br/>en, uk, de, es, fr, ja, pt, ru"]
        RMS["Per-buffer mic RMS<br/>(from MeetingRecorder tap)"]
    end

    MicGate["MicGate<br/>pure precedence rules<br/>(verdict_changed event per flip)"]

    Verdict[/"MicGateVerdict<br/>.hot · .mutedByApp · .mutedByHardware<br/>.silentByRMS · .uncertain"/]

    subgraph Consumers
        Writer["MicGateWriter<br/>per-buffer apply<br/>20 ms linear fade"]
        Backstop["MicOnlySilenceBackstop<br/>force-stop after N seconds<br/>(default 480, configurable)"]
    end

    Audio[".wav left channel"]
    ForceStop["force_stop<br/>reason=mic_only_silence"]

    HALMute --> MicGate
    HALVAD --> MicGate
    AXMute --> MicGate
    RMS --> MicGate
    MicGate --> Verdict
    Verdict --> Writer
    Verdict --> Backstop
    Writer --> Audio
    Backstop --> ForceStop
```

`MeetingLifecycleCoordinator` is the sibling system for meeting-level verdicts (`.idle`, `.starting`, `.inMeeting`, `.endingProvisional`, `.ended`). It runs alongside MicGate; its `.ended` verdict drives stop-recording (TECH-C13 step 5, shipped).

### Data contracts

The daemon and pipeline share state through files on disk, not IPC. Five sidecars per meeting; the schemas live in [`CONVENTIONS.md`](./CONVENTIONS.md). The library window also reads the same files.

```mermaid
flowchart LR
    subgraph DaemonSide["Swift daemon"]
        DR["MeetingRecorder"]
        DM["MeetingMetaSidecar"]
        DT["FluidAudio transcribe"]
        DL["Library window"]
    end

    subgraph Files["~/Documents/Meetings/raw/&lt;stem&gt;.*"]
        WAV[".wav<br/>mixed mic + system"]
        META[".meta.json<br/>workflow + source"]
        TRANSCRIPT[".json / .md<br/>diarized transcript"]
        SUMM[".summary.json<br/>LLM output"]
        NOT[".notion.json<br/>page URL"]
        RUN[".run.json<br/>run metadata"]
    end

    subgraph Pipe["Python pipeline (mp run-all)"]
        PS["summarize"]
        PP["publish"]
    end

    DR --> WAV
    DM --> META
    WAV --> DT
    DT --> TRANSCRIPT
    TRANSCRIPT --> PS
    META --> PS
    PS --> SUMM
    PP --> NOT
    PP --> RUN
    WAV --> DL
    META --> DL
    TRANSCRIPT --> DL
    SUMM --> DL
    NOT --> DL
```

### Workflow resolution

How a recording gets routed: precedence top-down. The prompt window's chevron menu sets an explicit override; failing that, rules match by bundle ID and window title; failing that, the default workflow runs. `nda_mode` then forces local backend + filesystem-only sinks regardless of the resolved workflow's preferences.

```mermaid
flowchart TD
    Start([AppSource or manual])
    OV{pendingOverride<br/>set?}
    BT{bundle + title<br/>rule match?}
    B{bundle-only<br/>rule match?}
    Def[Default workflow]
    Pick[/Picked Workflow/]
    NDA{nda_mode<br/>= true?}
    Local["Backend: local<br/>Sinks: filesystem only"]
    Normal["Backend: workflow.backend<br/>Sinks: workflow.sinks"]

    Start --> OV
    OV -->|yes| Pick
    OV -->|no| BT
    BT -->|yes| Pick
    BT -->|no| B
    B -->|yes| Pick
    B -->|no| Def
    Def --> Pick
    Pick --> NDA
    NDA -->|yes| Local
    NDA -->|no| Normal
```

---

## Daemon — `daemon/Sources/MeetingPipe/`

### Lifecycle entry points

- `App.swift` — `@main`. NSApplication accessory app. Reads `UISettings`, applies theme, sets up `ConfigStore` + `SecretsStore`, constructs `Coordinator`, wires `StatusBarController`, kicks off `SystemAudioCapture.prewarm`.
- `Coordinator.swift` — the spine. Owns the `AppState` machine (`State.swift`), drives every transition, dispatches between subsystems. ~1500 lines, the only place where everything meets.

### Detection - "is the user in a meeting?"

Detection is the `MeetingPipeCore` lifecycle subsystem plus the daemon-side discovery scan.

- `MeetingPipeCore/Lifecycle/MeetingLifecycleCoordinator.swift` - owns the per-app adapters and fuses their signals into a `MeetingLifecycleVerdict` stream (`.idle`, `.starting`, `.inMeeting`, `.endingProvisional`, `.ended`).
- `MeetingPipeCore/Lifecycle/PromotionEngine.swift` - the pure verdict-fusion rules: a debounce that promotes provisional signals to a confirmed verdict.
- `MeetingPipeCore/Lifecycle/Signals/` - the signal sources: per-process audio activity, ScreenCaptureKit shareable-content windows, the AX Leave button, plus corroborating window-title / workspace / input-device signals.
- `MeetingPipeCore/Lifecycle/Adapters/` - one adapter per meeting client (Teams, Zoom, Webex, Slack, browser), wiring the right signals with locale-tolerant title patterns.
- `MeetingDiscoveryWatcher.swift` / `MeetingSourceScanner.swift` / `MeetingSourceScorer.swift` - start-side discovery: enumerate every concurrent candidate app, score each on "I am in a meeting" evidence, pick the strongest.
- `Resources/meeting_apps.toml` - per-bundle-id table of known meeting apps and their window-title regex hints.
- `SilenceDetector.swift` - pure logic over mic + system RMS samples: decides when to fire the "Still meeting?" notify and the silence auto-stop.
- `RepromptCooldown.swift` - per-bundle, fixed-duration suppression window after a recording / skip so a post-call mic flicker can't spawn a fresh prompt.
- `SkippedMeetingLatch.swift` - per-bundle suppression anchored to discovery liveness (not a fixed clock): once you dismiss a prompt, every discovery sighting of that app refreshes the latch, so the meeting stays skipped for its whole lifetime and lapses ~15 s after it ends. Paired with `RepromptCooldown` in `abandonPrompt`.

### Recording - "capture what's playing + what I say"

- `MeetingRecorder.swift` - AVAudioEngine for mic capture + the `SystemAudioCapture` source for everything else, mixed and written to disk. `MicGateWriter` applies the per-buffer mute verdict in place.
- `SystemAudioCapture.swift` - ScreenCaptureKit + ProcessTap (macOS 14.2+) capture of every-other-process audio. The `excludesCurrentProcessAudio` API is the macOS 14 hard floor.

### Mute gating - "don't record me while I'm muted"

- `MeetingPipeCore/MicGate/` - the `MicGate` verdict-fusion subsystem. Probes (HAL system mute, HAL voice-activity detection, an AX read of the meeting client's Mute button, a per-buffer RMS gate) feed `MicGate.decide`; `MicGateWriter` zeros the mic channel with a short fade while muted, preserving frame alignment with system audio.
- `MeetingPipeCore/MicGate/MicOnlySilenceBackstop.swift` - force-stops a recording that has been mic-only and silent past a configured window.

### Transcription - "ASR + speaker labels, on device"

- `Transcription/FluidAudioRunner.swift` - FluidAudio (Parakeet TDT for ASR, pyannote-community-1 for diarization) on the Apple Neural Engine. `SinkDispatcher` runs it after the recorder closes the WAV, producing `<stem>.json` / `<stem>.md`.
- `Transcription/SegmentBuilder.swift`, `TranscriptionRunner.swift`, `TranscriptionService.swift` - segment assembly, the runner protocol, and the factory the dispatcher calls.

### Workflows — per-context routing (TECH-B)

- `Workflow.swift` — the codable struct (matching rules, sinks, backend, NDA flag).
- `WorkflowStore.swift` — TOML CRUD against `~/.config/meeting-pipe/workflows/*.toml`. One file per workflow, atomic writes.
- `WorkflowMatcher.swift` — given an `AppSource`, picks the matching workflow. Precedence: explicit override > bundle id > window title regex > default.
- `WorkflowMigrator.swift` — first-run shim that seeds a "General" workflow from the legacy `summarization.team_context` field.
- `WorkflowInspector.swift` — the prompt-window chip + drop-down that lets the user override before recording.
- `WorkflowsView.swift` — the Workflows tab UI (list, reorder, inline editor, sink picker).
- `MeetingMetaSidecar.swift` — builder for `<stem>.meta.json`. The contract surface between Swift and Python — the pipeline reads exactly these keys via `mp.workflow.apply_overrides`.

### UI surfaces

- **Menu bar:** `StatusBarController.swift` — title, icons (outline/filled per `UISettings.menuBarIconStyle`), lock glyph for regulated mode, model-download progress, aggregate permission warning.
- **Prompt panel:** `MeetingPromptWindow.swift` — the top-right "Record / Skip / Record (BYO)" panel that pops on detection.
- **HUD:** `RecordingHUDWindow.swift` — the floating pulse while recording.
- **Library window:** `LibraryWindow.swift` + `LibrarySidebar.swift` + `LibraryListView.swift` + `MeetingDetailView.swift` + tabs (`TranscriptTab`, `AudioTab`, `CorrectionsTab`, `RawFilesTab`). Reads `~/Documents/Meetings/raw/*.meta.json` via `MeetingStore.swift`. Filter / search via `MeetingFilter.swift`.
- **Preferences:** `PreferencesWindow.swift` (NSWindow shell) + `Preferences/PreferencesView.swift` (SwiftUI NavigationSplitView) + `Preferences/PreferencesControls.swift` (shared primitives: `SettingsGroup`, `SettingsRow`, `SettingsSegmented`, `SettingsHotkeyField`, …).
- **Correction window:** `CorrectionWindow.swift` + `CorrectionEditor.swift` — inline edit of a generated summary, writes a correction record, optional republish.

### Storage / persistence

- `Config.swift` — read-only Config snapshot loaded at launch (`~/.config/meeting-pipe/config.toml`).
- `ConfigStore.swift` — `ObservableObject` wrapper for the same file. Round-trips through TOMLKit, preserves unknown keys (so pipeline-side fields like `transcription.model` survive UI edits). 500 ms debounced writes.
- `Preferences/UISettings.swift` — singleton over `UserDefaults` for cosmetic flags (theme, menu-bar icon style, regulated badge, verbose logging).
- `SecretsStore.swift` — `~/.config/meeting-pipe/secrets.env` (mode 0600), Anthropic + Notion tokens.
- `ConsentStore.swift` — per-bundle "always record this app" decisions.
- `CorrectionStore.swift` — `<stem>.correction.json` records so the user's edits feed back into evals.
- `MeetingStore.swift` — read-only catalog of `<stem>.meta.json` sidecars; powers the Library list. Watches the directory via `DispatchSource.makeFileSystemObjectSource`.

### Plumbing

- `PipelineLauncher.swift` — spawns `mp run-all <wav>` as a subprocess. Each job is one `ProcessingJob` (see `State.swift`); the queue runs them serially so two whisper invocations don't thrash the GPU.
- `PermissionsCenter.swift` — single source of truth for the four TCC permissions (mic, Screen Recording, Accessibility, Notifications). Polls for live-flip detection; publishes a `permissionGranted` PassthroughSubject the Coordinator listens to (so the detector wakes up the moment Accessibility flips on mid-meeting).
- `HotkeyManager.swift` — Carbon RegisterEventHotKey for global hotkeys (toggle + force-stop).
- `Notifier.swift` — UNUserNotificationCenter wrapper (record / skip prompts, "meeting published" alerts).
- `Logger.swift` — `Log.main / .detector / .recorder` os.Logger handles, plus `Log.event(category:action:attributes:)` for the JSONL event log and `Log.writeLine(category:message:)` for the human-readable tail files.
- `ModelDownloadSupervisor.swift` — spawns `mp prefetch-model` for local-backend MLX models; surfaces progress in the menu bar.
- `WindowActivationManager.swift` — keeps the daemon Dock-less when no windows are visible but flips activation policy to `.regular` when the Library or Preferences window is open so Cmd+Tab works.
- `LaunchAtLoginService.swift` — `SMAppService.mainApp` wrapper for the General-tab toggle.

---

## Pipeline — `pipeline/src/mp/`

### Entry point

- `__main__.py` - argv dispatch. Lazy imports per subcommand so `mp --help` and `mp logs` stay fast; the heavier `mlx_lm` / `soundfile` imports are deferred to the subcommands that use them.

### Subcommands (one module each)

| Module | Subcommand | Output |
|---|---|---|
| `orchestrate.py` | `mp run-all <wav>` | reads the daemon transcript, then summarize, then publish; fail-fast |
| `summarize.py` | `mp summarize <transcript.md>` | `<stem>.summary.json`, `<stem>.summary.md` |
| `summarize_local.py` | (called from `summarize`) | on-device MLX path |
| `publish_notion.py` | `mp publish-notion <summary.json>` | Notion page (idempotent) |
| `publish_obsidian.py` | (called via router) | Markdown note in vault |
| `publish_fs.py` | (called via router) | three files in a directory |
| `publish_router.py` | (called from `orchestrate`) | fan-out over `output.sinks` |
| `publish_from_paste.py` | `mp publish-from-paste <transcript.md>` | BYO summary, then publish |
| `workflow.py` | (called from `orchestrate`) | applies `.meta.json` overrides |
| `diarize.py` | (called from `orchestrate`) | channel-aware speaker labels when daemon diarization is missing |
| `doctor.py` | `mp doctor` | preflight diagnostics |
| `logs_cmd.py` | `mp logs` | `events.jsonl` pretty-printer / filter |
| `dogfood.py` | `mp dogfood` | side-by-side backend comparison |
| `prefetch_model.py` | `mp prefetch-model <repo>` | MLX model download (JSONL progress) |
| `corrections.py` | `mp corrections-stats` | aggregate over correction records |
| `analyze_detection.py` | `mp analyze-detection` | meeting-end detection audit |

### Shared services and contracts

- `services.py` — `Protocol`s for the three external dependencies (`SummaryClient`, `Publisher`, `Diarizer`). Concrete implementations live next to use sites; tests inject fakes.
- `schemas.py` — pydantic models. `MeetingSummary` is the JSON contract the publishers expect.
- `config.py` — TOML loader for `~/.config/meeting-pipe/config.toml` + `secrets.env`. Same file the daemon reads.
- `events.py` — Python mirror of Swift's `Log.event`. Appends to `~/Library/Logs/MeetingPipe/pipeline_events.jsonl`.

---

## Data flow

### Detect → record (daemon-only)

```
lifecycle verdict .starting (or discovery scan, or manual hotkey)
  -> WorkflowMatcher.resolve(source) -> Workflow
  -> MeetingPromptWindow shown (or auto-consent / always-for-bundle)
  -> user clicks Record (or auto / timeout-default)
  -> Coordinator.beginRecording(source, summaryMode, workflow)
  -> MeetingRecorder writes <stem>.wav
  -> MeetingMetaSidecar.build writes <stem>.meta.json   (both in ~/Documents/Meetings/raw/)
  -> MicGate engaged for the recording
```

### Stop → process → publish (daemon hands off to pipeline)

```
lifecycle verdict .ended (or hotkey, or silence backstop)
  -> MeetingRecorder.stop -> ffmpeg merge -> final WAV closed
  -> SinkDispatcher: FluidAudio transcribe + diarize -> <stem>.json / <stem>.md
  -> PipelineLauncher.enqueue(ProcessingJob)
  -> mp run-all <wav>:
       orchestrate reads <stem>.meta.json and the daemon transcript
       workflow.apply_overrides -> context_prompt, backend, sinks
       summarize -> Anthropic OR mlx_lm.server (per workflow.backend)
       publish_router fanout -> notion + obsidian + filesystem (per workflow.sinks)
       sidecar updates -> <stem>.run.json, <stem>.notion.json, ...
  -> daemon notifies "published"
```

### Cross-cutting

- **`<stem>.meta.json`** — the only Swift→Python contract surface. Schema lives in `MeetingMetaSidecar.swift` (writer) and `mp.workflow.apply_overrides` (reader). Don't add keys to one without the other.
- **`<stem>.error.json`** is the daemon-internal failure sidecar. Written when a pipeline run fails (transcribe / summarize / launch) with the failed stage and reason; read by the Library to mark the meeting row failed until the owner retries. Cleared on the next successful run. Not a Swift to Python contract: the daemon both writes and reads it.
- **Event log** (`events.jsonl` from Swift + `pipeline_events.jsonl` from Python): one JSON object per line, fields `{ts, category, action, ...attrs}`. Schema and the full category list live in [`CONVENTIONS.md`](./CONVENTIONS.md#event-log-schema).
- **Logs directory** (`~/Library/Logs/MeetingPipe/`) — both event logs, plus `daemon.log`, `detector.log`, `recording.log`, `pipeline.log`, `launchd.out.log`, `launchd.err.log`.

---

## Key invariants

- **State machine never reaches two `.recording` states**, and `.stopping` always advances to `.idle` after the WAV closes. `AppState` enum (`State.swift`) is the contract; every transition lives in `Coordinator`.
- **Pipeline runs concurrently with recording.** Processing jobs queue in `Coordinator.processingJobs` and execute serially; the recording state machine is independent of queue depth. A new meeting can start while the last one is still transcribing.
- **Sinks are idempotent and isolated.** `publish_router.fanout` runs each sink; one failing doesn't block the others. Notion uses a deterministic page slug derived from the meeting stem so re-publish is upsert, not duplicate.
- **Unknown TOML keys survive.** `ConfigStore` round-trips through `TOMLTable` and only touches the fields it models. Pipeline-side fields the daemon doesn't know about (`transcription.model`, `summarization.team_context`, …) stay untouched.
- **TCC grants survive rebuilds.** `scripts/install.sh` and `scripts/rebuild.sh` codesign adhoc with a stable `--identifier com.meetingpipe.daemon` and bind Info.plist into the signature. The cdhash still changes per rebuild (no Developer ID), so Screen Recording requires one toggle after rebuild, but Mic + Notifications + Accessibility survive.
- **`Log.event` failures never crash the daemon.** A malformed attribute drops the event silently. Same in `mp.events.emit`.

---

## Where files live on disk (user side)

| Path | Owner | Purpose |
|---|---|---|
| `~/.config/meeting-pipe/config.toml` | both | shared config |
| `~/.config/meeting-pipe/secrets.env` | both | API tokens, mode 0600 |
| `~/.config/meeting-pipe/workflows/*.toml` | daemon writes, pipeline reads | per-workflow definitions |
| `~/Documents/Meetings/raw/<stem>.wav` | daemon writes | recording |
| `~/Documents/Meetings/raw/<stem>.meta.json` | daemon writes, pipeline reads | per-meeting workflow + source |
| `~/Documents/Meetings/raw/<stem>.recordfail.json` | daemon writes | breadcrumb left only when an ffmpeg merge failed; the `.mic.wav`/`.system.wav` intermediates are kept and the orphan sweep retries on the next launch (REC1) |
| `~/Documents/Meetings/raw/<stem>.mute-timeline.json` | daemon writes + reads | muted spans for the offline redactor, written at stop under capture-first-redact only; `{version, spans:[{start_sec,end_sec}]}` (DOC6) |
| `~/Documents/Meetings/raw/<stem>.capturemode` | daemon writes + reads | one-line privacy-mode marker (`capture_first` / `capture_first_redact` / `regulated_gate`) written at recording start so orphan recovery applies the right posture after a crash (DOC6) |
| `~/Documents/Meetings/raw/<stem>.recovery.json` | daemon writes + reads | start-time identity manifest (`{summary_mode, meta}`) written at recording start so orphan recovery routes a crash-interrupted BYO/NDA/regulated meeting on-device instead of auto-egressing it; the meta payload is replayed into a rebuilt `.meta.json` (REC2) |
| `~/Library/Application Support/MeetingPipe/originals/<stem>.wav` | daemon writes | kept full (un-redacted) recording, the recovery source only; 0600, Time-Machine/iCloud-excluded, outside the Library-scanned `raw/` tree (ADR 0016, DOC6) |
| `~/Documents/Meetings/raw/<stem>.{json,md,summary.*,correction.json}` | pipeline writes, daemon reads | transcripts / summaries / corrections |
| `~/Library/Logs/MeetingPipe/` | both | tail-able text logs + JSONL event logs |
| `~/Library/LaunchAgents/com.meetingpipe.daemon.plist` | install.sh writes | LaunchAgent |
| `~/Applications/MeetingPipe.app/` | install.sh / rebuild.sh writes | installed bundle |

Memory hygiene note: don't save file paths from this section into Claude memory — read them here when needed. They change.

---

## Glossary

Project-specific terms. When in doubt, the code is authoritative; this is the orientation index.

---

**AppSource** - the origin of a detection event: bundle id + display name + `.native | .browser` kind + best-effort meeting title. Stable across in-meeting title flips (titles are excluded from `Equatable` / `Hashable`). Defined in `State.swift`.

**AppState** - the recording-side state machine: `.idle`, `.prompting`, `.suppressed`, `.recording`, `.stopping`. Pipeline processing is *not* part of this enum - it lives in a parallel `processingJobs` queue so a new meeting can record while the previous one transcribes. Defined in `State.swift`.

**AX path / AX lockon** - the Accessibility-API descent into a specific NSWindow's subtree. The lifecycle subsystem walks it once at meeting start to find the Leave button (`AXLeaveButtonSignal`), and `MicGate`'s `AXMuteButtonProbe` reads the Mute button's label against `MuteLabels.toml`. Requires the Accessibility TCC permission. `MicGate` falls back to HAL voice-activity detection + RMS when AX is denied or the meeting client is unknown.

**Backend** - which model summarizes the transcript: `"anthropic"` (Claude Sonnet via API), `"local"` (MLX-Qwen on Metal, fully on-device), or `"auto"` (try Anthropic, fall back to local on network/auth failure). Set globally in `summarization.backend` and per-workflow via `workflow.backend`.

**BYO (Bring Your Own summary)** - the "Record (BYO)" prompt option / `summaryMode == .byo` recording path. Captures audio and writes a paste-into-Claude-Code bundle; user hand-summarises in their preferred LLM front-end, saves `<stem>.summary.md` next to the transcript, then runs `mp publish-from-paste <stem>.md` to push it to Notion. Used for sensitive meetings or when the user wants editorial control over the summary.

**cdhash** - the code-signing hash of the daemon binary. macOS TCC keys grants on `(bundle_id, signing_identifier, cdhash)`. The repo has no Apple Developer ID, so the cdhash changes every `swift build`. `install.sh` / `rebuild.sh` re-sign with a *stable* `--identifier com.meetingpipe.daemon` so two of the three TCC key components stay constant, which is enough for grants to survive a rebuild after one Screen Recording toggle.

**Coordinator** - the spine type in `Coordinator.swift`. Owns the `AppState` machine and routes every transition. The place where the lifecycle subsystem, MeetingRecorder, MicGate, PromptWindow, StatusBar, SinkDispatcher, and PermissionsCenter meet.

**Debounce (start / end)** - seconds the detector waits before firing `.started` after a meeting app shows up, or `.ended` after the mic / window signal goes away. Smooths transient noise. Per-app overrides live in `meeting_apps.toml`; browser bundles default to a longer end debounce because window state flickers more.

**Detection signals** - the inputs the `MeetingPipeCore` lifecycle subsystem fuses to decide a meeting started or ended. PRIMARY signals are per-process audio activity, ScreenCaptureKit shareable-content windows, and the AX Leave button; `PromotionEngine` fuses them with a debounce into a `MeetingLifecycleVerdict`. Start detection additionally enumerates and scores concurrent candidate apps via `MeetingSourceScanner` + `MeetingSourceScorer`. Detection no longer depends on the mic being held, so joining a meeting muted is detected fine; mute only affects what `MicGate` records.

**Doctor (`mp doctor`)** - preflight diagnostics: checks secrets, live API access, model availability, config validity. Surfaced as the "Run doctor…" button in Preferences → Integrations.

**Dogfood** - A/B harness in `mp dogfood`. Runs the Anthropic and local backends on the same transcript, scores the outputs, aggregates into a "ship-decision report" so the user can decide whether the local model is good enough yet for daily use.

**Event log** - `~/Library/Logs/MeetingPipe/events.jsonl` (Swift) + `pipeline_events.jsonl` (Python). Append-only JSONL, one event per line. Grepped with `mp logs` and `scripts/tail-events.sh`. See [`CONVENTIONS.md#event-log-schema`](./CONVENTIONS.md#event-log-schema).

**Force-stop hotkey** - second global hotkey (default `⌃⌥⇧M`) that only *stops* a running recording. Pressing it when idle is a no-op, so panic-pressing can't accidentally start a fresh recording. The toggle hotkey (`⌃⌥M`) starts AND stops; force-stop is stop-only.

**Library window** - the daily-driver UI (TECH-A). Lists every recording in `~/Documents/Meetings/raw/`, with summary / transcript / audio / corrections / raw-files tabs in the detail pane. Cmd+L opens it.

**Lockon** - the lifecycle and `MicGate` subsystems walk the meeting window's AX subtree once at recording start and cache the handles (Leave button, Mute button), so they observe the same window for the meeting's lifetime instead of re-walking. `MeetingAXWindowWatcher` picks up call-control windows that appear later.

**Long-meeting guard** - `summarization.skip_above_chars` (default 80 000 ≈ 1 h of speech). When the transcript markdown exceeds this size, `mp run-all` skips summarize + publish and writes a `<stem>.READY_FOR_MANUAL.md` paste-bundle instead, so the user doesn't burn a ~$0.50 Anthropic call on a long meeting they may not even want summarized.

**`<stem>.meta.json`** - see *Sidecar*.

**`<stem>.run.json`, `<stem>.notion.json`** - per-stage output sidecars written by the pipeline so re-runs are idempotent (publishers know which page id they already posted to).

**Mic gate** - the `MicGate` verdict-fusion subsystem (`MeetingPipeCore/MicGate/`) decides, per audio buffer, whether the recorded mic channel carries audio or zero-amplitude frames. `MicGateWriter` applies the verdict in place with a short fade, preserving frame alignment with system audio. The verdict fuses HAL system mute, HAL voice-activity detection, an AX read of the meeting client's Mute button, and a per-buffer RMS gate. See TECH-G-MIC.

**NDA mode** - per-workflow flag (`Workflow.flags.ndaMode`). When true, the workflow's effective backend forces to `"local"` and effective sinks force to `["filesystem"]`, regardless of what the workflow's fields say. The HUD and status-bar title show " · NDA" so the user can confirm at a glance. Distinct from *regulated mode*: NDA is per-workflow, regulated is global.

**Permissions Center** - `PermissionsCenter.shared`. Single source of truth for the four TCC permissions (mic, Screen Recording, Accessibility, Notifications). Polls for live state, publishes a `permissionGranted` PassthroughSubject so the detector wakes up the moment Accessibility flips on mid-meeting.

**Prompt panel / prompt window** - top-right floating panel shown at meeting detection (Notion-style aesthetic). Three actions: Record, Skip, Record (BYO). Dismisses on the configured prompt timeout; the default action (skip / record / byo) is configurable in Preferences → Prompt (TECH-E5).

**Regulated mode** - global flag (`modes.regulated_mode`). When true, the Notion publisher no-ops at upsert time for *every* meeting. Pair with `summarization.backend = "local"` for a fully zero-egress pipeline. Distinct from *NDA mode*: regulated is global, NDA is per-workflow. The status-bar lock glyph (when `UISettings.showRegulatedBadge` is on) signals it.

**Reprompt cooldown** - per-bundle, fixed-duration suppression window after a recording / skip / prompt timeout (default 60 s). Absorbs the post-call mic flicker when Teams' chat surface or Zoom's "your call has ended" toast briefly holds the mic. On the skip path it is paired with the **Skip latch**, which extends suppression for the rest of the meeting. The manual hotkey always bypasses both. See `RepromptCooldown.swift`.

**RMS fallback** - when the AX path is denied or the meeting client is unknown, `MicGate`'s `RMSGateProbe` decides mute from mic energy alone, with asymmetric hysteresis (close after a sustained quiet dwell, open quickly above the louder threshold) so the start of a word is not clipped. HAL voice-activity detection is preferred over RMS when the input device supports it.

**Sidecar** - `<stem>.meta.json` next to every `<stem>.wav`. Carries the resolved `AppSource` + the resolved `Workflow` fields. Written by `MeetingMetaSidecar.build` in Swift, read by `mp.workflow.apply_overrides` in Python. The only contract surface between the two trees. See [`CONVENTIONS.md#sidecar-schema-stem-metajson`](./CONVENTIONS.md#sidecar-schema-stemmetajson).

**Sinks** - output destinations for the published summary: `"notion"`, `"obsidian"`, `"filesystem"`. `publish_router.fanout` runs each sink independently; one failing doesn't block the others. Default `["notion"]`; per-workflow override via `Workflow.sinks`.

**Skip latch** - per-bundle re-prompt suppression that, unlike the fixed **Reprompt cooldown**, is anchored to discovery liveness: dismissing a prompt arms it, every discovery sighting of that app refreshes it, so the skipped meeting stays skipped for its whole lifetime and the latch lapses ~15 s after discovery stops seeing the meeting (i.e. shortly after it ends). It never re-engages the lifecycle, so there is no Leave-button poll to leak, and it is bundle-scoped, so other apps still detect. Blind spot: a new meeting in the *same* app within ~15 s of the previous one ending inherits the latch (no meeting-instance id exists to tell them apart). See `SkippedMeetingLatch.swift`.

**Smart folders** - the left-rail filters in the Library window (Recent / This week / Untagged / per-workflow / per-source-app). Powered by `LibraryScope` + `MeetingFilter`. Pure in-memory; no SQLite yet (see TECH-A3 in the backlog for the FTS5 upgrade path when scale justifies it).

**Transcription** - ASR + speaker diarization, run on-device by the Swift daemon via FluidAudio (Parakeet TDT for ASR, pyannote-community-1 for diarization, both on the Apple Neural Engine). `SinkDispatcher` runs it after a recording stops and writes the transcript sidecar (`<stem>.json` / `<stem>.md`); the Python pipeline then summarizes and publishes. There is no separate transcription subprocess.

**TOML round-trip** - `ConfigStore`'s pattern of reading the config file into a `TOMLTable`, mutating only the fields the UI models, and writing back. Unknown keys (pipeline-side fields the daemon doesn't know about) survive untouched. The point: a UI edit can never blow away a hand-edited pipeline field.

**Workflow** - per-context routing config (TECH-B). Bundles a matching rule (which app / window triggers it), a context prompt, an output backend, sinks, and behavioural flags into one named profile. The user maintains several (one per work context); the matcher picks one per meeting. Stored as one TOML file per workflow in `~/.config/meeting-pipe/workflows/`.
