# Architecture

Fast subsystem map for finding code. For the *why* behind shape decisions, see [`SPEC.md`](./SPEC.md). For terminology, see [`GLOSSARY.md`](./GLOSSARY.md). For coding patterns, see [`CONVENTIONS.md`](./CONVENTIONS.md).

```
meeting-pipe/
├── daemon/      Swift menu-bar app (detection, recording, UI, hotkeys)
├── pipeline/    Python CLI invoked as `mp <subcommand>` (ASR, summarize, publish)
└── scripts/    install.sh, rebuild.sh, uninstall.sh, dev tools
```

The daemon writes a WAV + sidecar; it spawns the pipeline as a subprocess and forgets about it. The pipeline reads the sidecar, decides what to do per workflow, and writes summaries / publishes. The two processes share contracts via two files on disk: `.meta.json` (per recording) and `events.jsonl` / `pipeline_events.jsonl` (append-only log).

---

## Daemon — `daemon/Sources/MeetingPipe/`

### Lifecycle entry points

- `App.swift` — `@main`. NSApplication accessory app. Reads `UISettings`, applies theme, sets up `ConfigStore` + `SecretsStore`, constructs `Coordinator`, wires `StatusBarController`, kicks off `SystemAudioCapture.prewarm`.
- `Coordinator.swift` — the spine. Owns the `AppState` machine (`State.swift`), drives every transition, dispatches between subsystems. ~1500 lines, the only place where everything meets.

### Detection — "is the user in a meeting?"

- `Detector.swift` — polls `NSWorkspace.shared.runningApplications` + window enumeration on a coalesced background queue. Two-signal AND: known meeting app + mic-active. Fires `.started(AppSource)` / `.ended`.
- `MeetingWindowProbe.swift` — locks onto the specific NSWindow (via AX handle) that hosts the meeting, watches it for close. Source of the "AX lockon" path.
- `Resources/meeting_apps.toml` — per-bundle-id table of which apps are "known meeting apps", their window-title regex hints, and per-app debounce overrides.
- `SilenceDetector.swift` — pure logic: given a stream of mic + system RMS samples, decides when to fire the 90 s "Still meeting?" notify and the 5-min auto-stop (TECH-C2).
- `RepromptCooldown.swift` — per-bundle suppression window after a recording / skip so Teams' post-call mic flicker can't spawn a fresh prompt.
- `MeetingMuteProbe.swift` / `MeetingRecorder.setMicGate(_:)` — TECH-C8 mute tracking. AX path (Teams/Zoom/Meet/Webex Mute button) + RMS fallback. Zeros mic frames while muted so the merged WAV's left channel is silent.

### Recording — "capture what's playing + what I say"

- `MeetingRecorder.swift` — AVAudioEngine for mic capture + the `SystemAudioCapture` source for everything else, mixed and written to disk.
- `SystemAudioCapture.swift` — ScreenCaptureKit + ProcessTap (macOS 14.2+) capture of every-other-process audio. The `excludesCurrentProcessAudio` API is the macOS 14 hard floor.
- `StreamingTranscriber.swift` — spawns `mp transcribe-stream` during the recording so transcription overlaps the meeting (the Tier 2.5 "10–30 s after Stop" win).

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

- `__main__.py` — argv dispatch. Lazy imports per subcommand so `mp --help` doesn't pay torch / whisperx / mlx cost.

### Subcommands (one module each)

