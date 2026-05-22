# Glossary

Project-specific terms. When in doubt, the code is authoritative; this is the orientation index.

---

**AppSource** — the origin of a detection event: bundle id + display name + `.native | .browser` kind + best-effort meeting title. Stable across in-meeting title flips (titles are excluded from `Equatable` / `Hashable`). Defined in `State.swift`.

**AppState** — the recording-side state machine: `.idle`, `.prompting`, `.suppressed`, `.recording`, `.stopping`. Pipeline processing is *not* part of this enum — it lives in a parallel `processingJobs` queue so a new meeting can record while the previous one transcribes. Defined in `State.swift`.

**AX path / AX lockon** - the Accessibility-API descent into a specific NSWindow's subtree. The lifecycle subsystem walks it once at meeting start to find the Leave button (`AXLeaveButtonSignal`), and `MicGate`'s `AXMuteButtonProbe` reads the Mute button's label against `MuteLabels.toml`. Requires the Accessibility TCC permission. `MicGate` falls back to HAL voice-activity detection + RMS when AX is denied or the meeting client is unknown.

**Backend** — which model summarizes the transcript: `"anthropic"` (Claude Sonnet via API), `"local"` (MLX-Qwen on Metal, fully on-device), or `"auto"` (try Anthropic, fall back to local on network/auth failure). Set globally in `summarization.backend` and per-workflow via `workflow.backend`.

**BYO (Bring Your Own summary)** — the "Record (BYO)" prompt option / `summaryMode == .byo` recording path. Captures audio and writes a paste-into-Claude-Code bundle; user hand-summarises in their preferred LLM front-end, saves `<stem>.summary.md` next to the transcript, then runs `mp publish-from-paste <stem>.md` to push it to Notion. Used for sensitive meetings or when the user wants editorial control over the summary.

**cdhash** — the code-signing hash of the daemon binary. macOS TCC keys grants on `(bundle_id, signing_identifier, cdhash)`. The repo has no Apple Developer ID, so the cdhash changes every `swift build`. `install.sh` / `rebuild.sh` re-sign with a *stable* `--identifier com.meetingpipe.daemon` so two of the three TCC key components stay constant, which is enough for grants to survive a rebuild after one Screen Recording toggle.

**Coordinator** - the spine type in `Coordinator.swift`. Owns the `AppState` machine and routes every transition. The place where the lifecycle subsystem, MeetingRecorder, MicGate, PromptWindow, StatusBar, SinkDispatcher, and PermissionsCenter meet.

**Debounce (start / end)** — seconds the detector waits before firing `.started` after a meeting app shows up, or `.ended` after the mic / window signal goes away. Smooths transient noise. Per-app overrides live in `meeting_apps.toml`; browser bundles default to a longer end debounce because window state flickers more.

**Detection signals** - the inputs the `MeetingPipeCore` lifecycle subsystem fuses to decide a meeting started or ended. PRIMARY signals are per-process audio activity, ScreenCaptureKit shareable-content windows, and the AX Leave button; `PromotionEngine` fuses them with a debounce into a `MeetingLifecycleVerdict`. Start detection additionally enumerates and scores concurrent candidate apps via `MeetingSourceScanner` + `MeetingSourceScorer`. Detection no longer depends on the mic being held, so joining a meeting muted is detected fine; mute only affects what `MicGate` records.

**Doctor (`mp doctor`)** — preflight diagnostics: checks secrets, live API access, model availability, config validity. Surfaced as the "Run doctor…" button in Preferences → Integrations.

**Dogfood** — A/B harness in `mp dogfood`. Runs the Anthropic and local backends on the same transcript, scores the outputs, aggregates into a "ship-decision report" so the user can decide whether the local model is good enough yet for daily use.

