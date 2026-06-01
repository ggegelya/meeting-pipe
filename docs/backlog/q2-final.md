# MeetingPipe Q2 backlog

## Next session priority order (handoff 2026-05-20)

Today shipped 10 commits across G-MIC, C7, C14, locale catalogue, Mermaid diagrams, Preferences expansion, AX walk depth + multi-window + watcher, word-boundary matching, and the transient-unknown latch. 484 tests at session start, 501 at session end, all green.

**P0 — runtime validation gate (user, before any new code)**

Re-install (`./scripts/install.sh`) and run a real Teams English meeting with mute toggles. Tail:
```bash
tail -300 ~/Library/Logs/MeetingPipe/events.jsonl \
  | grep -E '"action":"(ax_handles_built|ax_watcher_rescan|ax_mute_button_state(_kept)?|verdict_changed)"'
```
Expect: `found_mute:true`, `mute_buttons_found:1` (not 2+), `ax_mute_button_state_kept` events during Teams call setup, no spurious `muted_by_app` drops out into RMS while you stay muted.

**P1 — daily-bite bugs, ship next 1-2 sessions, in this order**

1. **TECH-C15 Detector multi-source scoring** `[DONE 2026-05-20]` (see below; M, multi-signal scorer + AX/HAL plumbing). Today's Google Meet drop. Highest user-visible payoff; robust signal that future apps/edge cases inherit.
2. **Watcher initial probe retry on backendFailed(AXError)** `[DONE 2026-05-20]`. Today's latch fix masks this, but adds latency to the first valid AX subscription. Retry after 1-2s, cap 3 attempts. ~20 lines in MeetingAXWindowWatcher.
3. **HAL `!obj` (OSStatus 560947818) in lifecycle_engage_failed** `[DIAGNOSTIC DONE 2026-05-20]`. Diagnostic-first: per-subscription logging in CoreAudioHALBus.subscribe now emits subscribe_attempt + subscribe_failed (with osstatus + osstatus_4cc). Root-cause analysis still owed once a fresh trace lands. Blocks TECH-C13 step 5 (lifecycle stream is never live until this is understood).
4. **End-of-call timeline shift** `[DIAGNOSTIC DONE 2026-05-20]`. User reported a few seconds shift at end of recording. recorder.intermediate_durations event now fires before mergeViaFFmpeg with mic_audio_sec, system_audio_sec, delta_sec, wallclock_sec. Root cause pinned by inspecting the next event trace.

**P2 — queued architectural work**

- TECH-C13 step 5 - verdict-fusion end-detection, retire Detector.swift. Gated on P1.3. [DONE 2026-05-21]
- TECH-A6 — title-prefixed recording filenames. Small, can land anytime.
- TECH-C6 — opportunistic corpus capture during dogfood (harness ready).
- TECH-E4 — dogfood analysis script. Blocked on TECH-C13 step 5.

**P3 — off the critical path**

- TECH-G1 personal two-Mac hub.
- TECH-D8 distribution + notarization.
- Group F compliance docs.

**Critical context for next session**

- User locale: 99% English / Ukrainian. Don't default examples to German. `uk` is in MuteLabels.toml; verify any new uk labels with the user.
- User is vibe-coding: high-level explanations, doesn't read code. Lean on ARCHITECTURE.md Mermaid diagrams.
- Identity: commit with the repository's configured git identity. No em-dashes in any output. Don't push without permission.
- MicGate runtime knobs live in Preferences > Recording > Microphone and Preferences > Prompt > Stop conditions.
- This backlog is the source of truth for TECH-* items.

---

The binding constraint is CLAUDE.md: the primary user is the author, sellability is tertiary, technical excellence in basic functionality comes first. This backlog reorders the prior plan around two principles the prior plan violated: do it right once (no patches that need redesign), and migrate to a Swift-native foundation before adding more layers on top of the Python pipeline.

Priority bands:
- **P0** blocks the daily-use experience.
- **P1** meaningful improvement, not blocking daily use.
- **P2** polish and power-user payoff, including the personal two-Mac Hub.
- **P3** deferred indefinitely, promoted only on a stated trigger.

Size:
- **S** about half a day
- **M** one to two days
- **L** three to five days
- **XL** one to two weeks, typically multiple Claude Code sessions

Conventions: `[DONE]` marks tasks already complete in the working tree. `[NEW]` marks tasks introduced or rewritten in this revision. Each task is written self-contained so one Claude Code session can execute it (or a stated subset, for XL tasks) from the prompt in CLAUDE.md. Files to create or edit are named explicitly. Stop-and-ask triggers are called out for any new dependency, schema change, or user-visible behaviour change.

Claude Code delegation prompt template:
```
Read TECH-{ID} from /home/me/meetingpipe-q2-backlog.md.
Read the relevant existing files in the repo.
Implement the task. Stop and ask before introducing new dependencies.
Run the existing tests before declaring done. Output a summary of
changed files + any decisions you made that weren't specified.
```

---

## Group H · Architectural foundations

**TECH-H1 · Coordinator extraction · L · none** `[DONE]` [NEW priority: moved earlier]

`Coordinator.swift` is around 1500 lines and owns three subordinate responsibilities that must become first-class types before any pipeline or detection work lands. Otherwise the new code paths in Group P and the verdict subsystems in Group C will land in the wrong shape and the next refactor will redo them.

Create:
- `Sources/MeetingPipe/Coordination/DetectionStateMachine.swift` (idle / armed / recording / cooling, transitions, cooldown timer).
- `Sources/MeetingPipe/Coordination/MuteProbeSubsystem.swift` (the periodic mic-state probe seam; the 1Hz poll moves here unchanged for now, to be replaced event-driven in TECH-G-MIC).
- `Sources/MeetingPipe/Coordination/SinkDispatcher.swift` (fanout to writer, transcriber queue, event log).

Edit: `Sources/MeetingPipe/Coordination/Coordinator.swift` shrinks to a thin orchestrator wiring the three subordinates. Target under 400 lines.

Acceptance: existing test suite green; behaviour unchanged; every `Log.event` call preserves name and payload shape; a `--reset-tcc` smoke run produces an `events.jsonl` trace identical to the pre-refactor build modulo timestamps; each subordinate has its own unit test file.

Stop and ask: any change to `Log.event` names; any new dependency; any change to the `recorder.micPaused` seam (that belongs to TECH-G-MIC).

Deps: none. Phase 0 anchor.

**TECH-H4 · CI test audit and gap fill · M · TECH-H1** `[DONE]` [NEW]

Audit the current XCTest targets, list every public seam in `Coordinator` and its new subordinates, and add tests for the seams that currently have none. The goal is to make Phase 1 refactors safe.

Create: `docs/test-coverage.md` listing seams covered and seams not covered with explicit decisions. Edit: existing test targets to fill the documented gaps.

Acceptance: coverage doc exists; the named seams in `DetectionStateMachine`, `MuteProbeSubsystem`, and `SinkDispatcher` each have at least one happy-path and one failure-path test; CI runs in under five minutes.

Stop and ask: any test that requires new fixtures over 1MB; any test that requires a new package dependency.

Deps: TECH-H1.

**TECH-H5 · Doctor command coverage · M · TECH-H1** `[DONE]` [NEW]

The `meetingpipe doctor` subcommand currently probes TCC, audio device presence, and disk space. Extend to probe the things that actually break daily use: AX permission state per app (Teams, Zoom, Slack, Meet host browser, Webex), CoreAudio HAL tap availability, the pipeline binary's launch-and-exit roundtrip, and the events.jsonl writability.

Edit: `Sources/MeetingPipe/CLI/DoctorCommand.swift`.

Acceptance: `meetingpipe doctor` exits non-zero with a precise reason when any probed condition fails; exits zero on a healthy machine; emits one `Log.event("doctor.probe", ...)` per probe.

Stop and ask: any probe that requires elevated privileges; any probe that writes outside the user's container.

Deps: TECH-H1.

**TECH-F10 · CONVENTIONS.md codification · S · none** `[DONE]` [NEW]

Capture the conventions already enforced in the codebase but not yet written down. The em-dash lint already lives in the pre-commit hook; the `Log.event` vs `Log.writeLine` distinction is implicit in the source but undocumented.

Create: `CONVENTIONS.md` covering: no em-dashes (hyphen, comma, or rewrite); `Log.event` for structured fields consumed by events.jsonl analysis, `Log.writeLine` for human-readable narrative log only; file headers; Swift naming; error propagation pattern (`Result<T, MeetingPipeError>` at module boundaries, `throws` inside modules); test file naming.

Acceptance: file exists; pre-commit hook references it; one violation deliberately introduced in a throwaway branch is caught by CI.

Deps: none. Can run in parallel with TECH-H1.

---

## Group P · Pipeline migration to Swift [NEW group]

This group migrates ASR and diarization off the Python sidecar onto Swift-native, ANE-accelerated equivalents. It runs after Group H so the new code paths land in the extracted Coordinator surface, not in the 1500-line monolith. It runs before Group C (capture and detection) because the unified verdict subsystems in C13 and G-MIC surface to a transcription layer that is materially different post-migration.

**TECH-P0 · Parakeet language benchmark · M · none** `[DONE]` [NEW]

Before committing to Parakeet, verify that quality on the user's own voice and typical interlocutor languages clears the bar. Parakeet-TDT-0.6B-v2 is English-only; Parakeet-TDT-0.6B-v3 ships multilingual support but quality on the user's languages must be measured, not assumed. If Parakeet fails the bar the rest of Group P is wrong and the user needs to know that before sinking weeks into it.