| Module | Subcommand | Output |
|---|---|---|
| `transcribe.py` | `mp transcribe <wav>` | `<stem>.json`, `<stem>.md` |
| `transcribe_stream.py` | `mp transcribe-stream` | streamed chunks → final `<stem>.json` |
| `diarize.py` | (called from `transcribe`) | speaker labels |
| `summarize.py` | `mp summarize <transcript.md>` | `<stem>.summary.json`, `<stem>.summary.md` |
| `summarize_local.py` | (called from `summarize`) | on-device MLX path |
| `publish_notion.py` | `mp publish-notion <summary.json>` | Notion page (idempotent) |
| `publish_obsidian.py` | (called via router) | Markdown note in vault |
| `publish_fs.py` | (called via router) | three files in a directory |
| `publish_router.py` | (called from `orchestrate`) | fan-out over `output.sinks` |
| `publish_from_paste.py` | `mp publish-from-paste <transcript.md>` | BYO summary → publish |
| `orchestrate.py` | `mp run-all <wav>` | transcribe → summarize → publish, fail-fast |
| `workflow.py` | (called from `orchestrate`) | applies `.meta.json` overrides |
| `doctor.py` | `mp doctor` | preflight diagnostics |
| `logs_cmd.py` | `mp logs` | `events.jsonl` pretty-printer / filter |
| `dogfood.py` | `mp dogfood` | side-by-side backend comparison |
| `prefetch_model.py` | `mp prefetch-model <repo>` | MLX model download (JSONL progress) |
| `corrections.py` | `mp corrections-stats` | aggregate over correction records |
| `analyze_detection.py` | `mp analyze-detection` | detector failure-mode audit (TECH-C1) |

### Shared services and contracts

- `services.py` — `Protocol`s for the three external dependencies (`SummaryClient`, `Publisher`, `Diarizer`). Concrete implementations live next to use sites; tests inject fakes.
- `schemas.py` — pydantic models. `MeetingSummary` is the JSON contract the publishers expect.
- `config.py` — TOML loader for `~/.config/meeting-pipe/config.toml` + `secrets.env`. Same file the daemon reads.
- `events.py` — Python mirror of Swift's `Log.event`. Appends to `~/Library/Logs/MeetingPipe/pipeline_events.jsonl`.

---

## Data flow

### Detect → record (daemon-only)

```
NSWorkspace + window scan → Detector.started(AppSource)
  → WorkflowMatcher.resolve(source) → Workflow
  → MeetingPromptWindow shown (or auto-consent / always-for-bundle)
  → user clicks Record (or auto / timeout-default)
  → Coordinator.beginRecording(source, summaryMode, workflow)
  → MeetingRecorder writes <stem>.wav  ─┐
  → MeetingMetaSidecar.build → <stem>.meta.json  ┴─ in ~/Documents/Meetings/raw/
  → StreamingTranscriber spawns `mp transcribe-stream` (Tier 2.5)
```

### Stop → process → publish (daemon hands off to pipeline)

```
Detector.ended (or hotkey, or SilenceDetector auto-stop)
  → MeetingRecorder.flush → final WAV closed
  → PipelineLauncher.enqueue(ProcessingJob)
  → mp run-all <wav>:
       orchestrate reads <stem>.meta.json
       workflow.apply_overrides → context_prompt, backend, sinks
       transcribe (offline fallback if streaming failed)
       summarize → Anthropic OR mlx_lm.server (per workflow.backend)
       publish_router fanout → notion + obsidian + filesystem (per workflow.sinks)
       sidecar updates → <stem>.run.json, <stem>.notion.json, …
  → daemon notifies "published"
```

### Cross-cutting

- **`<stem>.meta.json`** — the only Swift→Python contract surface. Schema lives in `MeetingMetaSidecar.swift` (writer) and `mp.workflow.apply_overrides` (reader). Don't add keys to one without the other.
- **Event log** (`events.jsonl` from Swift + `pipeline_events.jsonl` from Python) — one JSON object per line, fields `{ts, category, action, ...attrs}`. Categories Swift writes: `coordinator`, `correction`, `detector`, `library`, `main`, `recorder`, `workflow`. Categories Python writes: `pipeline`, `publisher`, `prefetch`. See [`CONVENTIONS.md`](./CONVENTIONS.md#event-log-schema).
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
| `~/Documents/Meetings/raw/<stem>.{json,md,summary.*,correction.json}` | pipeline writes, daemon reads | transcripts / summaries / corrections |
| `~/Library/Logs/MeetingPipe/` | both | tail-able text logs + JSONL event logs |
| `~/Library/LaunchAgents/com.meetingpipe.daemon.plist` | install.sh writes | LaunchAgent |
| `~/Applications/MeetingPipe.app/` | install.sh / rebuild.sh writes | installed bundle |

Memory hygiene note: don't save file paths from this section into Claude memory — read them here when needed. They change.