**Event log** — `~/Library/Logs/MeetingPipe/events.jsonl` (Swift) + `pipeline_events.jsonl` (Python). Append-only JSONL, one event per line. Grepped with `mp logs` and `scripts/tail-events.sh`. See [`CONVENTIONS.md#event-log-schema`](./CONVENTIONS.md#event-log-schema).

**Force-stop hotkey** — second global hotkey (default `⌃⌥⇧M`) that only *stops* a running recording. Pressing it when idle is a no-op, so panic-pressing can't accidentally start a fresh recording. The toggle hotkey (`⌃⌥M`) starts AND stops; force-stop is stop-only.

**Library window** - the daily-driver UI (TECH-A). Lists every recording in `~/Documents/Meetings/raw/`, with summary / transcript / audio / corrections / raw-files tabs in the detail pane. Cmd+L opens it.

**Lockon** - the lifecycle and `MicGate` subsystems walk the meeting window's AX subtree once at recording start and cache the handles (Leave button, Mute button), so they observe the same window for the meeting's lifetime instead of re-walking. `MeetingAXWindowWatcher` picks up call-control windows that appear later.

**Long-meeting guard** — `summarization.skip_above_chars` (default 80 000 ≈ 1 h of speech). When the transcript markdown exceeds this size, `mp run-all` skips summarize + publish and writes a `<stem>.READY_FOR_MANUAL.md` paste-bundle instead, so the user doesn't burn a ~$0.50 Anthropic call on a long meeting they may not even want summarized.

**`<stem>.meta.json`** — see *Sidecar*.

**`<stem>.run.json`, `<stem>.notion.json`** — per-stage output sidecars written by the pipeline so re-runs are idempotent (publishers know which page id they already posted to).

**Mic gate** - the `MicGate` verdict-fusion subsystem (`MeetingPipeCore/MicGate/`) decides, per audio buffer, whether the recorded mic channel carries audio or zero-amplitude frames. `MicGateWriter` applies the verdict in place with a short fade, preserving frame alignment with system audio. The verdict fuses HAL system mute, HAL voice-activity detection, an AX read of the meeting client's Mute button, and a per-buffer RMS gate. See TECH-G-MIC.

**NDA mode** — per-workflow flag (`Workflow.flags.ndaMode`). When true, the workflow's effective backend forces to `"local"` and effective sinks force to `["filesystem"]`, regardless of what the workflow's fields say. The HUD and status-bar title show " · NDA" so the user can confirm at a glance. Distinct from *regulated mode*: NDA is per-workflow, regulated is global.

**Permissions Center** — `PermissionsCenter.shared`. Single source of truth for the four TCC permissions (mic, Screen Recording, Accessibility, Notifications). Polls for live state, publishes a `permissionGranted` PassthroughSubject so the detector wakes up the moment Accessibility flips on mid-meeting.

**Prompt panel / prompt window** — top-right floating panel shown at meeting detection (Notion-style aesthetic). Three actions: Record, Skip, Record (BYO). Dismisses on the configured prompt timeout; the default action (skip / record / byo) is configurable in Preferences → Prompt (TECH-E5).

**Regulated mode** — global flag (`modes.regulated_mode`). When true, the Notion publisher no-ops at upsert time for *every* meeting. Pair with `summarization.backend = "local"` for a fully zero-egress pipeline. Distinct from *NDA mode*: regulated is global, NDA is per-workflow. The status-bar lock glyph (when `UISettings.showRegulatedBadge` is on) signals it.

**Reprompt cooldown** — per-bundle suppression window after a recording / skip / prompt timeout (default 60 s). Absorbs the post-call mic flicker when Teams' chat surface or Zoom's "your call has ended" toast briefly holds the mic. The manual hotkey always bypasses it. See `RepromptCooldown.swift`.

**RMS fallback** - when the AX path is denied or the meeting client is unknown, `MicGate`'s `RMSGateProbe` decides mute from mic energy alone, with asymmetric hysteresis (close after a sustained quiet dwell, open quickly above the louder threshold) so the start of a word is not clipped. HAL voice-activity detection is preferred over RMS when the input device supports it.

**Sidecar** — `<stem>.meta.json` next to every `<stem>.wav`. Carries the resolved `AppSource` + the resolved `Workflow` fields. Written by `MeetingMetaSidecar.build` in Swift, read by `mp.workflow.apply_overrides` in Python. The only contract surface between the two trees. See [`CONVENTIONS.md#sidecar-schema-stem-metajson`](./CONVENTIONS.md#sidecar-schema-stemmetajson).

**Sinks** — output destinations for the published summary: `"notion"`, `"obsidian"`, `"filesystem"`. `publish_router.fanout` runs each sink independently; one failing doesn't block the others. Default `["notion"]`; per-workflow override via `Workflow.sinks`.

**Smart folders** — the left-rail filters in the Library window (Recent / This week / Untagged / per-workflow / per-source-app). Powered by `LibraryScope` + `MeetingFilter`. Pure in-memory; no SQLite yet (see TECH-A3 in the backlog for the FTS5 upgrade path when scale justifies it).

**Transcription** - ASR + speaker diarization, run on-device by the Swift daemon via FluidAudio (Parakeet TDT for ASR, pyannote-community-1 for diarization, both on the Apple Neural Engine). `SinkDispatcher` runs it after a recording stops and writes the transcript sidecar (`<stem>.json` / `<stem>.md`); the Python pipeline then summarizes and publishes. There is no separate transcription subprocess.

**TOML round-trip** — `ConfigStore`'s pattern of reading the config file into a `TOMLTable`, mutating only the fields the UI models, and writing back. Unknown keys (pipeline-side fields the daemon doesn't know about) survive untouched. The point: a UI edit can never blow away a hand-edited pipeline field.

**Workflow** — per-context routing config (TECH-B). Bundles a matching rule (which app / window triggers it), a context prompt, an output backend, sinks, and behavioural flags into one named profile. The user maintains several (one per work context); the matcher picks one per meeting. Stored as one TOML file per workflow in `~/.config/meeting-pipe/workflows/`.