Create: `bench/parakeet-vs-whisperx/` containing a small fixture set (10 to 20 clips, 30 to 60 seconds each, covering the languages the user actually uses, drawn from the user's existing recordings with consent-of-self only). Edit: none.

Acceptance: a report file `bench/parakeet-vs-whisperx/REPORT.md` with WER per clip per model, observed latency, and a go/no-go recommendation. WER computed against a hand-corrected reference transcript. The fixture set is checked in (or referenced if it cannot be committed for size reasons; in that case the build script regenerates them locally).

Stop and ask: if Parakeet WER on any user-relevant language is worse than WhisperX by more than 3 absolute points, stop and discuss before proceeding to TECH-P1.

Deps: none.

**TECH-P1 · FluidAudio integration · L · TECH-P0 go** [NEW; landed 2026-05-16. Default backend flipped to FluidAudio via `[transcription] backend = "fluidaudio"`; runner runs pre-pipeline in SinkDispatcher; Python orchestrator accepts the sidecar; toggle exposed in Preferences → Pipeline. Runtime acceptance (ANE residency via powermetrics, ukrainian dogfood checkpoint per REPORT.md) owed by user.]

Bring FluidAudio in as the Swift-native ASR + diarization runner. Parakeet-TDT-0.6B-v3 for ASR (assuming TECH-P0 cleared it), pyannote-Community-1 for diarization, both via the FluidAudio Swift package. Targets ANE on Apple Silicon.

Create: `Sources/MeetingPipe/Transcription/FluidAudioRunner.swift` implementing the existing `TranscriptionRunner` protocol. Edit: `Package.swift` to add FluidAudio; `Sources/MeetingPipe/Transcription/TranscriptionService.swift` to route to the new runner behind a build flag for the first iteration.

Acceptance: a recorded fixture produces a transcript with speaker labels through FluidAudioRunner; the output structure matches the existing sidecar JSON schema field for field (so downstream library code does not change yet); ANE usage observable via `powermetrics` during a run.

Stop and ask: any FluidAudio API that requires user-visible permission beyond what is already granted; any model download larger than 2GB; any sidecar field that cannot be filled from FluidAudio output.

Deps: TECH-P0.

**TECH-P2 · WhisperX retirement · M · TECH-P1** `[DONE]` [NEW; landed 2026-05-17 alongside TECH-P4. The Python MLX-Whisper / faster-whisper ASR path is fully removed. `pipeline/src/mp/transcribe.py` is gone; `render_markdown` moved to `pipeline/src/mp/markdown.py`. `mlx-whisper` and `faster-whisper` deps dropped. No `[transcription] backend = "pipeline"` toggle remains.]

Once TECH-P1 has produced parity transcripts on the benchmark fixtures, remove the WhisperX code path. Keep the Python sidecar binary scaffold in place for one revision so a rollback flag still works, then delete in TECH-P4.

Edit: `Sources/MeetingPipe/Transcription/TranscriptionService.swift` to make FluidAudioRunner the default; remove the build flag from TECH-P1. Edit: `pipeline/whisperx_runner.py` deleted. Edit: `pipeline/requirements.txt` cleaned.

Acceptance: a fresh checkout transcribes a fixture without WhisperX present; no Python import errors on launch; events.jsonl `transcription.engine` field reads `fluidaudio` for all new recordings.

Stop and ask: any user-visible regression in transcript formatting (timestamps, paragraph breaks, speaker label format).

Deps: TECH-P1.

**TECH-P3 · sherpa-onnx retirement · M · TECH-P1** `[DONE]` [NEW; landed 2026-05-16. Swift FluidAudio diarization (P1) supersedes sherpa-onnx end-to-end. Python fallback retires the sherpa-onnx code paths: `mp.diarize` keeps only channel-aware helpers, `mp.transcribe` / `mp.transcribe_stream` / `mp.orchestrate` drop the embedding-diarization branches, doctor and pyproject no longer mention sherpa-onnx. Mono inputs on the Python fallback degrade to Speaker?; stereo (the daemon's normal output) labels by channel.]

Replace the sherpa-onnx diarization path with the FluidAudio pyannote runner.

Edit: `Sources/MeetingPipe/Transcription/DiarizationService.swift`; delete the sherpa-onnx Python bridge files.

Acceptance: diarization runs through FluidAudio; speaker labels appear in transcripts; sidecar JSON schema unchanged from the library's point of view.

Stop and ask: any change to the speaker-label string format (`spk_0`, `spk_1`, etc).

Deps: TECH-P1.

**TECH-P4 · Python sidecar scope decision · M · TECH-P2, TECH-P3** `[DONE]` [NEW; landed 2026-05-17. Decision documented in `docs/decisions/0007-python-sidecar.md` (Accepted, Option B): retire the Python transcription sidecar (streaming subprocess + offline ASR + `backend` toggle); keep the Python pipeline binary for summarize + publish because outbound HTTP must stay out of the daemon per `CLAUDE.md`. `StreamingTranscriber.swift`, `mp/transcribe.py`, `mp/transcribe_stream.py` deleted; FluidAudio is now the only ASR path; the orchestrator errors loudly on a missing daemon sidecar.]

After WhisperX and sherpa-onnx are gone, the Python sidecar is doing very little. Decide: keep it as an orchestration thin layer (audio normalisation, ffmpeg invocation, sidecar JSON assembly) or eliminate it entirely by porting the remaining steps to Swift.

Recommendation to evaluate: **eliminate it.** Reasoning: every remaining Python responsibility has a Swift equivalent (AVFoundation for audio normalisation; a vendored ffmpeg invocation from Swift via `Process` is already in `MediaWriter.swift`; JSON assembly is trivial). Keeping Python alive means keeping a Python distribution shipped with the app, which costs disk, launch time, and `--reset-tcc` complexity for no transcription benefit post-P2/P3. The subprocess drain pattern (`readabilityHandle` + line buffering) becomes irrelevant when the work is in-process.

Create or edit: depends on the decision. If eliminating, port `pipeline/normalize.py` and `pipeline/assemble_sidecar.py` to `Sources/MeetingPipe/Pipeline/*.swift`.

Acceptance: documented decision in `docs/decisions/0007-python-sidecar.md`; if eliminating, app bundle no longer contains a Python distribution; cold launch time drops measurably (record before and after); `doctor` no longer probes Python.

Stop and ask: confirm the decision before executing.

Deps: TECH-P2, TECH-P3.

---

## Group C · Capture and detection [renamed from "Detection"]

**TECH-C1 · CoreAudio HAL tap capture** `[DONE]`

**TECH-C2 · Per-app audio routing detection** `[DONE]`

**TECH-C3 · AX trigger-word probe for Teams, Zoom, Meet** `[DONE]` (superseded by TECH-G-MIC architecture; current code remains in place until TECH-G-MIC lands.)

**TECH-C4 · Hardware mute observer via CoreAudio property listener** `[DONE]`

**TECH-C5 · Auto-stop on app teardown for Teams and Zoom** `[DONE]` (superseded by TECH-C13 architecture; current code remains in place until TECH-C13 lands.)

**TECH-C13 · MeetingLifecycleCoordinator verdict subsystem · XL · TECH-H1, TECH-P4** [NEW, replaces the brittle Teams-AX-Leave-button-plus-title-pattern detector] [steps 1-4 DONE 2026-05-17 in new MeetingPipeCore SPM target: shared infra (CoreAudioHALBus + AXObserverBus + EventLog) plus real CoreAudio/AX backends; PRIMARY signals (Process, ShareableContent, AXLeaveButton); corroborating signals (InputDevice, WindowTitle, Workspace, CalendarContext); per-app adapters (Teams, Zoom, Webex, Browser) with locale-tolerant title patterns; PromotionEngine encodes the verdict-fusion rules + 2.0s debounce. Step 5 DONE 2026-05-21 in seven commits (TECH-C13 step 5/5 parts 1-7): the lifecycle verdict stream owns recording-end (parts 1-2); MeetingSourceScanner + MeetingTitleResolver extracted and the shadow-mode MeetingDiscoveryWatcher added (parts 3-5); start detection migrated onto the lifecycle subsystem, PromotionEngine .idle then .starting then .inMeeting with a confirmRecording() promotion (part 6); Detector.swift + MeetingWindowProbe.swift deleted (part 7). swift build + 501 tests green. Runtime acceptance on Teams/Zoom/Webex/Meet still owed by the user; native Skype and native Google Meet have no lifecycle adapter and no longer auto-detect (decision owed).]

Replaces the existing end-detection path with a verdict-fusion subsystem that surfaces a single `MeetingLifecycleVerdict` to `RecordingStateMachine` through an `AsyncStream`. The coordinator consumes PRIMARY signals from `ShareableContentSignal` (SCShareableContent polled at 2 Hz when a meeting is active and 1 Hz otherwise, filtered by `owningApplication.bundleIdentifier` and a locale-tolerant title regex), `ProcessAudioSignal` (per-process `kAudioProcessPropertyIsRunningInput` on the meeting-app AudioObject, listener registered plus 1 Hz polling fallback, excluded as primary for Webex), `AXLeaveButtonSignal` (cached `AXUIElementRef` on the Leave button, observed via `kAXUIElementDestroyedNotification`, health-polled at 1 Hz with `kAXErrorInvalidUIElement` treated as authoritative), and `SCStream` stopped signals when the daemon owns a stream. Corroborating signals are `WorkspaceSignal` (`NSWorkspaceDidTerminateApplicationNotification`, `NSRunningApplication` KVO), AX title-change on the meeting window, `CGWindowList` HUD-window disappearance polled at 0.5 Hz, EventKit scheduled-end hysteresis, and optional Graph presence or Slack `user_huddle_changed` when the user provides cloud tokens.

The verdict transitions through `.idle`, `.starting`, `.inMeeting`, `.endingProvisional` (any one PRIMARY satisfied), and `.ended` (a second PRIMARY confirming or 2.0 second debounce elapsing with the leading signal still satisfied). `RecordingStateMachine` consumes the verdict and closes the WAV on `.ended`. The 2.0 second debounce absorbs the post-call chat surface mic-grab cleanly without RepromptCooldown.

The cached AX Leave-button reference is obtained from the same AX-tree walk that TECH-G-MIC uses for the Mute button, through a shared `AXObserverBus` introduced here. HAL property listeners are registered through a shared `CoreAudioHALBus` introduced here. Every signal change and verdict transition is logged to `events.jsonl`.

Per-app behaviour: Teams native (com.microsoft.teams2 and legacy com.microsoft.teams), Zoom (us.zoom.xos), and Webex (com.cisco.webexmeetingsapp legacy and com.cisco.spark unified) each have their own adapter. Webex specifically excludes `kAudioProcessPropertyIsRunningInput` from PRIMARY signals because Cisco documents that Webex holds the microphone open after meetings for ultrasound device discovery. Browser-hosted meetings (Teams web, Meet, Webex web, Slack PWA) use a single browser adapter that takes the active-tab title from `CGWindowListCopyWindowInfo` and matches against meeting-URL patterns; the documented hardest case is Google Meet, for which the leading PRIMARY is browser-tab title transition off the `Meet · <code>` pattern.

Create:
- `Sources/MeetingPipeCore/Lifecycle/MeetingLifecycleCoordinator.swift`
- `Sources/MeetingPipeCore/Lifecycle/MeetingLifecycleVerdict.swift`
- `Sources/MeetingPipeCore/Lifecycle/Signals/ProcessAudioSignal.swift`
- `Sources/MeetingPipeCore/Lifecycle/Signals/InputDeviceSignal.swift`
- `Sources/MeetingPipeCore/Lifecycle/Signals/ShareableContentSignal.swift`
- `Sources/MeetingPipeCore/Lifecycle/Signals/AXLeaveButtonSignal.swift`
- `Sources/MeetingPipeCore/Lifecycle/Signals/WindowTitleSignal.swift`
- `Sources/MeetingPipeCore/Lifecycle/Signals/WorkspaceSignal.swift`
- `Sources/MeetingPipeCore/Lifecycle/Signals/CalendarContextSignal.swift`
- `Sources/MeetingPipeCore/Lifecycle/Adapters/TeamsLifecycleAdapter.swift`
- `Sources/MeetingPipeCore/Lifecycle/Adapters/ZoomLifecycleAdapter.swift`
- `Sources/MeetingPipeCore/Lifecycle/Adapters/WebexLifecycleAdapter.swift`
- `Sources/MeetingPipeCore/Lifecycle/Adapters/BrowserMeetingLifecycleAdapter.swift`
- `Sources/MeetingPipeCore/Infra/CoreAudioHALBus.swift` (shared with TECH-G-MIC)
- `Sources/MeetingPipeCore/Infra/AXObserverBus.swift` (shared with TECH-G-MIC)
- `Sources/MeetingPipeCore/Infra/EventLog.swift` (shared with TECH-G-MIC)

Edit:
- `Sources/MeetingPipe/Coordination/DetectionStateMachine.swift` consumes `AsyncStream<MeetingLifecycleVerdict>` instead of the old per-app probes.
- `Sources/MeetingPipe/Coordination/Coordinator.swift` wires up `MeetingLifecycleCoordinator`.
- Removes the existing Teams-AX-Leave-button-only detector and the window-title-pattern matcher.

Acceptance:
- Joining and leaving a Teams 2.x call in English produces events.jsonl entries `inMeeting` then `endingProvisional` with `leadingSignal: "shareable_content_window_gone"` within 800 ms of clicking Leave, then `ended` within 2.0 seconds total with `confirmedBy` containing both `"shareable_content_window_gone"` and `"process_audio_is_running_input_false"`.
- The WAV closes cleanly with no audio from the post-call chat surface present in the file.
- Joining and leaving a Zoom call produces the same transitions with the Zoom adapter.
- Joining and leaving a Webex call produces `.ended` with `confirmedBy` containing `"shareable_content_window_gone"` and `"ax_leave_button_invalid"` but never `"process_audio_is_running_input_false"`.
- Joining and leaving a Google Meet call in Chrome produces `.ended` with `leadingSignal: "browser_tab_title_left_meet_pattern"`.
- The AX tree is walked exactly once per meeting (verified by an assertion counter exposed in debug builds).
- `kAXUIElementDestroyedNotification` dropout on Sequoia does not prevent `.ended` within 2.5 seconds of Leave (verified by killing the notification path in a test build and confirming the health-poll path fires).

Stop and ask:
- If `SCShareableContent` returns empty arrays at daemon startup, indicating Screen Recording TCC is not granted. Surface a `SetupRequired` state instead of running with degraded signals.
- If `kAudioProcessPropertyIsRunningInput` listener never fires for the Teams or Zoom process on the user's Mac during initial integration. File a Feedback Assistant ticket and fall back to 1 Hz polling for that PID; do not ship a polling-only path silently.
- If the post-call chat surface mic-grab exceeds 2.0 seconds on the user's specific Teams build. Extend the debounce to 3.0 seconds after measurement, not before.
- The Webex unified-app bundle ID should be verified at integration time against the user's actual install; if Cisco has shipped a different identifier, surface it before hardcoding.

Decomposition guide for multi-session execution:
1. Shared infra (`CoreAudioHALBus`, `AXObserverBus`, `EventLog`) plus verdict types plus Coordinator skeleton. Run existing tests green.
2. Three primary signal files (Process, ShareableContent, AXLeaveButton). Wire to events.jsonl. Validate per-signal output manually with the existing detector still in place.
3. Remaining signal files (InputDevice, WindowTitle, Workspace, Calendar).
4. Adapters (Teams, Zoom, Webex, Browser) plus coordinator promotion rules plus the 2.0 s debounce.
5. Wire to `RecordingStateMachine`; remove the old detector; full acceptance pass.

Deps: TECH-H1, TECH-P4.

**TECH-G-MIC · MicGate verdict subsystem · XL · TECH-C13** [NEW, replaces MeetingMuteProbe and the recorder.micPaused boolean seam] [DONE 2026-05-18: steps 1-6 landed in MeetingPipeCore 2026-05-17; step 7 (executable wiring) landed 2026-05-18: MuteProbeSubsystem and MeetingMuteProbe deleted, recorder.micPaused replaced with MicGateWriter.apply per buffer (frame parity preserved per ADR 0009), Coordinator now constructs MeetingLifecycleCoordinator + MicGate with all 5 lifecycle + 6 mute adapters and a LogEventAdapter bridging EventLog to Log.event, verdict-consumer Task forwards MicGateVerdict to recorder + MicOnlySilenceBackstop on the main actor, onMicRmsDb feeds MicGate.ingest from the mic tap allocation-free. Runtime acceptance pass (Teams/de, Meet silence, hardware mute, USB-no-VAD, allocation-free render thread) still owed to user and tracked under Phase 2 dogfood.]

Replaces `MeetingMuteProbe` with `MicGate`, a verdict-fusion subsystem that determines whether the recorded left channel should contain microphone audio or zero-amplitude frames at each buffer boundary. The verdict fuses HAL Voice Activity Detection on the default input device (`kAudioDevicePropertyVoiceActivityDetectionEnable`, `kAudioDevicePropertyVoiceActivityDetectionState`, scope `kAudioDevicePropertyScopeInput`, macOS 14.0+), an RMS energy gate inside the existing AVAudioEngine input tap with asymmetric hysteresis (close at sustained -55 dBFS for 350 ms, open at sustained -45 dBFS for 80 ms), Accessibility observation of the meeting-app Mute button against a locale TOML covering en, es, fr, de, ja, pt, ru, and HAL system-input mute via `kAudioObjectPropertyMute` on the default input device. The verdict is one of `.hot`, `.mutedByApp`, `.mutedByHardware`, `.silentByRMS`, `.uncertain`, each with reasoning attached for the audit log.

**Precedence rules.** `.mutedByHardware` wins if HAL system-input mute is true. Otherwise `.mutedByApp` wins if AX scrape returns a "muted" label that matches the locale TOML. Otherwise `.silentByRMS` wins if RMS has been below the close threshold for the sustained dwell. Otherwise `.hot` if VAD is active or RMS is above the open threshold. Otherwise `.uncertain` with reasons listed.

**Writer behaviour.** The writer emits zero-amplitude frames with a 20 ms fade on transitions whenever the verdict is anything but `.hot`. The fade is computed in the writer, not in the gate. Frames are never skipped: skipping would break sample alignment with the ScreenCaptureKit ProcessTap right channel because the writer cannot know how many frames the right channel will produce in the same wall-clock interval. Stopping the writer entirely would create a discontinuity in the WAV that downstream diarization and silent-system-audio detection cannot recover from. Writing zero frames preserves alignment and produces a recording that audibly contains silence on the left when muted, audio on the left when speaking, with no glitches at transition boundaries.

**Shared infrastructure.** The Mute button `AXUIElementRef` is obtained from the single AX-tree walk that TECH-C13's `MeetingLifecycleCoordinator` performs at meeting start, retained for the meeting lifetime, observed via `kAXValueChangedNotification` and `kAXTitleChangedNotification` on the shared `AXObserverBus` per PID, and health-polled at 1 Hz via `AXUIElementCopyAttributeValue` to absorb Sequoia destruction-notification dropouts. HAL VAD is enabled at meeting start via `kAudioDevicePropertyVoiceActivityDetectionEnable` and observed through the shared `CoreAudioHALBus`. The AX tree is not re-walked during the meeting.

**Per-platform behaviour.** Teams native and browser, Zoom native, Slack native and PWA, Webex native and browser: AX is PRIMARY when the locale TOML resolves; HAL VAD plus RMS are PRIMARY when AX fails. Meet (browser only) and unrecognized locales fall through to HAL VAD plus RMS only, which produces `.silentByRMS` when the user is not speaking. No public per-tab mute signal exists for browsers, by Apple's API surface as of macOS 14-15.

**Localization.** `Sources/MeetingPipeCore/MicGate/Locale/MuteLabels.toml` is keyed by app and locale. Microsoft, Zoom, Cisco, Slack, and Google publish no developer-consumable localization tables, so the TOML is maintained from observation. A CI tool `MuteLabelsValidator` validates the TOML against the AX tree of each app installed in each locale; when a vendor ships a label drift, the CI job fails and the project ships a TOML update.

Create:
- `Sources/MeetingPipeCore/MicGate/MicGate.swift`
- `Sources/MeetingPipeCore/MicGate/MicGateVerdict.swift`
- `Sources/MeetingPipeCore/MicGate/MicGateWriter.swift`
- `Sources/MeetingPipeCore/MicGate/Probes/HALVoiceActivityProbe.swift`
- `Sources/MeetingPipeCore/MicGate/Probes/RMSGateProbe.swift`
- `Sources/MeetingPipeCore/MicGate/Probes/AXMuteButtonProbe.swift`
- `Sources/MeetingPipeCore/MicGate/Probes/HALSystemMuteProbe.swift`
- `Sources/MeetingPipeCore/MicGate/Probes/InternalSpeechProbe.swift`
- `Sources/MeetingPipeCore/MicGate/Locale/MuteLabels.toml`
- `Sources/MeetingPipeCore/MicGate/Locale/MuteLabelsLoader.swift`
- `Sources/MeetingPipeCore/MicGate/Locale/MuteLabelsValidator.swift` (CI tool)
- `Sources/MeetingPipeCore/MicGate/Adapters/TeamsMuteAdapter.swift`
- `Sources/MeetingPipeCore/MicGate/Adapters/ZoomMuteAdapter.swift`
- `Sources/MeetingPipeCore/MicGate/Adapters/WebexMuteAdapter.swift`
- `Sources/MeetingPipeCore/MicGate/Adapters/MeetMuteAdapter.swift`
- `Sources/MeetingPipeCore/MicGate/Adapters/SlackMuteAdapter.swift`
- `Sources/MeetingPipeCore/MicGate/Adapters/BrowserMuteAdapter.swift`

Edit:
- `Sources/MeetingPipe/Coordination/MuteProbeSubsystem.swift` becomes a thin subscriber to `MicGate`'s `AsyncStream<MicGateVerdict>`.
- `Sources/MeetingPipe/Recording/Recorder.swift` removes `recorder.micPaused: Bool` and replaces it with the per-buffer `MicGateWriter.apply(verdict:to:)` call.
- Removes `Sources/MeetingPipe/MeetingMuteProbe.swift` and all references.

Acceptance:
- With Teams in German locale, joining a call and toggling mute, events.jsonl shows `micgate` transitions `hot` to `mutedByApp` with `axLabel: "Stummschaltung aufheben"` and `locale: "de"`.
- With Meet in any browser, joining a call and remaining silent, events.jsonl shows `micgate` transitions to `silentByRMS` within 400 ms of speech cessation, and the recorded left channel contains zero-amplitude frames with sample alignment preserved against the right channel (verified by frame-count equality between channels in the resulting WAV).
- With Control Center mic muted, events.jsonl shows `mutedByHardware`.
- With a USB mic that does not support HAL VAD, the daemon logs `signal:vad_unsupported` once at startup and operates correctly on RMS only.
- The 1 Hz health-poll of the Mute button AX element fires within 1.5 seconds of a `kAXValueChangedNotification` dropout (verified by killing the notification path in a test build).
- No allocations occur on the audio render thread (verified by Instruments allocations track during a 5-minute recording).

Stop and ask:
- If the TOML for any of the seven locales returns zero matches against a live Teams 2.x install during initial integration. Surface the missing locale, do not ship with an empty list.
- If HAL VAD enable returns `kAudioHardwareUnknownPropertyError` on the user's built-in mic on their Apple Silicon target. The daemon should detect at startup and fall through to RMS-only gating for that device, but confirm the fallback is the correct behaviour for that hardware before shipping.
- If frame-count equality fails between left and right channels by more than one frame in any 10-minute recording.
- If any RMS computation in the tap callback requires allocation or locking, surface that as a separate design problem rather than working around it.

Decomposition guide for multi-session execution:
1. Probes scaffolding: `HALSystemMuteProbe`, `HALVoiceActivityProbe`, `RMSGateProbe`. Verify each emits state changes independently against a manual test.
2. Locale loader plus initial TOML for en, de (the user's confirmed need cases). `MuteLabelsValidator` skeleton.
3. `AXMuteButtonProbe` reusing the AX walk from TECH-C13. Adapters for Teams, Zoom, Slack.
4. `MicGate` coordinator plus precedence rules plus `MicGateVerdict` events. Wire to events.jsonl.
5. `MicGateWriter` plus 20 ms fade plus integration with `Recorder.swift`. Remove `MeetingMuteProbe`.
6. Remaining adapters (Webex, Meet, Browser). Remaining locales (es, fr, ja, pt, ru). Full acceptance pass.

Deps: TECH-C13 (shares the one-time AX walk and shared infra files).

**TECH-C6 · Detection regression test corpus · M · TECH-C13, TECH-G-MIC** [REVISED] [HARNESS DONE 2026-05-17: trace format + INDEX.json + replay test (DetectionCorpusTests) live under daemon/Tests/MeetingPipeCoreTests/Fixtures/detection-corpus/. Eight synthetic seed traces lock in the load-bearing scenarios (Teams clean leave, Teams post-call chat-grab, Zoom clean leave, Webex ultrasound retention, Google Meet, plus MicGate precedence corners). 20+ user-recorded traces from the Phase 2 dogfood window remain owed.]

Build a regression corpus from the user's own fortnight of dogfood usage (Phase 2 dogfood window). Capture each meeting's signal stream (`MeetingLifecycleVerdict` transitions, `MicGateVerdict` transitions, AX state log, HAL VAD stream) and ground-truth start/stop and mute/unmute times. Fixtures stored as compact replay traces, not full audio, so they can live in git.

Create: `tests/detection-corpus/` containing one trace file per recorded scenario plus an index. Edit: `Tests/DetectionTests/CorpusTests.swift` to iterate the index.

Acceptance: at least 20 traces covering Teams, Zoom, Meet (Chrome and Arc), Slack huddle (native and PWA), Webex (native and PWA), mic-only-silence false-positive scenarios, rapid mute-toggle scenarios, and post-call chat surface mic-grab scenarios; CI runs all traces in under 30s; any new regression to detection or gating logic must update fixtures or fail.

Deps: TECH-C13, TECH-G-MIC.

**TECH-C7 · Mic-only-silence backstop · S · TECH-C13** [DONE 2026-05-18: pure logic landed in MeetingPipeCore 2026-05-17 (MicOnlySilenceBackstop with synthetic-trace tests covering window-elapsed trigger, system-audio reset, hot reset, sticky-trigger, reset re-arm, app-muted-with-no-system-audio). Executable wiring landed 2026-05-18: Coordinator constructs the backstop with the window read from `[detection] mic_only_silence_seconds` (default 480), feeds it each MicGateVerdict alongside a hasSystemAudio derived from recorder.onSystemLevel (threshold mirrors SilenceDetector.defaultThresholdDb at -50 dBFS), and routes onTriggered into the existing forceStop(reason: "mic_only_silence") path. Config.swift + ConfigStore.swift round-trip the knob; config.example.toml documents it.]

When the only audio source is the local mic and the `MicGateVerdict` is `.silentByRMS` for longer than the configured backstop window (default 8 minutes), stop the recording. This catches the case where the user joins a meeting, the other participants drop, and the user forgets to stop recording.

Edit: `Sources/MeetingPipe/Coordination/DetectionStateMachine.swift`. Acceptance: backstop fires in a unit test with a synthetic silence trace; configurable via `~/.meetingpipe/config.toml` under `[detection] mic_only_silence_seconds`.

Deps: TECH-C13 (consumes the `MicGateVerdict` stream).

**TECH-C14 · Dynamic AX window watcher · M · TECH-G-MIC** [DONE 2026-05-20: MeetingAXWindowWatcher subscribes to kAXWindowCreatedNotification on the AX application at engage time. On each notification + once at start (for already-open windows), rescans every AX window for mute buttons via the existing MeetingAXHandleBuilder predicate and spins up a fresh AXMuteButtonProbe per match. Events flow into MicGate.injectAxMuteEvent (new public API) which merges them into the same precedence chain as the primary adapter's events. Coordinator owns the watcher per-meeting; created in engageMicGate, torn down alongside lifecycleCoord.disengage() in stopRecording. Each rescan emits coordinator.ax_watcher_rescan with window_count + mute_buttons_found + active_probes for diagnostic visibility. Verified via Accessibility Inspector dump on a live Teams call: compact-view NSPanel ("Meeting compact view | Echo | Microsoft Teams (system dialog)") is owned by the same com.microsoft.teams2 process, has the same Calling controls toolbar with Unmute mic button at AXButton role and same English labels, so the existing predicate matches once the watcher rescans. Lifecycle leave-button rediscovery on the compact view deferred (uncommon need; user can leave from either window).]

Reactive AX subscription so mute / leave clicks from secondary windows that appear AFTER `beginRecording` are still observed.

Symptom: Teams 2 shows a small floating call-control overlay when the user backgrounds the main meeting window. Clicking Mute on that overlay does not flip MicGate's verdict because the AX walk in `MeetingAXHandleBuilder.build` runs once at meeting-start and captures only the buttons present at that moment; the overlay is created later.

Current flow:
1. `Coordinator.beginRecording` -> `MeetingAXHandleBuilder.build` (single AX walk)
2. `AXMuteButtonProbe.start` subscribes to AX notifications on the one button reference returned by step 1
3. No re-walking happens for the duration of the meeting

Reactive fix (proposed):
- Subscribe at the AX application level to `kAXWindowCreatedNotification` for the duration of a meeting.
- On notification, walk the new window for mute + leave buttons using the existing predicates.
- For each new mute button found, attach an additional `AXMuteButtonProbe` and merge its events into MicGate's state (`axMute`, `axLabel`, `axLocale`). For each new leave button found, attach an `AXLeaveButtonSignal`.
- On `kAXUIElementDestroyedNotification` for the parent window, drop the corresponding subscriptions.
- MicGate currently has a single `activeAdapter`; extend it (or move to a multi-adapter list) so multiple buttons from the same app feed the same state machine.

Stop and ask:
- Capture AX hierarchy for the Teams 2 floating overlay BEFORE coding. We need to confirm whether the overlay is (a) a new `AXWindow` in the same `com.microsoft.teams2` process, (b) an `AXSheet` attached to the main window, or (c) a separate helper process. Each case wants a different code path; guessing is not safe. Accessibility Inspector capture procedure: open Teams meeting, background main window, point Inspector at the overlay's Mute button, lock with `⌥Space`, screenshot the Hierarchy panel.
- If the overlay turns out to be in a separate process, we may need to add a helper-bundle-id list to the lifecycle / mute adapters and either subscribe across both PIDs or accept that the overlay case requires a different mechanism (e.g., HAL VAD becomes more important).

Edits:
- `Sources/MeetingPipe/MeetingAXHandleBuilder.swift` (or split into a new `MeetingAXWindowWatcher.swift`): drive the window-created subscription, expose a callback for each newly-discovered button.
- `Sources/MeetingPipeCore/MicGate/MicGate.swift`: allow attaching additional `MicGateAdapter` probes after `start` so dynamically-discovered buttons can join the state machine. Today `activeAdapter` is a single optional.
- `Sources/MeetingPipeCore/Lifecycle/MeetingLifecycleCoordinator.swift`: same shape for the lifecycle leave-button signal.

Acceptance:
- During a Teams meeting, background the main window so the floating overlay appears. Click Mute on the overlay. Within ~1 s an `events.jsonl` entry shows `micgate.verdict_changed` with `verdict: muted_by_app`.
- Stopping a meeting tears down all dynamically-added subscriptions; a second meeting starts clean.
- A unit test seeds a fake AX bus that emits `windowCreated` notifications and asserts the watcher walks the new window, adds the probe, and emits the expected verdict transition.

Deps: TECH-G-MIC (consumer). Land after the depth-bump fix (commit e61cc29) has been validated in dogfood so we know the main-window case works reliably first.

**TECH-C15 · Detector multi-source scoring · M · none** [DONE 2026-05-20: MeetingSourceScorer (pure) + MeetingSourceCandidate land in MeetingPipe with 19 synthetic tests (weights, threshold, 2-distinct-signal floor, sticky tie-break, 2026-05-20 incident scenario). MeetingAXHandleBuilder grows findAllLeaveButtons + findCallingControlsToolbar (per-bundle needles for Teams "Calling controls" / Meet "Meeting controls"). Detector.scanMeetingApp now enumerates every concurrent native bundle + every browser with a meeting tab, fills each candidate's signals via existing AX walks + ProcessAudioSignal.defaultProbe (Webex excluded for ultrasound retention), and picks the highest scorer above the 5-point + 2-signal floor. lastScorerWinner state feeds the sticky bonus and clears on stop() / below-threshold scans. ShareableContent slot reserved on the tuple but Detector passes false for now (SCShareableContent is async; deferred per spec's "follow-up if initial scoring is sufficient"). detector.source_scored event fires on each winner change (not every 3 s poll) with full signal breakdown. Weights and threshold tuning still owed to dogfood. Runtime acceptance (2026-05-20 incident scenario in events.jsonl) still owed to user.]

Detector currently picks the first matching "known meeting app" running on the system. When a user has Teams open (chat, home view, or any non-meeting window) AND is in a Google Meet via Chrome, native scan wins over browser scan and the recording is attributed to Teams. The shell window has no Calling-controls toolbar so MeetingAXHandleBuilder finds no leave / no mute button; when the Teams shell window closes mid-call, Detector's end-debounce fires `.ended` with `window_open:false` + `mic_active:false` and the recording stops while the actual Google Meet continues.

Signature in events.jsonl when this happens (2026-05-20 15:30 incident):

```
ax_handles_built: window_count=1, found_leave=false, found_mute=false
```

Approach: replace the "first-match wins" logic with multi-source scoring. Detector enumerates every known meeting app + every browser with potential meeting tabs running concurrently, scores each candidate on the strength of "I am IN a meeting" signals, and attributes to the highest-scoring candidate. The score is a robust, stable signal that combines AX, audio, and window-title evidence; no single signal can mis-attribute on its own.

Per-candidate score (proposed weights, tune in dogfood):

| Signal | Weight | Source |
|---|---|---|
| Calling-controls toolbar present in any window | 4 | `MeetingAXHandleBuilder.findCallingControlsToolbar` (new helper) |
| Leave button found in AX walk | 3 | `MeetingAXHandleBuilder.findAllLeaveButtons` (new; mirrors findAllMuteButtons) |
| Mute button found in AX walk | 2 | Existing `MeetingAXHandleBuilder.findAllMuteButtons` |
| Window title matches meeting pattern | 2 | Existing meeting_apps.toml regex (or BrowserMeetingLifecycleAdapter title matchers) |
| Process audio active for this PID | 3 | New: HAL ProcessAudioSignal scope per-PID (already exists in MeetingPipeCore for lifecycle signals) |
| ShareableContent has app as active source | 2 | New: SCShareableContent query for this bundle |
| Recently transitioned to in-meeting state | 1 | Sticky bonus for the candidate that scored highest in the previous scan |

Decision rule:
- Score >= 5 from at least 2 distinct signals: candidate is "in a meeting"
- Highest-scoring candidate wins; tie broken by recency (sticky bonus to last winner)
- No candidate above threshold => no source; Detector stays idle
- Once attribution locks in, do NOT switch to a different source mid-recording (avoid mid-call churn). Re-evaluation happens on the next idle->in-meeting transition.

Files:
- New `Sources/MeetingPipe/MeetingSourceScorer.swift`: pure-logic scorer with `score(candidate:signals:) -> Int` and `pickBest(candidates:) -> Candidate?`. Trivially unit-testable with synthetic signal tuples.
- New `Sources/MeetingPipe/MeetingSourceCandidate.swift`: struct bundling AppSource + per-signal booleans + score.
- Edit `Sources/MeetingPipe/Detector.swift`: replace the linear scan with `enumerateCandidates() -> [Candidate]` then `MeetingSourceScorer.pickBest`. The candidate enumerator walks NSWorkspace.runningApplications, filters to known meeting apps, plus walks browser windows for meeting-title-matching tabs. Each candidate gets its signal tuple populated by querying the existing probes (`MeetingAXHandleBuilder.findAllMuteButtons`, `ProcessAudioSignal.isActive(pid:)`, meeting_apps.toml regex match).
- Extend `Sources/MeetingPipe/MeetingAXHandleBuilder.swift`: add `findAllLeaveButtons` (mirrors `findAllMuteButtons`) and `findCallingControlsToolbar` (searches every window for an AXToolbar role with title containing "Calling controls" or "Meeting controls", reusing the depth-32 walk).
- Edit `Sources/MeetingPipe/Resources/meeting_apps.toml`: add Calling-controls toolbar title patterns per-app if needed (Teams 2 uses "Calling controls", Google Meet uses "Meeting controls" per the 2026-05-20 AX dump).

Tests:
- `Tests/MeetingPipeTests/MeetingSourceScorerTests.swift`: synthetic scoring cases. Teams-with-shell-only-window scores low; Chrome-with-Meet-toolbar scores high; tied scores broken by recency; below-threshold returns no source.
- Replay corpus capture: synthesise an end-to-end trace for the 2026-05-20 incident (Teams running with shell, Chrome with Meet) and assert the scorer picks Chrome.

Stop and ask:
- Tune the threshold + weights in a follow-up dogfood pass. Initial defaults are best-guess; real misattributions in events.jsonl over a week of meetings show whether to adjust.
- Confirm: should the scorer also consider audio routing (which app is sending to the system mixer)? ScreenCaptureKit ProcessTap exposes this per-PID. If the user is actively speaking and audio is flowing FROM Chrome's renderer process, that's a near-certain signal. But it adds a dependency on the SCStream session being active; defer to a follow-up if this initial scoring is sufficient.
- Mid-recording attribution switch: confirm "lock-in" is the right semantics. Alternative: switch attribution if a different candidate exceeds the current by N points for M seconds. Lock-in is safer (no churn); switch is more accurate (catches "I left Teams and joined Meet" mid-recording, though that's rare).

Acceptance:
- Synthetic scorer tests pass: every signal combination resolves predictably.
- Real dogfood (2026-05-20 incident scenario): Teams running with chat window only + Chrome Meet open. events.jsonl shows `detector.started` with `kind: browser`, `bundle_id: com.google.Chrome`, meeting_title set from the Meet tab.
- No regression on existing native Teams meetings: when Teams IS in a real call (Calling controls toolbar + leave/mute buttons + process audio active), the scorer picks Teams and the recording attributes correctly.
- The 2026-05-20 incident trace is added to the corpus (TECH-C6) so future regressions on this exact failure mode are caught in CI.

Deps: none, but ProcessAudioSignal per-PID query may need lifting to a daemon-side helper if it currently lives only inside MeetingPipeCore adapters. Should land before TECH-C13 step 5 because verdict-fusion end-detection assumes the source attribution is trustworthy.

**TECH-C12 · Slack huddle teardown observer · S · TECH-C13** [KEPT] [DONE 2026-05-17: SlackLifecycleAdapter ships ShareableContent + AXLeaveButton signals keyed to com.tinyspeck.slackmacgap; BrowserMeetingLifecycleAdapter default matchers include the huddle title pattern for the PWA case.]

Slack huddles do not fire a clean teardown AX event the way Teams or Zoom do. The Slack adapter in `BrowserMeetingLifecycleAdapter` (for PWA) and a dedicated native adapter subscribe to the huddle window's `kAXUIElementDestroyedNotification` plus a fallback poll of the huddle title-bar widget every 5 s while a huddle is active.

Edit: `Sources/MeetingPipeCore/Lifecycle/Adapters/BrowserMeetingLifecycleAdapter.swift` (extend) and add `Sources/MeetingPipeCore/Lifecycle/Adapters/SlackLifecycleAdapter.swift` for native.

Acceptance: ending a Slack huddle drops the verdict from `.inMeeting` to `.ended` within 5 s; verified manually and in a recorded AX trace fixture.

Deps: TECH-C13.

---

## Group A · Library and search

**TECH-A1 · SQLite-backed library** `[DONE]`

**TECH-A2 · Full-text search via FTS5** `[DONE]`

**TECH-A3 · Menu-bar quick-find · M · TECH-P4** `[DONE]` [KEPT]

Quick-find from the menu bar over title, attendee, transcript snippet. Already partially in place; tighten ranking and add keyboard navigation.

Edit: `Sources/MeetingPipe/UI/MenuBarSearchView.swift`. Acceptance: every meeting in the library reachable in under 5 seconds from menu bar open to result selection on a library of at least 200 meetings; keyboard-only navigation works.

Deps: TECH-P4 (transcript snippet field shape is settled).

**TECH-A4 · Orphan-recording reaper · S · none** `[DONE]` [KEPT]

Recordings present on disk but missing a library row, or library rows missing a file, are detected and reported. Reaper does not auto-delete; it surfaces a list in `meetingpipe doctor`.

Edit: `Sources/MeetingPipe/CLI/DoctorCommand.swift` and `Sources/MeetingPipe/Library/LibraryStore.swift`.

Acceptance: `doctor` reports orphans; a unit test seeds an orphan and asserts it appears in the report.

Deps: none.

**TECH-A5 · Correction round-trip · M · TECH-P4** `[DONE]` [KEPT]

User edits a transcript line; the correction lands in the sidecar JSON; the edited version is the source of truth on every subsequent open. Already partial; verify the FluidAudio output shape lets corrections persist cleanly.

Edit: `Sources/MeetingPipe/Library/TranscriptStore.swift`.

Acceptance: edit a line, close the meeting, reopen, edit persists; events.jsonl records `transcript.correction` with the original and edited text.

Deps: TECH-P4.

**TECH-A6 · Title-prefixed recording filenames · S · none** [NEW 2026-05-20, IDEA]

User feedback (2026-05-20): scanning `~/Documents/Meetings/raw/` for the right file is painful when every name is just `yyyyMMdd-HHmmss.wav`. The meeting title is already harvested at recording-start via `Detector.enrichWithMeetingTitle` (confirmed feasible 2026-05-20: Teams 2 exposes the meeting name as `<MeetingName> | Microsoft Teams` in `kAXTitleAttribute` on the meeting window; an Accessibility Inspector dump confirmed the format) and persisted in `<stem>.meta.json`. The same string should drive the filename stem too: `20260520-1030-echo.wav` is dramatically easier to spot than `20260520-103034.wav`.

New stem format proposal: `<yyyyMMdd-HHmm>-<slugified-title>` where slugify lowercases, replaces non-alphanumerics with `-`, collapses runs, trims to 40 chars, strips leading/trailing dashes. Manual recordings and pre-meeting starts (where `AppSource.meetingTitle == nil`) keep the timestamp-only stem.

Edits:
- `Sources/MeetingPipe/MeetingRecorder.swift` `start(outputDir:voiceProcessing:)` takes an optional `titleSlug` parameter; if provided, the stem becomes `<timestamp>-<slug>`, otherwise the existing timestamp stem.
- `Sources/MeetingPipe/Coordinator.swift` `beginRecording` computes the slug from `source?.meetingTitle` and threads it through. Workflow short-name could also be appended (`20260520-1030-echo-1on1`) but defer that until the simpler version proves itself.
- `Sources/MeetingPipe/MeetingStore.swift` recognises both legacy `<timestamp>.wav` and new `<timestamp>-<slug>.wav` stems; sidecar pairing already uses meta.json so this is mostly a regex update for the recognised-extension list.
- New `Sources/MeetingPipe/FilenameSlugifier.swift` with pure-function tests in `Tests/MeetingPipeTests/FilenameSlugifierTests.swift` covering: ASCII titles, Ukrainian / Cyrillic titles (transliterate or keep? decide as part of the task), titles with emoji and slashes, very long titles, empty / whitespace-only titles, titles that slugify to empty.

Stop and ask:
- Cyrillic vs Latin: Ukrainian meeting names ("Зустріч команди") could either keep Cyrillic in the filename or transliterate to ASCII. Cyrillic in macOS filenames is supported but trips up some shell scripts; transliteration loses information. Decide at task-start with the user.
- Workflow short-name inclusion (`-1on1`, `-standup`): defer to a follow-up if needed.

Acceptance:
- Detected meetings produce title-prefixed stems; manual recordings keep timestamp-only stems.
- Library window opens both formats without code changes (sidecar-driven).
- A pure-function unit test corpus covers ASCII / Cyrillic / emoji / overlong / empty inputs.
- Two meetings with identical titles in the same minute resolve uniquely (timestamp seconds break ties).
- No regression in the .meta.json schema; only the on-disk filename stem changes.

Deps: none. Can land anytime; small.

**TECH-LIB-MIX · Library playback mono mixdown · S · none** `[DONE]` [NEW]

The library window's audio playback defaults to a real-time mono mixdown of the stereo WAV instead of stereo playback. The on-disk WAV stays stereo (mic-L, system-R) for diarization and silent-system-audio detectability per the existing design. The mixdown is computed in the playback path as 0.5 times left plus 0.5 times right per sample, applied through an `AVAudioMixerNode` pan-to-center configuration on the player node, with no modification to the source file. A toggle in the library window's playback controls switches between mono mixdown (default) and original stereo for users who explicitly want the channel separation. The toggle state is persisted per library, not globally. The mixdown avoids the "input in left ear, output in right ear" listening confusion that the stereo-on-headphones default produces.

Create:
- `Sources/MeetingPipeLibrary/Playback/PlaybackChannelMode.swift` (enum: `.monoMixdown` (default), `.stereoOriginal`).

Edit:
- `Sources/MeetingPipeLibrary/Playback/LibraryPlayer.swift` to apply the channel-mode at player-node configuration time.
- `Sources/MeetingPipeLibrary/Views/PlaybackControlsView.swift` to add the toggle UI.
- `Sources/MeetingPipeLibrary/Storage/LibraryPreferences.swift` to persist the toggle state.

Acceptance:
- Opening any existing stereo recording in the library and clicking play produces mono audio on both ears by default.
- The on-disk WAV is byte-identical before and after playback (verified by SHA-256).
- The stereo toggle in the playback controls switches to original stereo and persists across library window close and reopen.
- The mixdown introduces no audible clipping on recordings where left and right are both near full-scale (verified by playing back a test recording of a loud call).

Stop and ask:
- If `AVAudioMixerNode` pan-to-center produces audible phase artifacts on any test recording, switch to explicit per-buffer 0.5L + 0.5R summation in an `AVAudioSourceNode` render block, not a mixer pan.

Deps: none. Can land anytime in Phase 0 or Phase 1 alongside other work; small enough to fit into a single Claude Code session.

---

## Group B · Workflows and attribution

**TECH-B1 · Workflow inference from calendar event** `[DONE]`

**TECH-B2 · Per-workflow prompt presets** `[DONE]`

**TECH-B3 · Workflow attribution audit · S · TECH-A5** [KEPT]

Every meeting in the library carries a workflow attribution. Add a periodic audit (run from doctor) that surfaces meetings with `workflow = unknown` plus a quick-attribute action.

Edit: `Sources/MeetingPipe/CLI/DoctorCommand.swift`.

Acceptance: `doctor --workflows` lists every meeting in the last 30 days where `workflow = unknown`; the count is also surfaced as a menu-bar badge if non-zero.

Deps: TECH-A5.

---

## Group E · Events and telemetry

**TECH-E1 · events.jsonl writer** `[DONE]`

**TECH-E2 · Event schema versioning** `[DONE]`

**TECH-E3 · Rebuild-event tagging · S · none** `[DONE]` [NEW]

Every app launch records the running binary's cdhash and a synthetic `app.rebuild` event when the cdhash differs from the previous launch. Lets dogfood analysis filter out re-grant churn from `--reset-tcc` cycles. The cost of deferring Dev ID (TECH-D8) shows up in events.jsonl noise; this tag is the mitigation.

Edit: `Sources/MeetingPipe/Logging/EventLogger.swift`.

Acceptance: launching a rebuilt binary records `app.rebuild` with `prev_cdhash` and `new_cdhash`; launching the same binary twice records no `app.rebuild`; a dogfood-analysis script can filter the window around each rebuild.

Deps: none.

**TECH-E4 · Dogfood analysis script · M · TECH-E3, TECH-C13, TECH-G-MIC** [NEW]

A script that reads events.jsonl over a fortnight and reports against the dogfood bars defined below. Outputs a one-page summary per layer (capture, detection, transcription, library) with pass / fail / inconclusive verdicts.

Create: `scripts/dogfood-report.swift` (a Swift script invoked via `swift run dogfood-report --since 14d`).

Acceptance: running the script over a seeded fixture events.jsonl produces the expected report; the report names each bar and the observed value; rebuild-tagged windows are excluded by default; the report distinguishes `MeetingLifecycleVerdict` evidence from `MicGateVerdict` evidence per bar.

Deps: TECH-E3, TECH-C13, TECH-G-MIC.

---

## Group F · Conventions and docs

**TECH-F1 · README accuracy pass** `[DONE]`

**TECH-F10 · CONVENTIONS.md** (see Group H)

**TECH-F11 · Decision records directory · S · none** `[DONE]` [NEW]

A `docs/decisions/` directory with one file per architectural decision. Format: context, decision, consequences. Numbered sequentially.

Acceptance: directory exists; `0001` through `0006` retroactively capture decisions already made (CoreAudio HAL over ScreenCaptureKit input, sherpa-onnx then FluidAudio rationale, SQLite over Core Data, menu-bar over dock app, no em-dash lint, Swift over Go for the eventual Hub). `0007` is the Python sidecar decision (TECH-P4). `0008` is the verdict-fusion architecture (TECH-C13 plus TECH-G-MIC). `0009` is the stereo-on-disk plus mono-on-playback decision (TECH-LIB-MIX).

Deps: none.

---

## Group G · Personal Hub (P2)

**TECH-G1 · Personal two-Mac Hub · XL · all P0 and P1 dogfood bars met** [REFRAMED]

The Hub is not scoped as a regulated-buyer pilot tool. It is a personal sync target so the user's Mac at home and Mac at work share one library. Single user, two machines, both owned and operated by the same person. No multi-tenant. No Compliance Profile presets. An audit log is optional and exists only because Part 11 reflexes are good engineering practice, not because anyone external requires it.

Recommendation: **CloudKit private database, Swift-native, no self-hosted helper.** Reasoning: the user already has an Apple ID on both machines; CloudKit private database is end-to-end encrypted to the iCloud Keychain; there is no server to operate; conflict resolution is record-level with last-writer-wins plus a small custom-merge for transcript corrections. The self-hosted-helper option (a tiny Go or Swift daemon on a home NAS or a $5/mo VPS) gives more control over storage and audit but costs operational overhead the user does not want to carry, and that overhead does not buy anything for a one-person two-machine setup. If the user later wants to share with a second person, the right move is to redesign at that point, not to over-build now.

Client-side encryption mandatory. The library SQLite + sidecar JSONs + audio files are encrypted to a key derived from a passphrase the user holds; CloudKit sees opaque blobs. Optional audit log records every sync operation locally on each machine.

Create: `Sources/MeetingPipe/Hub/CloudKitSync.swift`, `Sources/MeetingPipe/Hub/Encryption.swift`, `Sources/MeetingPipe/Hub/ConflictResolver.swift`. Edit: `Sources/MeetingPipe/Library/LibraryStore.swift` for sync hooks.

Acceptance: a recording made on Mac A appears in Mac B's library within 60s under normal network conditions; transcript edits made on either machine converge; the system survives wifi drop, Mac sleep, restart, and bidirectional offline editing without corruption; encrypted blobs are unreadable in CloudKit Dashboard.

Scope-creep alarm: if this task crosses 25 days of actual work, stop and reassess. The temptation to "make it just a little more general so it could ship to a second user later" is the failure mode.

Stop and ask: any change to the library schema; any plaintext field added to a CloudKit record; any path that emits the user's audio to anywhere other than CloudKit private database.

Deps: all P0 and P1 dogfood bars met.

---

## Group D · Distribution (deferred)

**TECH-D1 · Build script and DMG packaging** `[DONE]`

**TECH-D8 · Apple Developer ID enrollment plus notarization · L · all dogfood bars met AND user decides to ship to a second user** [DOWNGRADED to P3]

Promoted only when both conditions hold. Until then the user lives with `--reset-tcc` and the cdhash drift; the drift cost is mitigated by TECH-E3 (rebuild tagging).

Reasoning for the deferral: enrollment costs about $99/yr plus the operational tax of certificate rotation and a notarization step in the build. Neither buys anything for the primary user. The trigger is "user decides to ship to a second user," not a calendar date.

Deps: dogfood bars met across all phases AND explicit user decision.

---

## Group F · Compliance docs (deferred)

**TECH-F2 · Threat model document · M · TECH-D8** [KEPT, deferred behind D8]

**TECH-F3 · Data retention and deletion policy · S · TECH-D8** [KEPT, deferred behind D8]

**TECH-F4 · Privacy disclosures · S · TECH-D8** [KEPT, deferred behind D8]

All three only matter once a second user enters the picture. Until then, the primary user knows what the app does because the primary user wrote it.

---

## Group I · Future ideas (parking lot)

Captured for later reflection, not committed work. None of these are scheduled. Each entry sketches the idea, the use case, and the open questions worth answering when the idea gets promoted to a real ticket. None of them block any current Phase 0..3 work.

**TECH-I1 · Multi-recording merge / stitch · M · none** [IDEA, not scheduled, 2026-05-20]

Use case: a meeting got auto-stopped mid-call (false end-detection) and auto-restarted moments later, producing two `<stem>.wav` files that are actually one meeting. Or the user manually paused and resumed across a break. Today the library has two unrelated rows and the Notion publish flow processes each independently. The user wants a single merged artifact (audio + transcript + sidecar) without re-running the pipeline from scratch.

Sketch:
- ffmpeg `concat` protocol for the WAVs (same sample rate by construction since both came from the same MeetingRecorder config).
- Transcripts concatenate at the segment boundary with timestamps offset by the duration of the first file. Speaker diarization labels reconciled: if file A's speaker_1 and file B's speaker_1 are actually the same person (probable given they're back-to-back fragments of the same call), an embedding-similarity check on a short sample resolves the merge. Fallback: prompt the user.
- Sidecar merges with the earliest `started_at` and the latest `ended_at`. `meeting_title` taken from whichever sidecar has the most informative value (non-nil wins; longer wins on tie).
- Donor files move to a `.merged-into/<parent-stem>/` archive folder so the operation is reversible without backups.
- Notion: republish the merged page; either delete the donor pages or mark them "merged into <parent>" with a link. User decides per the same flag set as TECH-I2.

Open questions:
- UX entry point. Library multi-select + "Merge" toolbar action is the natural place; a CLI `mp merge <stems...>` covers scripted use.
- Cross-day boundary: a meeting that started at 23:58 and continued at 00:03 should merge as one. Probably yes; flag if the gap is greater than 10 minutes for an explicit confirm.
- Republish to Notion automatically or surface as a manual action. Default: surface for confirm, since republishing is a chunky pipeline run.

Deps: TECH-I2 informs the Notion-side semantics. Independent on the audio + transcript side.

**TECH-I2 · Notion re-sync with explicit source-of-truth model · M · TECH-P4** [IDEA, not scheduled, 2026-05-20]

Use case: the local library and the Notion database drift over time. A meeting deleted from disk still has a Notion page; a Notion page may exist that the user updated manually but the local sidecar is stale; a fresh recording never made it to Notion because the network was down at publish time. The user wants a one-shot reconciliation command that does the right thing per row.

Recommended source-of-truth (assessment for the future ticket): the local file system is canonical. Notion is a publish projection of the canonical artifact (the WAV plus its sidecar JSON). This matches the rest of the daemon's architecture: SQLite library + sidecars are authoritative, Notion is downstream.

| State | Action |
|---|---|
| Sidecar exists in FS, no Notion page | publish to Notion (the existing publish path) |
| Notion page exists, no sidecar in FS (FS deletion) | DO NOT auto-delete from Notion. Surface in a `mp doctor` report; user decides per row whether to archive (move to a Notion archive section) or unlink (drop the Notion-side mapping from the sidecar). Auto-delete is destructive and the user already trusts FS deletes; one-click confirm is acceptable, silent delete is not. |
| Both exist, sidecar newer than Notion page | re-publish (covers transcript edits, title fixes, correction round-trip output) |
| Both exist, Notion newer (user edited the page manually) | leave alone for v1. Bi-directional sync is a larger project (TECH-G1 Personal Hub territory) and out of scope here. Surface the conflict in `mp doctor` so the user knows. |

Sketch: a `mp resync-notion` CLI subcommand that walks the local library, queries the Notion database for the linked pages, prints a per-row plan, and executes. `--dry-run` by default; `--apply` to actually run; `--archive-stale` and `--unlink-stale` control the deletion semantics. Idempotent (safe to re-run).

Open questions:
- Where to store the FS sidecar's mapping to its Notion page ID. Verify whether the existing sidecar already carries `notion_page_id`; if not, add it on first publish.
- Throttling Notion API calls for libraries past a few hundred rows (Notion API is rate-limited; back off + resume).
- Detecting "Notion-newer" without storing a Notion `last_edited` snapshot locally. The Notion API exposes `last_edited_time` per page; fetch + compare against the sidecar's `summary_published_at` (or equivalent) without a local snapshot.

Deps: TECH-P4 (transcript shape settled) so the "newer" comparison has a stable signal.

**TECH-I3 · Use captured meeting title as Notion page title + summarization context · S · none** [IDEA, not scheduled, 2026-05-20]

Status callout: the CAPTURE half of this idea is already shipping. `Detector.enrichWithMeetingTitle` runs at the `.started` fire and stores the title on `AppSource.meetingTitle`, then `MeetingMetaSidecar.build` persists it via the sidecar (`<stem>.meta.json`). TECH-A6 uses the same field for filename stems and confirms Teams 2 / Zoom / Webex / Slack / browser title extraction is feasible (Accessibility Inspector dump dated 2026-05-20). This idea is about the CONSUMPTION half on the publish + summarize side.

What this ticket adds:

1. **Notion page title.** Today's Notion publish derives the page title from the LLM summary or the timestamp. Switch to: prefer `meeting_title` from the sidecar; fall back to the LLM-derived title; fall back to the timestamp. Pure publish-side change in the Python pipeline; no daemon work needed.
2. **Summarization context.** Pass `meeting_title` plus the detected app and workflow short-name to the summarizer as a structured context block, not just as part of the transcript blob. A summary that knows "this is a 1:1 with Echo on Teams" produces a notably better output than the same transcript with no framing. Add a `context` block to the `mp.summarize` request schema and prepend it to the prompt template.

Sketch:
- Python pipeline `mp.summarize`: extend the request schema with `context.meeting_title`, `context.app`, `context.workflow`; prepend a short framing paragraph to the prompt when any are present.
- Python pipeline `mp.publish_notion`: read `meeting_title` from the sidecar; prefer it for the Notion page title.
- Optional daemon-side polish: let the correction window edit the title before publish in case the AX harvest captured a weird string. Trivial to add (the sidecar is already writable from the daemon).

Open questions:
- Title editability before publish. Yes for v1; the correction window already touches the sidecar.
- What to do when `meeting_title` is the literal app chrome ("Microsoft Teams") because the call had no topic. Detect + fall through to the LLM title; the chrome-blacklist already exists in `Detector.isActiveMeetingWindow` and can be reused.

Deps: none. The pure-publish-side changes are independent.

**TECH-I4 · Confirm-to-publish for Notion (local-first summary) · S · none** [IDEA, not scheduled, 2026-05-20]

Use case: today the pipeline auto-publishes every recording's summary to Notion the moment summarization finishes. Some meetings are sensitive (medical, legal, hiring, personal) and should never leave the Mac. Today the only way to opt out is to remember to switch to `SummaryMode.byo` BEFORE the meeting starts, which is too easy to forget. The user wants the default to be "summary lives locally; publish is a deliberate action," not the reverse.

Distinct from `SummaryMode.byo`: BYO gates WHO produces the summary (you in your own LLM frontend vs. the pipeline calling Anthropic). This idea gates WHEN the summary leaves the Mac. They compose: local Anthropic summarization + local-only retention is the new combination this enables.

Sketch:

- **Config flip.** New `notion.auto_publish` boolean. Default `false` in the new model; user explicitly opts in to auto-publish per workflow or globally. The existing always-publish behaviour becomes one config switch away for users who prefer it.
- **State.** Sidecar grows a `publish_state` enum: `.pending` (summary done, not yet pushed), `.published` (pushed to Notion, page_id stored), `.declined` (user explicitly skipped this one), `.local_only` (workflow-marked never-publish). The state is the source of truth for the publish queue and for `mp resync-notion` (TECH-I2) reconciliation.
- **UX entry points (pick one or more at design time):**
  - Notification action: when summarization completes, the existing notification grows a "Publish to Notion" button alongside "Open Library". One click pushes; dismissing the notification leaves it `.pending`.
  - Menu-bar pending counter: a status-bar row "📤 1 summary pending publish - Review…" that opens the library filtered to `.pending` rows with a Publish action per row.
  - Library row pill: a "Local only" pill on `.pending` rows with a one-click Publish button. Batch select + Publish for the bulk case.
- **Batch publish.** Library multi-select + "Publish selected to Notion". Useful after a meeting-heavy day where the user wants to review all summaries at once and push approved ones in one go.
- **Workflow override.** Per-workflow setting `auto_publish: never|always|prompt` (matches the existing per-workflow config surface). A workflow tagged "personal" or "1:1" stays local-only by default without further prompting; a workflow tagged "standup" auto-publishes since there's nothing sensitive about it.

Open questions:
- Should the "local-only" default also apply when the user has explicitly tagged a workflow as `auto_publish: always`? Workflow override should win; the global default is for the unknown-workflow / manual-recording case.
- What happens to `.pending` rows that age out (user never decides)? Soft-expire after 30 days to `.declined` with a doctor-report note, or keep forever? Probably keep forever; the cost of a stale `.pending` row is zero and silent auto-state-change is exactly the foot-gun this whole idea is trying to remove.
- Interaction with `SummaryMode.byo`: BYO produces the paste-bundle; the `.pending` state lives until the user pastes back their summary AND clicks Publish. The two states compose cleanly.

Deps: independent. Pure publish-side change (Python `mp.publish_notion` becomes opt-in, daemon-side UI grows the prompts).

**TECH-I5 · Detect PWA / installed-desktop-app meetings · M · none** [IDEA, not scheduled, 2026-05-21]

Use case (2026-05-21 dogfood): the user started a Google Meet via the installable Meet desktop app (Chrome "Install Google Meet…" PWA, or an equivalent standalone app) and the daemon did not detect the meeting start. Today `Detector.enumerateCandidates` only builds candidates for bundle IDs in `meeting_apps.toml` `[native].bundle_ids` or `[browser.bundles].ids`. A Chrome-installed PWA runs under a synthetic bundle ID of the form `com.google.Chrome.app.<hash>` (the hash is per-install, per-machine), which is in neither list, so no candidate is ever enumerated for it. Same gap applies to a Teams PWA, a Slack PWA installed as an app, an Edge-installed Meet app, etc.

This is a pre-existing gap, NOT the TECH-C15 regression (that was fixed 2026-05-21 in `MeetingSourceScorer.pickBest`).

Sketch:
- PWA bundle IDs are not stable across machines (the hash is derived at install time), so hardcoding them in `meeting_apps.toml` does not work. Detection must be structural.
- Option A: enumerate every `NSRunningApplication` whose bundle ID matches `com.google.Chrome.app.*` / `com.microsoft.edgemac.app.*` / `org.mozilla.firefox.*` PWA-prefix patterns, then AX-walk the app's windows for a meeting-pattern title (the same `BrowserMeetingLifecycleAdapter` title matchers). A PWA window IS a normal AX window so the existing title scan applies.
- Option B: read the PWA's `Info.plist` (`CFBundleDisplayName`, the `CrAppModeShortcutName` Chrome writes) to recover the human name ("Google Meet") and the start URL, and match the start URL against the meeting URL fragments.
- The scorer side already works once a candidate exists; the missing piece is purely candidate enumeration.

Open questions:
- Whether to treat a PWA as `kind: .browser` (it is Chromium under the hood, no native AX call controls) or a new `kind: .pwa`. Probably `.browser` so the existing browser end-detection + MicGate HAL-VAD-fallback paths apply unchanged.
- PWA-prefix patterns per browser need confirming against a live install (Chrome uses `com.google.Chrome.app.<hash>`; Edge and Arc differ).
- Process-audio attribution: a PWA is a separate process from the main browser, so `ProcessAudioSignal` keyed to the PWA PID should actually work better than tab-in-browser detection. Worth measuring.

Deps: none. Independent of the scorer; it is an enumeration-side addition.

---

## Dogfood acceptance bars

The "technical excellence" standard is testable: each layer ships when its bar is met over a fortnight of normal use, measured against events.jsonl with rebuild-tagged windows excluded (TECH-E3). The thresholds below are starting proposals; calibrate against the first fortnight of post-Phase-0 data.

**Capture bar (closes mute-while-recording corruption).** Over 14 calendar days of normal use, with at least 20 recorded meetings spanning Teams, Zoom, Meet, Webex, and at least one browser-PWA meeting:
- Zero corrupted-merge events (`writer.merge.failed` count = 0).
- Zero "user muted but mic captured ambient" events, defined as a `MicGateVerdict.hot` segment overlapping a writer-active window where the meeting-app AX state showed `mutedByApp` for more than 250 ms within that segment.
- Frame-count equality between left and right channels on every recording (writer alignment preserved by zero-amplitude frames, not skipped frames).
- Zero manual ffmpeg re-runs needed to salvage a recording.

**Detection bar (closes meeting-ending-detection).** Same window, same meetings:
- Zero false-positive prompts, measured as `MeetingLifecycleVerdict.starting` events with no following `.inMeeting` confirmed by the user.
- Zero missed-starts, measured by reconciling calendar events with `.inMeeting` events.
- `MeetingLifecycleVerdict.ended` fires within 30 s of actual meeting end on 95% or more of meetings, measured by the gap between the user-observed Leave click and the `.ended` event in events.jsonl.
- Zero manual `⌃⌥M` stops needed.
- For Teams specifically: `.ended` fires with `confirmedBy` containing both `shareable_content_window_gone` and `process_audio_is_running_input_false` on 90% or more of native Teams calls.
- For Webex specifically: `.ended` fires with `confirmedBy` containing `shareable_content_window_gone` plus `ax_leave_button_invalid` (never `process_audio_is_running_input_false` due to documented ultrasound retention).

**Transcription bar.** Over the same window:
- WER under 8% on the user's own voice (calibrated against hand-corrected references in the TECH-P0 fixture set, plus any new ground-truth corrections from the fortnight).
- WER under 12% on the user's typical interlocutors.
- Diarization confusion under 15% (DER on the fixtures).
- End-to-end transcription latency under 1.5x recording duration on the user's hardware.
- Zero pipeline subprocess crashes (or "zero unexpected runner exceptions" if TECH-P4 eliminated the sidecar).

**Library bar.** Same window:
- Every meeting findable in under 5s from menu-bar open to selection.
- Zero orphaned recordings (TECH-A4 reaper reports empty).
- Transcript correction round-trip works (TECH-A5 assertion holds on every edited meeting).
- 100% of meetings carry a workflow attribution (TECH-B3 reports zero `workflow = unknown`).
- Library playback defaults to mono mixdown; no "input ear, output ear" report from the user across 14 days (TECH-LIB-MIX).

A layer is "done" when its bar holds over a fortnight, not when its task list is checked off. Tasks ship to enable the bar; the bar decides when the next layer can start.

---

## Critical path

The path is anchored on dogfood bars, not weeks. Each step gates the next.

1. **Phase 0** ships when Group H tasks (TECH-H1, H4, H5) plus TECH-F10, TECH-F11, TECH-E3, TECH-LIB-MIX are complete and the existing functionality regression is clean over a fortnight.
2. **Phase 1** ships when the transcription bar holds over a fortnight on FluidAudio output (TECH-P0 through P4).
3. **Phase 2** ships when **both** the capture bar **and** the detection bar hold over a fortnight with TECH-C13 (MeetingLifecycleCoordinator) and TECH-G-MIC (MicGate) live. These two tasks share the AX walk and the shared infra, so they are co-scheduled.
4. **Phase 3** ships when the detection bar continues to hold with the regression corpus (TECH-C6) plus residual detection tasks (TECH-C7, TECH-C12) in place.
5. **Phase 4** ships when the library bar holds over a fortnight across both Macs (TECH-G1).
6. **Phase 5** is not on the path; it is a future gate (TECH-D8 and Group F compliance docs).

Note for the companion `roadmap.md`: the prior Phase 2 description ("MicGate subsystem only") needs revision to reflect that Phase 2 now closes both end-detection and mute-gating in one coordinated drop. Recommended rename: "Verdict fusion subsystems" or "Phase 2: lifecycle plus gate verdicts." Update the Phase 2 dogfood-bar wording to require both bars holding together (since the architecture treats them as one shared infrastructure layer, separating them in the bar narrative would misrepresent the work).
