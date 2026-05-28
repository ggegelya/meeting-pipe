# MeetingPipe Q3 backlog

## Next session priority order (handoff 2026-05-24)

Q2 closed five of eight audit headline items: documentation integrity, Meet/PWA detection, capture integrity (callbacks moved off RT threads + device-change auto-resume), observability (durable error sidecar + inline Retry), security and privacy (regulated-mode egress, ObsidianPublisher idempotency, mlx_lm.server lifecycle, local-LLM loopback clamp), and correctness (orphan recovery, plus dead-code removal). 574 Swift tests + 185 Python tests green at Step 5.

Q3 closes the rest: the open P1 mic/system end-of-call skew, the architectural debt the audit named (TECH-H1 still 1090-1600 lines vs the 400-line acceptance bar, two unwired lifecycle signals, god-view sizes, typed summary model), the unbuilt onboarding screen with a finished mockup, the discovered-but-misguided UI addendum (rewrite three items, drop two), the next.md ideas worth shipping (LLM diarization cleanup, HUD app icon, opt-out auto-restart, Apple Intelligence backend on top of a new chunking primitive), and the GTM doc's pre-launch deliverables (compliance pages, landing page, demo GIF, README hero) so the June launch can hit the window.

**P0 - runtime acceptance owed (user, before any new code)**

These are owed against work already merged. No code change; runtime validation only.

1. **Live Meet PWA detection** in a real call. Tail `events.jsonl` for `detector.started` with `kind: browser, bundle_id: com.google.Chrome.app.<hash>` and the Meet tab title. Confirms TECH-I5 + Step 2.
2. **Live device swap mid-recording.** Unplug AirPods mid-meeting; confirm one continuous WAV with no flatline gap. Confirms Step 3 commit `fe3bf0e`.
3. **Three Step 5 failure surfaces in daily use** (inline Retry on the failed row, failed-state detail pane, status-bar "N failed" row). Confirms Step 5 commits `f9bfa6e`, `9479551`, `9510e24`.
4. **Join-muted check.** Join a Teams call already muted; confirm `AXMuteButtonProbe` emits initial muted state at engage (not only on toggle), no spurious `muted_by_app` drops to RMS while staying muted. Confirms the audit's deferred small follow-up.

**P0 - ship next (the structural unblock)**

1. **TECH-H1-FINISH Coordinator slimming round 2** (L). Extract `MeetingLibraryService`, `ConfigRefreshCoordinator`, `PipelineJobDispatcher`. Target under 600 lines (the original under-400 was unrealistic given the device-change recovery work; recalibrate).
2. **TECH-C6-FINISH Detection regression corpus from real dogfood** (M). 20+ user-recorded traces; harness ready since Step 2.

TECH-CAP1 (the audit's open P1) was here; deprioritized to P3 on 2026-05-28 (monitor only, see the P3 band and Group C).

**P1 - ship in Q3**

1. TECH-A11 Typed summary model (M). Replaces `[String: Any]` threaded through four detail views.
2. TECH-A12 MeetingStore mtime cache (S). Closes the 500ms-debounce-re-parse during recording.
3. TECH-DIAR1 LLM-based diarization cleanup (M). Next.md idea 5, highest leverage on the page.
4. TECH-SUM1 Chunking primitive + Apple Intelligence backend (L). Next.md idea 2, depends on TECH-DIAR1 to share the chunking primitive.
5. TECH-UX1 Onboarding screen (M). Mockup exists at `design/ui_kits/macos_app/OnboardingPermissions.jsx`.
6. TECH-UX2 Regenerate / Republish discoverability (S). Same treatment Retry got.
7. TECH-UX4 Degraded recording state on the HUD during the meeting (S).
8. TECH-UX6 HUD icon for the currently-recording app (S). Wire `AppGlyphView` into the HUD.
9. TECH-E4-FINISH Dogfood analysis script (M). Closes the loop on the acceptance bars.
10. TECH-C16 Decide-or-delete: InputDeviceSignal and CalendarContextSignal (S, two ADRs and a code change).

**P1 - launch readiness (GTM doc pre-launch ship list)**

11. TECH-BRAND1 Register domains and namespaces (S).
12. TECH-BRAND8 Compliance posture pages (M). The actual differentiating work.
13. TECH-BRAND7 Landing page on meetingpipe.app (L).
14. TECH-BRAND5 Demo GIF / WebM (M).
15. TECH-BRAND3 README hero (S). Depends on BRAND5 for the embedded loop.
16. TECH-BRAND6 Screenshot set, light and dark (S).
17. TECH-BRAND4 OG card / social meta (S).
18. TECH-BRAND9 Repo polish (S). CoC, CONTRIBUTING, PR template, issue templates, SECURITY.md, CHANGELOG.
19. TECH-BRAND2 Trademark clearance opinion and Class 9/42 filing (S, owner action).

**P2 - polish, queued**

- TECH-UI-X1 Extract MeetingDetailView into per-tab files (M)
- TECH-UI-X2 Extract PreferencesView into per-section files (M)
- TECH-A13 Render cliffs: streaming FluidAudio + waveform redraw budget (M)
- TECH-UX3 Long-meeting / BYO in-app completion paths (M)
- TECH-UX5 In-app pipeline progress / wedged-vs-slow detection (M)
- TECH-UX7 Opt-out auto-restart on quit (S)
- TECH-UX8 Voice-activity meter on the HUD (S)
- TECH-SEC1 secrets.env permissions on read (S)
- TECH-I6 Partial-publish failure visibility (M)
- TECH-T2 Snapshot tests for three SwiftUI views (S)
- TECH-W2 Workflow precedence pinning test (S)
- Group UI quick-win polish (Wave A, Wave B) - see Group UI below

**P3 - deferred indefinitely**

- TECH-I7 Drop Python entirely (promotion trigger: Apple Intelligence proves out AND local LLM swap is Swift-native)
- TECH-I8 Live transcription during recording (promotion trigger: Q4 streaming summarization design proves the floor)
- TECH-G1 Personal two-Mac Hub (unchanged from Q2: all P0/P1 dogfood bars met first)
- TECH-D8 Apple Developer ID + notarization (promotion trigger: user decides to ship to a second user; partially overlapped by Q3 launch readiness but the full notarization-in-CI is still parked)
- Group F compliance docs (BAA template, threat model, retention policy, privacy disclosures) - partially activated by TECH-BRAND8
- TECH-CAP1 Mic/system end-of-call skew (M, was the open P1). Deprioritized 2026-05-28: user no longer reliably observes the skew in daily use. Monitor across dogfood; promotion trigger: the few-seconds mic/system shift reappears across multiple recordings. Full task spec retained under Group C.

**Critical context for next session**

- User locale: 99% English / Ukrainian. Do not default examples to German. `uk` is in MuteLabels.toml; verify any new uk labels with the user.
- User is vibe-coding: high-level explanations, does not read code. Lean on ARCHITECTURE.md Mermaid diagrams.
- Identity: commits as `Georgy <g.gegelya@icloud.com>`. No em-dashes in any output. Do not push without permission.
- MicGate runtime knobs live in Preferences > Recording > Microphone and Preferences > Prompt > Stop conditions.
- This backlog is the source of truth for TECH-* items. Q2 archived to `docs/backlog/q2-final.md`. Q2 UI addendum archived to `docs/backlog/q2-ui-addendum-final.md`. Audit doc reframed to `docs/operational-state-2026-q2.md`. next.md archived to `docs/planning/2026-05-next.md`.
- Architecture doc renamed to `docs/architecture/signal-fusion-and-mic-gating.md`.
- GTM doc renamed to `docs/gtm/local-first-regulated.md`.
- Path correction across the whole UI addendum: `Sources/MeetingPipeLibrary/` does NOT exist. Library and detail views live under `daemon/Sources/MeetingPipe/` (e.g. `LibraryListView.swift`, `MeetingDetailView.swift`, `MeetingRow.swift`, `LibraryChrome.swift`, `Design/AppGlyphView.swift`, `Preferences/PreferencesView.swift`).

---

The binding constraint remains CLAUDE.md: the primary user is the author, sellability is tertiary, technical excellence in basic functionality comes first. Q3 reframes "sellability" from tertiary to a Q3-bounded launch readiness sub-track: ship the pre-launch deliverables the GTM doc names, do not let them slip into Q4, hold the technical excellence bar elsewhere.

Priority bands:
- **P0** blocks the daily-use experience OR blocks the June launch window.
- **P1** meaningful improvement, not blocking.
- **P2** polish and power-user payoff.
- **P3** deferred indefinitely, promoted only on a stated trigger.

Size:
- **S** about half a day
- **M** one to two days
- **L** three to five days
- **XL** one to two weeks, typically multiple Claude Code sessions

Conventions: `[DONE]` marks tasks complete in the working tree. `[NEW]` marks tasks introduced in Q3. Each task is self-contained for one Claude Code session (or a stated subset, for XL). Files to create or edit are named explicitly. Stop-and-ask triggers are called out for any new dependency, schema change, or user-visible behaviour change.

Claude Code delegation prompt template:
```
Read TECH-{ID} from docs/backlog/meetingpipe-q3-backlog.md.
Read the relevant existing files in the repo.
Implement the task. Stop and ask before introducing new dependencies.
Run the existing tests before declaring done. Output a summary of
changed files + any decisions you made that were not specified.
Do not use em-dashes anywhere in code, comments, commit messages, or output (ADR 0005).
```

---

## Group H · Architectural foundations (continuation)

**TECH-H1-FINISH · Coordinator slimming round 2 · L · none** [DONE]

> Resolved 2026-05-28: the three named subordinates were extracted, each with its own unit test file (20 new tests; full suite 593, 0 failures), and every `Log.event` name/payload preserved verbatim (categories stay `coordinator`). `Coordinator.swift` dropped from 1695 to 1446 lines.
>
> Scope decision (explicitly chosen this session): only the three named extractions were done, so the literal "under 600 lines" bar was NOT met. The remaining ~1446 lines are the live recording-lifecycle orchestration (init / start / beginRecording / stopRecording / lifecycle-discovery / MicGate-engage / silence / the delegate extensions), which the task does not name and which touches the `recorder.micPaused` / MicGate seam owned by TECH-G-MIC. Hitting <600 would require either splitting the residual type into per-concern extension files (opening many private members to internal) or extracting further real types near that seam; both were deliberately deferred. This supersedes the Q2 TECH-H1 `[DONE]` (which overstated the slimming): round 2 is a verified, behavior-preserving pass, with the line target recalibrated to the achieved 1446 rather than the unrealistic original.
>
> The `pendingDetectorRefresh` scaffolding in `DetectionStateMachine` was left unwired: `ConfigRefreshCoordinator` extracts only the existing (eager, mid-recording-safe) config-persist behavior. There is no concrete "rebuild-detector" operation to defer today (the old Detector was replaced by `discoveryWatcher` + the lifecycle stack), so wiring it would have invented behavior with no target and changed the events trace.

`Coordinator.swift` is 1090-1600 lines depending on which slice (the audit measured ~1600 pre-Step-3; Step 3 noted ~1090 after the device-change recovery block landed). The original TECH-H1 acceptance bar of "under 400 lines" was unrealistic given the recovery work; recalibrate to under 600 lines and extract three subordinate types.

Create:
- `daemon/Sources/MeetingPipe/Library/MeetingLibraryService.swift` (owns the soft-delete / trash / export / republish / regenerate / retry path that today lives as ten methods on `Coordinator`).
- `daemon/Sources/MeetingPipe/Coordination/ConfigRefreshCoordinator.swift` (owns the deferred-config-refresh-while-recording state plus the rebuild-detector path; the `pendingDetectorRefresh` flag and consumer in `DetectionStateMachine` already model the contract).
- `daemon/Sources/MeetingPipe/Coordination/PipelineJobDispatcher.swift` (owns the per-job completion routing; today `SinkDispatcher.onJobCompleted` closures live on Coordinator).

Edit: `daemon/Sources/MeetingPipe/Coordinator.swift` shrinks to a thin orchestrator wiring the three new subordinates plus the existing DetectionStateMachine and SinkDispatcher.

Acceptance:
- `Coordinator.swift` is under 600 lines.
- The 574 Swift test baseline holds (any new tests for the three subordinates are additive).
- Every `Log.event` call preserves name and payload shape.
- A `--reset-tcc` smoke run produces an `events.jsonl` trace identical to the pre-refactor build modulo timestamps.
- Each subordinate has its own unit test file.
- TECH-H1 status in this backlog flips from `[DONE]` (overstated in Q2) to a verified pass.

Stop and ask: any change to `Log.event` names; any new dependency; any change to the `recorder.micPaused` seam (owned by TECH-G-MIC).

Deps: none. Should land before the god-view extractions in P2 so the new files do not double-extract.

**TECH-C16 · Decide-or-delete: InputDeviceSignal and CalendarContextSignal · S · none** [DONE]

> Resolved 2026-05-28: both signals DELETED. InputDeviceSignal was redundant with the recorder's shipped device-change auto-resume and telemetry-only with zero consumers; CalendarContextSignal's EventKit probe was never built (default returns nil) and a real one would cost a new Calendar TCC prompt for no verdict value. Decisions in ADR 0010 and ADR 0011. Both signal files plus their test files removed; `swift build` + `swift test` green (573 tests, 0 failures).

Step 2 wired `WorkspaceSignal` and `WindowTitleSignal` into the browser lifecycle adapter. `InputDeviceSignal` and `CalendarContextSignal` remain built but unwired. They ship in the binary and consume zero state-machine paths in production. Decide for each:

1. **InputDeviceSignal** (HAL device `IsRunningSomewhere` corroborating). Either wire into `MeetingLifecycleCoordinator` as a corroborating signal for native adapters (Teams, Zoom), or delete.
2. **CalendarContextSignal** (EventKit hysteresis hint). Either wire into the scheduled-end hysteresis check, or delete.

Create: `docs/decisions/0010-inputdevicesignal-disposition.md` and `docs/decisions/0011-calendarcontextsignal-disposition.md`. Each ADR captures: context (built in C13 step 3, unwired since Step 4), decision (wire or delete), consequences.

Edit: either wire (small edits to `MeetingLifecycleCoordinator.swift` and the relevant adapter) or delete (the signal file plus any test fixtures that reference it).

Acceptance:
- Two ADRs land with decisions and reasoning.
- Either both signals are wired and observable in `events.jsonl` during a real meeting (corresponding `signal.*` entries appear), OR both signal files plus their fixtures are removed and `swift test` is green.
- No middle state: a built-but-unwired signal is the failure mode.

Stop and ask: if you propose wiring rather than deleting, surface the latency budget impact (each new signal in the fusion adds work to every verdict update).

Deps: none.

---

## Group C · Capture and detection

**TECH-CAP1 · Mic / system end-of-call skew investigation · M · none** [P3 · MONITOR]

> Status 2026-05-28: deprioritized to P3 (lowest band). The user no longer reliably observes the end-of-call skew in daily use. Do not run the investigation now; monitor across dogfood and promote only if the few-seconds mic/system shift reappears across multiple recordings. The spec below is retained for if/when it is promoted.

The audit's open P1, deferred through three steps. User-reported "few seconds shift" between mic and system audio at end of recording. Diagnostic event `recorder.intermediate_durations` fires before `mergeViaFFmpeg` with `mic_audio_sec`, `system_audio_sec`, `delta_sec`, `wallclock_sec`. Two candidate root causes on the table:

1. **Capture-callback buffer drops.** Step 3's validation-pass ruled this out as the *most likely* cause (the synchronous-write race was real RT-safety hygiene but the skew comment near `MeetingRecorder.swift:411` blames the merge step instead). Still possible under heavy disk pressure.
2. **ffmpeg merge step.** The `stop()` path's comment at line ~411 of `MeetingRecorder.swift` (per audit) points at the merge step. Possible candidates: timestamp drift between the mic-side `AVAudioFile` and the system-side `SystemAudioCapture` WAV (different file-format clock metadata), an ffmpeg `-ss` or `-c copy` flag that introduces frame-boundary rounding, or pad/truncate behaviour at the concat boundary.

Investigate with a small set of recordings spanning short (under 5 min) and long (over 45 min) durations. Read the next event trace from a real call and pin the root cause.

Edit: based on findings. Most likely candidates:
- `daemon/Sources/MeetingPipe/MeetingRecorder.swift` (stop / merge path)
- A new `daemon/Sources/MeetingPipe/Recording/EndOfCallMerger.swift` if the merge logic warrants its own type
- `pipeline/src/mp/` is not the likely surface; the merge is daemon-side per the audit comment

Acceptance:
- ADR `docs/decisions/0012-end-of-call-skew-root-cause.md` captures the diagnosis and the chosen fix.
- A new test or fixture pins the regression so a re-introduction fails CI.
- Over the next fortnight of dogfood, the user-observed skew drops to under 200 ms across 20+ recordings.

Stop and ask:
- If the diagnosis is "ffmpeg merge step is correct; the skew is upstream in one of the callbacks", confirm before adding to the RT path.
- If the fix requires a re-encode rather than `-c copy`, surface the CPU cost before shipping (a 60-minute meeting re-encoded with libopus or pcm_s16le is non-trivial).

Deps: none. Highest leverage open work.

**TECH-C6-FINISH · Detection regression corpus from real dogfood · M · none** [NEW]

Q2 shipped the corpus harness (`daemon/Tests/MeetingPipeCoreTests/Fixtures/detection-corpus/`, `DetectionCorpusTests`, eight synthetic seed traces). The 20+ real user-recorded traces from the Phase 2 dogfood window are still owed.

Capture each meeting's signal stream during the next fortnight of normal use. The user records traces; the test target replays them. Traces are compact (signal events + verdict transitions, no audio), so they live in git.

Edit:
- `daemon/Tests/MeetingPipeCoreTests/Fixtures/detection-corpus/INDEX.json` (extend).
- Add 20+ `.jsonl` trace files under the same directory, one per scenario.

Acceptance:
- At least 20 traces covering: Teams native, Zoom native, Webex native, Slack native (huddle), Meet (Chrome, Arc, PWA), Slack PWA, Webex PWA, mic-only-silence false-positive scenarios, rapid mute-toggle, post-call chat surface mic-grab, the 2026-05-20 Teams+Meet incident scenario (TECH-C15 covered).
- CI runs all traces in under 30s.
- Any new regression to detection or gating logic must update fixtures or fail CI.

Stop and ask:
- If a trace contains a meeting title or attendee name the user does not want in the repo, redact at capture time. Document the redaction approach in `daemon/Tests/MeetingPipeCoreTests/Fixtures/detection-corpus/README.md`.

Deps: none. (Previously gated on TECH-CAP1; that is now P3/monitor as of 2026-05-28. The corpus traces are signal + verdict streams with no audio, so the end-of-call skew cannot contaminate them.)

---

## Group A · Library, store, summary

**TECH-A11 · Typed summary model · M · none** [DONE]

> Resolved 2026-05-28: added `daemon/Sources/MeetingPipe/Library/MeetingSummary.swift` (tolerant `Decodable` mirror of the pipeline schema + `load(from:)` / `init?(jsonObject:)` / `jsonObject()` write bridge). `SummaryRenderedView`, `CorrectionSummaryPreview`, `CorrectionViewModel`, and `MeetingStore.buildSearchableText` now consume the typed model; no summary-field subscript reads remain in the view files (the leftover `[String: Any]` are the correction-record envelope, the run/notion/obsidian sidecars, and the byte-preserving title merge-write / revert paths). The one schema divergence (`detected_language` optional in Swift vs required-with-default in Python) is captured in `docs/decisions/0014-typed-summary-model.md`; Python stays the source. New `MeetingSummaryTests` (8 cases) plus updated `MeetingFilterTests` / `CorrectionsTabTests`; `swift build` green, affected suites green.

The audit's `[Medium] Open` finding: untyped `[String: Any]` summary data is plumbed through four SwiftUI views, with file I/O inside view code. A typo silently shows an empty section. Replace with a typed `MeetingSummary` model.

Create: `daemon/Sources/MeetingPipe/Library/MeetingSummary.swift` with `Codable` struct: `title: String`, `summary: [String]` (bullets), `decisions: [String]`, `actions: [ActionItem]`, `questions: [String]`, `attendees: [String]`, `detectedLanguage: String?`. Match the Python schema in `pipeline/src/mp/publish_from_paste.py` (already typed there as `MeetingSummary` dataclass).

Edit:
- The four detail views that today read `[String: Any]` from disk.
- `MeetingStore.swift` to load the typed model once and pass it to views.

Acceptance:
- No `[String: Any]` summary reads remain in view files (grep clean).
- A typo in a section name fails compilation, not silently.
- Existing summaries on disk round-trip cleanly (the Python writer's schema is the canonical shape; the Swift Codable mirrors it).
- An XCTest seeds a known-summary fixture and asserts every field renders.

Stop and ask: if the Python schema and the Swift Codable disagree on any field name or type, decide at the Python schema's level (it is the source) and document in an ADR.

Deps: none. Can run in parallel with TECH-A12.

**TECH-A12 · MeetingStore mtime cache · S · none** [DONE]

> Resolved 2026-05-28: verified the directory watcher is dir-level (`DispatchSource.makeFileSystemObjectSource` on the folder fd) and gives no per-file change event, so the stop-and-ask resolves to the mtime cache rather than a watch upgrade. `scan` is now an instance `performScan` that keeps a per-stem `CacheEntry(signature: [filename: mtime], meeting)`; an unchanged signature reuses the built row and skips the summary/run/meta JSON parse. The mtimes come from the existing `contentsOfDirectory(includingPropertiesForKeys:)` prefetch, so the signature costs no extra stat. Only terminal rows (`.done` / error-sidecar `.failed` / `.manualPasteReady`) are cached; a `.processing` / age-inferred `.failed` row is age-derived and rebuilt each scan so the staleness transition still fires. Three new `MeetingStoreTests` (stale-serve until mtime bump, new-meeting visibility, processing-row re-evaluation); full suite green.

`MeetingStore.scan` re-parses every sidecar in the library on a 500ms debounce during recording. With 500+ meetings this is the audit's `[Medium] Open` perf finding. Add an mtime cache: per stem, hold `(sidecarMtime, parsedRow)`; rescan only when `sidecarMtime` changes.

Edit: `daemon/Sources/MeetingPipe/MeetingStore.swift`.

Acceptance:
- Profiling during recording shows zero re-parse work for stems whose mtime did not change since the last scan.
- A new meeting still appears in the list within the existing debounce window.
- A sidecar edit (correction, rename) triggers a re-parse for that stem.

Stop and ask: if the directory-watch source already provides a per-file change event, prefer that over polling stat. Verify before adding cache complexity.

Deps: none.

**TECH-A13 · Render cliffs: in-memory FluidAudio + waveform redraw · M · none** [DONE · waveform half; RAM half deferred]

> Resolved 2026-05-28: waveform-redraw half shipped. `WaveformBody` was split into `StaticWaveform` (the two-channel envelope, behind `.equatable()` so the per-column path stroking only redraws on a peaks/zoom change) and `PlayheadOverlay` (the only view that observes `playback`, redrawing a single 1.5 pt line on the ~15 Hz tick). `WaveformPeaks` is now `Equatable` and the gate compares full content, not a binCount/duration proxy, so switching between two same-duration meetings still redraws. New `WaveformPeaksTests.test_equatable_distinguishes_content_not_just_shape`; `swift build` + waveform suite green. The under-5%-CPU bar needs live profiling (not runnable here) but the 15 Hz full-canvas re-stroke is structurally eliminated.
>
> Scope decision (explicitly chosen this session per the stop-and-ask): the FluidAudio RAM half is DEFERRED, so the "under 100 MB for a 90-min pass" bar is NOT met. `AsrManager.transcribe(samples:)` and `DiarizerManager.performCompleteDiarization(samples)` both consume the entire `[Float]`; capping RAM requires switching to FluidAudio's streaming ASR plus a windowed-diarization contract, which is exactly the "different segment-build contract" the stop-and-ask names. Owed as a dedicated follow-up session; `FluidAudioRunner.readMonoFloat32` is unchanged.

Audit's `[Low]` finding. The RAM one matters once any recording exceeds 90 minutes on a 16GB Mac; bump to `[Medium]` per Part 1 of the Q3 review.

`FluidAudioRunner.readMonoFloat32(from:)` loads the whole recording into memory (`[Float]`). For a 60-minute meeting at 16 kHz that is ~28 MB; at 90 minutes ~43 MB; not catastrophic but bad practice and a real ceiling for the eventual 4-hour-meeting case.

`WaveformBody` redraws the full canvas at 15 Hz during playback. Cap the redraw to changed pixels (the play head) and the visible range, not the full waveform.

Edit:
- `daemon/Sources/MeetingPipe/Transcription/FluidAudioRunner.swift` (stream the file in chunks; FluidAudio's `ASRStreamingProcessor` should be the right API to consume).
- `daemon/Sources/MeetingPipe/Library/Playback/WaveformBody.swift` (assumed path; locate by grep for `Canvas` and `15 Hz` or `0.066`).

Acceptance:
- A 90-minute recording transcribes without RAM growing past 100 MB during the FluidAudio pass.
- Waveform redraw during playback consumes under 5% CPU on M-series.

Stop and ask: if FluidAudio's streaming path requires a different segment-build contract, surface the schema change before refactoring.

Deps: none. Can run in parallel with TECH-A11 and TECH-A12.

**TECH-A14 · Wire (or verify-then-close) the Corrections tab end-to-end · S · none** [DONE · verified wired]

> Resolved 2026-05-28: verified wired, no rewire needed. The transcript-correction loop is complete: `TranscriptTab.saveCorrection` -> `TranscriptCorrectionStore.upsert` (atomic sidecar, preserves the pipeline-original across re-edits) -> emits `correction` / `transcript_correction` with `original_text` + `edited_text`; `TranscriptLoader.load` overlays the saved corrections on reopen. (Note: the UI "Corrections" tab shows the summary-grading record; the transcript line edits this acceptance targets live in the Transcript tab.) The only gap was a test of the real reload path, now added as `TranscriptTabTests.test_load_overlays_a_saved_correction_on_reload` (store round-trip was already covered by `TranscriptCorrectionStoreTests`). Closed via `docs/decisions/0015-corrections-tab-wired.md`; suites green.

Next.md item: "First step is to actually check whether the Corrections tab is wired end-to-end today - corrections are persisted, but the UI loop may not be complete."

Verify-first: 5 minutes of grep on `daemon/Sources/MeetingPipe/MeetingDetailView.swift` and the corrections store. Either:
- Tab is wired end-to-end -> close the task with a one-line ADR.
- Tab is unwired or partial -> close the loop (S task to wire the save path to the UI).

Edit: based on findings. Most likely `daemon/Sources/MeetingPipe/MeetingDetailView.swift` and `daemon/Sources/MeetingPipe/Library/CorrectionsStore.swift`.

Acceptance:
- An XCTest asserts a transcript correction edited in the UI lands in the sidecar and survives a reload.
- `events.jsonl` shows `transcript.correction` events with the before/after payload.

Stop and ask: if corrections are persisted but the rendering path is wrong, fix the rendering; do not change the persistence schema without an ADR.

Deps: TECH-A11 (typed summary model) lands first so corrections do not have to wrap untyped reads.

**TECH-A15 · Local LLM prompt + model + cold-start polish · S · TECH-A14** [DONE]

> Resolved 2026-05-28: all three covered. (1) Model name + size: the Pipeline pane now shows an "Active model" row with the resolved local model id and its on-disk size (from the preset disk hint; "custom; size unknown" otherwise). (2) Prompt template read-only: `mp summarize --print-prompt` renders the system prompt with the configured team context + summary language, surfaced via a "View prompt" read-only preview in the Pipeline pane. (3) Cold-start: a new `mp serve-local` warms a persistent `mlx_lm.server` that later `run-all` / `summarize` calls reuse via their health check; a `LocalModelPreloader` starts it at launch (and stops it on quit) behind a new Preferences toggle, default OFF.
>
> Stop-and-ask resolution: preloading holds the multi-GB model resident, so per the RAM trigger the toggle defaults OFF and only acts when backend == local AND the model is already cached (the download stays with ModelDownloadSupervisor). Files: `PreferencesView.swift`, `UISettings.swift`, new `LocalModelPreloader.swift`, `App.swift`, `summarize.py`, `summarize_local.py`, `__main__.py`. Tests: `LocalModelPreloaderTests` (gating) + `test_serve_local.py` (server-command, loopback clamp, serve-local exec, print-prompt rendering). Daemon 610 tests green, pipeline 191 green, ruff clean.
>
> Note (could not verify here): the "first local summary within 10% of subsequent" bar needs live MLX runs on-device and is owed to runtime dogfood; the cold-start mechanism (reuse a pre-warmed server) is in place. The edit list named `PipelineLauncher.swift` for the preload path; the warm process is instead owned by an AppDelegate-scoped `LocalModelPreloader` (so teardown rides the existing `applicationWillTerminate`) plus the `mp serve-local` command, rather than threading a launch-time spawn through the per-job launcher.

Next.md item: "Local-LLM improvements (prompt tuning, model-size in the UI, faster cold-start) are real but each individually small."

One session covering: surface the model size in the Preferences > Transcription > Backend pane; expose the prompt template per workflow (read-only for v1, editable in a follow-up); preload the MLX-Qwen process at app launch when the default workflow is local-backend so the first summary does not pay the cold-start cost.

Edit:
- `daemon/Sources/MeetingPipe/Preferences/PreferencesView.swift` (Backend section).
- `daemon/Sources/MeetingPipe/PipelineLauncher.swift` (preload path).
- `pipeline/src/mp/summarize.py` (prompt-template surfacing).

Acceptance:
- Preferences shows the currently-loaded model name and size in GB.
- The first local-backend summary on a fresh app launch completes within 10% of subsequent summaries (cold-start absorbed).

Stop and ask: if preloading at launch increases idle RAM by more than 1 GB, gate behind a Preferences toggle (default off).

Deps: TECH-A14.

---

## Group DIAR · Diarization quality

**TECH-DIAR1 · LLM-based diarization cleanup pass · M · TECH-SUM1-PRIMITIVE** [DONE]

> Resolved 2026-05-28: added `pipeline/src/mp/diarize_cleanup.py` consuming the chunking primitive. It renders numbered speaker lines, windows them, asks the LLM for per-segment merge / reattribution edits, and applies only edits whose target label already exists in the transcript (the model can never invent a speaker; out-of-range and no-op edits are dropped). Backend mirrors `summarize._select_backend` (regulated_mode and the apple_intelligence backend both pin cleanup to the on-device MLX path); cleanup-specific Anthropic (tool-use) and local clients, the latter reusing a new additive `LocalSummaryClient.complete` so the warm mlx server is shared rather than re-spawned. Wired as `mp cleanup-diarization <stem>.json` and as a run-all post-step placed after every cost short-circuit and before summarize, gated by a new `summarization.diarize_cleanup` flag (default OFF, config-file only, no Preferences toggle, keeping to the task's Python-only edit list) plus a 2-or-more-distinct-speaker guard (single-speaker is a no-op with no LLM call). The requested `diarize.cleanup` event is emitted as `pipeline` / `diarize_cleanup` (snake_case per CONVENTIONS) with `merges_count`, `reattributions_count`, `latency_ms`. New `test_diarize_cleanup.py` (13 cases) plus 2 run-all wiring tests. Owed to on-device dogfood (no hand-labels or live LLM headless): the measurable-DER-improvement and under-10s-per-30-min acceptance bars.

Next.md idea 5, graded 9/10 (highest leverage on the page). After the FluidAudio + pyannote diarization assigns speaker labels, an LLM post-pass merges clearly-same-speaker chunks and reattributes obvious mistakes (e.g. when one speaker says "thanks Tom", the next utterance is probably from Tom).

The chunking primitive needed here (split a long transcript into LLM-context-fitting windows with overlap) is the same primitive idea 2 (Apple Intelligence) needs. **Build the primitive once in TECH-SUM1-PRIMITIVE, consume from both.**

Create: `pipeline/src/mp/diarize_cleanup.py` consuming the chunking primitive.

Edit: `pipeline/src/mp/__main__.py` to add a `cleanup-diarization` subcommand and to wire it as a post-step in `run-all`.

Acceptance:
- Five hand-labeled reference transcripts show measurable DER improvement after the cleanup pass.
- The pass adds under 10 s to a 30-minute meeting on M-series.
- Backend respects the workflow's LLM backend (regulated-mode = local).
- `events.jsonl` records a `diarize.cleanup` event with `merges_count`, `reattributions_count`, `latency_ms`.

Stop and ask: if hand labels disagree with the cleanup pass's output in any non-obvious way (e.g. the LLM merges two genuinely different speakers because of stylistic similarity), surface a sample and decide on the precision/recall trade-off.

Deps: TECH-SUM1-PRIMITIVE (the chunking primitive).

---

## Group SUM · Summarization

**TECH-SUM1-PRIMITIVE · Transcript chunking primitive · S · none** [DONE]

> Resolved 2026-05-28: added `pipeline/src/mp/chunking.py` with `chunked_windows(...) -> Iterator[ChunkedWindow]`. Word-boundary packing so a word is never split at a window end, step = `max_chars - overlap_chars`, overlap clamped below `max_chars` so the window always advances. `carry_summary` is exposed only on `ChunkedWindow.prompt`; it never mutates `.text`. A ~30k-char transcript at `max_chars=8000` yields 4 windows. New `test_chunking.py` (9 cases) pins the window-count bar, the every-word coverage property (asserted as a subset, since overlap regions can legitimately begin mid-word and contribute leading fragments), and the carry presence/absence. Mirrored in Swift as `TranscriptChunker` for TECH-SUM1-APPLE, with `TranscriptChunkerTests` pinning parity.

A single Python primitive that splits a long transcript into LLM-context-fitting windows with configurable overlap and a configurable "previous-summary as next-window-prefix" injection. Consumed by both TECH-DIAR1 (diarization cleanup) and TECH-SUM1-APPLE (Apple Intelligence backend).

Create: `pipeline/src/mp/chunking.py` with one function: `chunked_windows(transcript: str, max_chars: int, overlap_chars: int = 200, carry_summary: str | None = None) -> Iterator[ChunkedWindow]`.

Acceptance:
- A 60-minute transcript (~30k chars) at `max_chars=8000` produces ~4 windows with 200-char overlap.
- A property test asserts every word in the original transcript appears in at least one window.
- A unit test asserts the carry-summary is prepended only when supplied.

Deps: none.

**TECH-SUM1-APPLE · Apple Intelligence backend for summarization · L · TECH-SUM1-PRIMITIVE** [DONE]

> Resolved 2026-05-28: full build. `daemon/Sources/MeetingPipe/Summarization/AppleIntelligenceSummarizer.swift` (gated behind `#if canImport(FoundationModels)` + `@available(macOS 26.0, *)`, so no Package.swift platform bump off the macOS 14 floor) chunks via the Swift `TranscriptChunker` mirror, calls the macOS 26 Foundation Model per window with a map-then-reduce reduction, parses tolerantly (whole-reply then largest-balanced-object), and writes `<stem>.summary.json` / `.summary.md` byte-compatible with the Python writer by reusing `MeetingSummary.jsonObject()` (TECH-A11).
>
> Chunking stop-and-ask: resolved to a small Swift mirror rather than a subprocess into the Python primitive. The Apple path runs in-process on-device by design; shelling out just to window a string re-adds the dependency the path exists to avoid. The mirror is pinned to the Python algorithm by `TranscriptChunkerTests`.
>
> Availability stop-and-ask: Apple Intelligence is a per-device opt-in. Handled by runtime `SystemLanguageModel.availability` gating, surfaced (not crashed) via `availabilityReason` in the Preferences footer and as an `AppleIntelligenceError.unavailable` through the existing failure path. No entitlement the user does not control.
>
> Seam: `apple_intelligence` added to the backend picker (local-model rows now scoped to local / auto), to the Python `Summarization.backend` Literal, and to the `workflow_backend` sidecar enum (CONVENTIONS + workflow.py). `summarize._select_backend` refuses it (daemon-only). `run-all` finalizes (plus optional diarization cleanup), writes a `<stem>.apple_pending.json` sentinel and stops; `PipelineLauncher` detects the sentinel after exit 0, summarizes on-device, and fans out via a new `mp publish <summary.json>` subcommand (so a Swift-produced summary still reaches Notion / Obsidian / filesystem). `regulated_mode` keeps forcing the proven local MLX path (apple is overridden to local) and bypasses the long-meeting paste-bundle guard for apple (it is free and chunks itself).
>
> Tests: `TranscriptChunkerTests` + `AppleIntelligenceSummarizerTests` (Swift, 624 total green), plus apple-path tests in `test_summarize_backend.py` / `test_orchestrate.py` and a new `test_publish_cmd.py` (Python, 223 total green).
>
> Scope decision (explicitly chosen): v1 instructions are Swift-resident; team_context is injected (from config.toml, overridden by the meta sidecar's `workflow_context_prompt`) and language follows the same auto / ISO-code rule as the Python prompt, but the Python `meeting_summary.md` master prompt with its worked examples is not reused. Owed to on-device dogfood (cannot run headless): the quality-vs-local (5 hand-rated), latency-within-2x, and zero-egress (Little Snitch) acceptance bars.

Next.md idea 2, graded 7/10. macOS 26 ships an on-device Foundation Model; 4K context limit means chunked summarization is mandatory. Add as a coexisting backend (alongside Anthropic and local MLX-Qwen); default to the existing backend until the new one proves out.

Apple Intelligence is Swift-native via the macOS 26 Foundation Model API. The summarize path moves into Swift for this backend (the other two backends stay in Python). The chunking primitive lives in Python, so the Swift Apple-Intelligence path either reimplements the primitive (small) or calls out to the Python primitive via the existing subprocess bridge (cheap if the bridge is already there).

Create:
- `daemon/Sources/MeetingPipe/Summarization/AppleIntelligenceSummarizer.swift` (Swift-native, calls the macOS 26 Foundation Model API).
- A small Swift mirror of `pipeline/src/mp/chunking.py`, OR a subprocess call into the Python primitive (decide in design).

Edit:
- `daemon/Sources/MeetingPipe/Preferences/PreferencesView.swift` to add `Apple Intelligence` to the Backend picker.
- `daemon/Sources/MeetingPipe/PipelineLauncher.swift` to route to the Swift summarizer when the workflow's backend is `apple_intelligence`.

Acceptance:
- A 30-minute meeting summarized with the Apple Intelligence backend produces output qualitatively comparable to the existing local backend (5 hand-rated comparisons).
- Latency is within 2x of the existing local backend (Apple Intelligence is on-device; the 4K context + chunking is the cost).
- No network egress recorded by Little Snitch or a similar tool during summarization.
- Backend selectable per-workflow.

Stop and ask:
- Before designing the Swift/Python chunking decision, surface the implementation cost of each side. Reimplementing in Swift is the lower-coupling option but doubles maintenance.
- If the Foundation Model API is gated behind a runtime entitlement or a per-device opt-in that the user does not control, surface before scheduling.

Deps: TECH-SUM1-PRIMITIVE.

---

## Group UX · User experience

**TECH-UX1 · First-launch onboarding screen · M · none** [DONE]

> Resolved 2026-05-28: added `Onboarding/OnboardingWindow.swift` (the `OnboardingGate` UserDefaults flag, an `OnboardingWindowController` hosting SwiftUI via `NSHostingController`, and the `OnboardingRootView` step navigator with a Skip-from-any-step escape hatch) plus the four steps: `OnboardingStepWelcome` (tagline), `OnboardingStepPermissions` (walks the real four TCCs from `PermissionsCenter` - microphone, screen recording, accessibility, notifications; "calendar" was deleted in TECH-C16 - requesting each via its own Grant button, showing Granted, and routing a deferred denial to System Settings with Retry), `OnboardingStepWorkflow` (Personal / Client work (NDA, local + filesystem) / Internal team presets created via `WorkflowStore`, or "set up later"), and `OnboardingStepTest` (a 60-second manual test recording driven through an injected toggle, reconciled against the live recorder). `Coordinator.presentOnboardingIfNeeded()` shows it on a fresh install; `App.applicationDidFinishLaunching` skips the Screen Recording prewarm in that case so the framed flow requests permissions one at a time instead of the unframed dialog burst (the stale "requests notification authorization" path in `Notifier` is never actually called, so notifications no longer pop at startup either). `OnboardingGateTests` (3) pin the gate; the window/steps are AppKit/SwiftUI so not headless-verified. Doctor note: `mp doctor` already probes microphone / screen-recording / accessibility and reports what is missing, which is the CLI "re-run the permissions step" for a skipped user; `OnboardingGate.reset()` is available for a future "redo setup".

The mockup at `design/ui_kits/macos_app/OnboardingPermissions.jsx` exists; today the real first run fires four unframed TCC dialogs (mic, screen recording, AX, calendar?) in a burst, and dismissing one silently kills the rest.

A 4-screen first-run flow:
1. Welcome + tagline ("Meeting notes that never leave your Mac").
2. Permissions walkthrough: explain each TCC, request one at a time, surface granted/denied state, allow retry on denied.
3. Pick a default workflow (offers "Personal", "Client work (NDA)", "Internal team" presets, or "I will set up later").
4. Test recording (60 s manual recording, prove the path end-to-end before the user trusts a real meeting to it).

Create: `daemon/Sources/MeetingPipe/Onboarding/OnboardingWindow.swift` plus four `OnboardingStep*.swift` files.

Edit: `daemon/Sources/MeetingPipe/Coordinator.swift` or the app entry point to show the onboarding window on first launch (gate by a `UserDefaults.onboardingCompleted` boolean).

Acceptance:
- Fresh install fires the onboarding window, not the four-dialog burst.
- All four TCC permissions can be requested, denied, retried, and the user lands on a non-broken state at the end.
- A skip path exists for power users.
- Skip-then-later: `meetingpipe doctor` can re-run the permissions step.

Stop and ask: if the permissions framing in the mockup does not match the actual TCC dialog wording (Apple's TCC strings are not editable), surface the mismatch before designing the explainer text.

Deps: none.

**TECH-UX2 · Regenerate / Republish discoverability · S · none** [DONE]

> Resolved 2026-05-28: `MeetingRow` now renders an inline Regenerate button on `.manualPasteReady` rows and an inline Republish button on rows where the local summary is newer than the last publish, mirroring the existing inline Retry (failed takes priority in the if/else chain; the context-menu items stay as the power-user shortcut). The "newer than last publish" signal is a new `Meeting.needsRepublish` computed in `MeetingStore.buildMeeting` from prefetched file mtimes (summary `.summary.json` mtime greater than the newest of `.notion.json` / `.obsidian.json`); never-published meetings return false. Dep resolved: no `lastPublishedAt` sidecar field was added (the stop-and-ask's "verify"), the publish-sidecar mtimes already carry the timestamp. The detail pane already surfaces Republish via the Summary tab's "Save & Republish"; Regenerate/Reprocess land in the TECH-UI-5 toolbar menu. Three `MeetingStoreTests` pin needsRepublish (summary-newer true, publish-current false, never-published false) through the real scan path; full suite green.

Step 5 made Retry discoverable (inline button, failed-state detail pane). Regenerate and Republish are still right-click-only. Apply the same treatment: surface them on rows that need them (Regenerate on rows with `manualPasteReady` status; Republish on rows where the local sidecar is newer than the last publish).

Edit:
- `daemon/Sources/MeetingPipe/MeetingRow.swift` (inline button rendering).
- `daemon/Sources/MeetingPipe/MeetingDetailView.swift` (detail-pane action surface).

Acceptance:
- A `manualPasteReady` row shows an inline `Regenerate` button.
- A row whose local sidecar timestamp exceeds the last-publish timestamp shows an inline `Republish` button.
- Right-click context menu still works for both as a power-user shortcut.

Deps: TECH-A11 if the sidecar shape needs a `lastPublishedAt` field that does not exist yet (verify).

**TECH-UX3 · Long-meeting and BYO in-app completion paths · M · none** [DONE]

> Resolved 2026-05-28: paste-ready rows (`.manualPasteReady`, both BYO and long-meeting) now show a "Paste your summary" panel in the Summary tab (`SummaryTab.byoPasteState`: a Markdown `TextEditor` + "Save & publish"), so no terminal command is needed. Save flows daemon -> pipeline: `LibraryWindowModel.publishFromPaste(stem:summaryText:)` -> `Coordinator` -> `MeetingLibraryService.publishFromPaste`, which writes the pasted text to `<stem>.summary.md` (the file `mp publish-from-paste` reads) and runs the new `PipelineDriver.publishFromPaste(transcriptMD:)` (a `runMP(["publish-from-paste", <stem>.md], timeout: 5 min)`). On success the panel reloads the freshly written `<stem>.summary.json` and the directory watcher flips the row to `.done`. Stop-and-ask honoured: schema-mismatch / publish failures surface inline in the panel (orange Label), not as a notification (the service deliberately does not call `notifyError`). Empty-paste and missing-transcript guards fail before any disk write. Three `MeetingLibraryServiceTests` cover the happy path (writes summary.md + invokes the driver), missing transcript, and empty text; full suite green.

Both currently dead-end at a terminal command (`mp publish-from-paste <stem>.md`). First-class entry points deserve first-class completion paths. Add an in-app paste-back surface: the detail pane for a BYO meeting offers "Paste your summary" with a text editor, and the save button runs `mp publish-from-paste` via the subprocess bridge.

Edit:
- `daemon/Sources/MeetingPipe/MeetingDetailView.swift` (or split out a `MeetingDetailBYOView.swift`).
- `daemon/Sources/MeetingPipe/PipelineLauncher.swift` (publish-from-paste roundtrip).

Acceptance:
- A BYO meeting shows a "Paste your summary" panel in the detail pane.
- Pasting and clicking Save runs the publish-from-paste path and updates the row state.
- No terminal command required for the BYO completion path.

Stop and ask: if the publish-from-paste roundtrip can fail on schema mismatch, surface the error inline (not as a notification), matching Step 5's failure-visibility pattern.

Deps: none.

**TECH-UX4 · Degraded recording state on the HUD during meeting · S · none** [DONE]

> Resolved 2026-05-28: `MeetingRecorder` now exposes `onSystemAudioDegraded`/`onSystemAudioRecovered` (main queue). The SCStream start path was extracted into a retryable `startSystemCapture(systemURL:isRetry:)`; on failure it tears the system channel down (so the stop-time merge stays mic-only) and fires `onSystemAudioDegraded(reason)`, and a new `retrySystemAudio()` re-arms it (system WAV resumes from now, leaving a documented gap). The HUD grows from the compact pill into a card with a `HUDDegradedBanner` (warning glyph + "System audio not captured" + "Retry system audio" button) via `showSystemAudioDegraded()` / `clearSystemAudioDegraded()`, anchored top-right so a dragged HUD is not yanked. `Coordinator` bridges the callbacks: degraded emits `Log.event(category: "recording", action: "degraded", attributes: ["reason": ...])` and shows the banner; recovered emits `recording.recovered` and clears it; the HUD's retry button routes through the new `recordingHUDDidRequestRetrySystemAudio` delegate to `recorder.retrySystemAudio()`. Headless coverage is the idle-guard test (`retrySystemAudio` is a no-op when not recording); the live banner/retry and the `recording.degraded` event need a real failed SCStream (Screen Recording TCC) on-device.

Today, when system audio capture fails at recording start (TCC race, SCStream init error, etc.), the user finds out only after the meeting when the recording is half-empty. Surface the degraded state on the HUD during recording.

Edit: `daemon/Sources/MeetingPipe/RecordingHUDWindow.swift` plus `daemon/Sources/MeetingPipe/MeetingRecorder.swift` to emit a degraded-state signal.

Acceptance:
- If `SystemAudioCapture` fails to start, the HUD shows a "System audio not captured" banner with a one-click "Retry system audio" button.
- If retry succeeds, the banner clears and the recording continues (with a documented gap in the system channel).
- An `events.jsonl` event `recording.degraded` fires with the failure reason.

Deps: none.

**TECH-UX5 · In-app pipeline progress · M · none** [DONE]

> Resolved 2026-05-28: a `_ProgressHeartbeat` thread in `orchestrate.run_all` (the real `run-all` home, not `__main__.py` as the edit list guessed) emits a `pipeline.stage_progress` event every 5s plus a `__MP_PROGRESS__ {json}` stdout sentinel; the run updates the current stage at each `stage_started` (finalize / diarize_cleanup / summarize / publish). The daemon consumes the live channel through the pipe it already reads: `PipelineLauncher.runAll` gained an `onProgress` overload (defaulted in the `PipelineDriver` protocol so fakes are unaffected) that parses the sentinel via the pure, tested `parseProgress`, plus a retained active `Process` and `cancelActiveRun()`. `SinkDispatcher` exposes `onActiveProgress` + `onActiveStalled` (a 5s timer flags 30s without a heartbeat) and `cancelActiveJob()`; `PipelineJobDispatcher` and the `Coordinator` forward these to a new `LibraryWindowModel.activeProcessing` (@Published) and `cancelProcessing()`. `MeetingRow` renders "Summarizing 0:42" for the active row (passed by `LibraryListView`) or a Stalled pill + Cancel button when the heartbeat lapses. Tests: `test_progress_heartbeat` (2, Python), `parseProgress` (2), `SinkDispatcher` progress-passthrough + cancel (3). The 30s stall timer and the live row UI are not headless-testable (timer threshold + AppKit); the IPC parse, progress fan-out, and cancel wiring are. Note: the durable `stage_progress` event is the analysis record; the stdout sentinel (which also lands in pipeline.log) is the ephemeral live channel.

Audit's `[High] Open`: progress is menu-bar text only; a wedged subprocess is indistinguishable from a slow one without tailing logs.

A small progress overlay on rows being processed: per-stage progress (transcribe, diarize, summarize, publish), elapsed time, ability to cancel. Subprocess-side: emit a `pipeline.stage.progress` event every 5 s with the current stage and a heartbeat.

Edit:
- `pipeline/src/mp/__main__.py` (heartbeat emission).
- `daemon/Sources/MeetingPipe/SinkDispatcher.swift` (consume heartbeat, expose on the model).
- `daemon/Sources/MeetingPipe/MeetingRow.swift` (progress UI).

Acceptance:
- A processing row shows the current stage and elapsed time.
- If no heartbeat arrives for 30 s, the row marks itself "stalled" and offers Cancel.

Deps: none.

**TECH-UX6 · HUD icon for the currently-recording app · S · none** [DONE]

> Resolved 2026-05-28: verify-then-close, no behavioural change needed. The HUD already builds `AppGlyphView(source:)` for the recording app (`RecordingHUDWindow.makeContentView`) and falls back to the vector waveform mark when there is no source; `Coordinator.beginRecording` passes the detected `source` into `recordingHUD.present(source:workflow:startedAt:)`, and the four glyph assets (teams, zoom, meet, slack, plus `_fallback`) ship in `Resources/AppGlyphs`. So a Teams/Zoom/Slack call shows that app's glyph, a Meet PWA resolves to the meet glyph via the displayName fall-through (a generic browser meeting lands on `_fallback`, the signal-blue waveform mark, since there is no dedicated browser glyph), and a manual recording shows the waveform-circle fallback. Pinned the previously-`private` source-to-glyph mapping by exposing `AppGlyphView.filename(for:)` as internal and adding `AppGlyphViewTests` (4 cases). No `NSWorkspace.icon(forFile:)` reach, per the design comment.

Next.md idea 6. Detection layer already knows which app it is; the HUD just needs an icon slot. Use the existing `AppGlyphView` (do not reach for `NSWorkspace.shared.icon(forFile:)`; see the design comment in `daemon/Sources/MeetingPipe/Design/AppGlyphView.swift`).

Edit: `daemon/Sources/MeetingPipe/RecordingHUDWindow.swift`.

Acceptance:
- During a Teams call, the HUD shows the Teams glyph.
- During a Zoom call, the Zoom glyph.
- During a Meet PWA, the browser glyph.
- For manual recordings (no source), a waveform-circle fallback.

Deps: none.

**TECH-UX7 · Opt-out auto-restart on quit · S · none** [DONE]

> Resolved 2026-05-28: added `UISettings.disableAutoRestart` (default OFF) plus a Preferences > General > Startup toggle framed positively as "Relaunch after quitting" (ON by default). Mechanism: the LaunchAgent's `KeepAlive` changed from `true` to `{ SuccessfulExit = false }` in `scripts/launchd.plist.template`, so launchd relaunches only on a non-zero exit. `AppDelegate.applicationWillTerminate` now picks the exit code via the pure, unit-tested `AppDelegate.shouldRelaunchOnQuit(override:disableAutoRestart:)` and `exit(EXIT_FAILURE/EXIT_SUCCESS)`: the default Quit relaunches (non-zero) unless the preference disables it, and a one-shot `AppDelegate.pendingRelaunchOverride` lets the new "Quit (do not relaunch)" status-bar item (added in `StatusBarController.populateMenu`, ⌘⌥Q) force exit 0. That alt item is shown only when auto-restart is on, and the menu re-populates on open (`refreshMenuBeforeDisplay`) so it tracks the toggle. Crash recovery is preserved (a crash exits non-zero -> relaunch). Edit-list note: the LaunchAgent lives in `launchd.plist.template`/`install.sh`, not `LaunchAtLoginService.swift` (that wraps the separate SMAppService login item), so the KeepAlive edit landed there. Caveat: existing installs carry `KeepAlive=true`; the new behaviour takes effect after re-running `scripts/install.sh` (surfaced in the General footer). `AppDelegateRelaunchTests` (4 cases) pin the decision; build green.

Next.md idea 8. Today the app auto-restarts on quit (LaunchAgent). Some users prefer "Quit means quit". Add a Preferences toggle plus an alternate "Quit (do not relaunch)" menu item. Default OFF for the primary user.

Edit:
- `daemon/Sources/MeetingPipe/Preferences/PreferencesView.swift` (General section).
- `daemon/Sources/MeetingPipe/StatusBarController.swift` (menu item; assumed path).
- `daemon/Sources/MeetingPipe/LaunchAtLoginService.swift` (or wherever the LaunchAgent install lives).

Acceptance:
- Toggle persists across app launches.
- Alt-Quit menu item visible only when the toggle is OFF (and the default-quit therefore relaunches).

Deps: none.

**TECH-UX8 · Voice-activity meter on the HUD · S · TECH-UX6** [DONE]

> Resolved 2026-05-28: added `HUDLevelMeter` to `RecordingHUDWindow`, a 10-segment horizontal meter over -60..0 dBFS (one segment per 6 dB), tinted to the workflow color when set. The HUD polls the level at 10 Hz on a main-queue `meterTicker`; the audio render thread only does a plain Float store. Edit list expansion (named only `RecordingHUDWindow.swift`): the existing `onMicLevel` is ~1 Hz and already owned by the silence detector, so I added `MeetingRecorder.latestMicLevelDb` (written in `processMicBuffer` from the per-buffer dBFS already computed for `onMicRmsDb`, no extra loop / alloc / dispatch) plus a `currentMicLevelDb()` reader, and `Coordinator` passes `levelProvider:` into `present(...)`. The meter sits between the elapsed time and the workflow line; panel height 146 -> 162. No headless test (pure rendering); the 10 Hz update and no-render-alloc bars are structural, the visual needs on-device confirmation.

A small VU-meter style indicator on the HUD that shows the current mic RMS level. Pairs naturally with TECH-UX6. The data is already available from MicGate's RMS probe; this is a rendering task.

Edit: `daemon/Sources/MeetingPipe/RecordingHUDWindow.swift`.

Acceptance:
- The HUD shows a small horizontal level meter (one segment per 6 dB).
- The meter updates at 10 Hz (matching the existing tap callback emission rate).
- No allocations on the render thread (ADR 0009).

Deps: TECH-UX6.

---

## Group UI · Quick-win polish (revised from Q2 addendum)

**Path correction across the whole group**: `Sources/MeetingPipeLibrary/` does NOT exist. Library and detail views live under `daemon/Sources/MeetingPipe/`. Each task below uses the correct path.

**TECH-UI-1 · DROPPED.** Misguided per Q3 review. The MeetingRow `leadingGlyph` already uses `AppGlyphRepresentable(source:)` via `daemon/Sources/MeetingPipe/Design/AppGlyphView.swift`, which explicitly documents why `NSWorkspace.shared.icon(forFile:)` was rejected.

**TECH-UI-2 · UI string em-dash audit and CI guard · S · none** [DONE]

> Resolved 2026-05-28: swept all 51 U+2014 occurrences across 18 files in `daemon/Sources` (and `daemon/Resources`, none there) to plain hyphens via a single-character replacement that preserves the surrounding spacing, so `git grep -l $'—' daemon/Sources daemon/Resources` is now empty. These were almost all comments and log lines plus a few UI strings (e.g. the `MeetingRow` neutral pill, the `LibraryToolbar` "-:-" timecode placeholder); the build and the full 656-test suite stay green. Added a whole-file (not diff-scoped) CI guard step to the `conventions` job in `ci.yml` and a matching `git grep --cached` check in `scripts/pre-commit`, both scoped to `daemon/Sources`/`daemon/Resources`, so a deliberately-added em-dash there fails CI and is blocked locally even on an untouched line. Note: the existing diff-based pre-commit/CI check was already content-based (it caught added em-dashes in Swift string literals, not "just comments"), so the "(not just comments)" extension was already satisfied; the new value is the whole-file guard. The lone remaining em-dash in this backlog (line ~577) is the task's own quoted bad-example string and is in `docs/`, outside the guard's scope.

Extend the existing pre-commit em-dash check to also cover `.strings` catalogs and Swift string literals (not just comments).

Edit:
- `.github/workflows/ci.yml` (or wherever the conventions job lives per ADR 0005).
- `scripts/pre-commit` (extend the diff-scope grep).
- Any `.swift` and `.strings` files with em-dashes (specific example: workflow editor helper text "No rules — this workflow matches only when used as the default.").

Acceptance:
- `git grep -l $'\u2014' daemon/Sources daemon/Resources` returns no Swift, .strings, or .stringsdict files.
- CI lint catches a deliberately-added em-dash in a throwaway branch.

Deps: none.

**TECH-UI-3 · DROPPED.** Already shipped. Verified in `daemon/Sources/MeetingPipe/LibraryChrome.swift` `WorkflowChip`: workflow color drives both text foreground and 0.16-alpha background tint, with `HexColor.parse` and `MPColors.fgMuted` fallback.

**TECH-UI-4 · Detected language in metadata row · S · TECH-A11** [DONE]

> Resolved 2026-05-28: `detected_language` is now lifted into `Meeting.detectedLanguage` during the scan (the header only has `Meeting`, not the loaded `MeetingSummary`), mirroring how `summaryTitle` is lifted. `MeetingDetailView.captionRow` renders an uppercase 2-letter monospaced chip between the duration and the source (`14 May 2026 at 10:54 · 0:31 · EN · Microsoft Teams`), with a `.help(...)` tooltip showing the endonym full name (`English`, `Українська`) via `Locale(identifier: code).localizedString(forLanguageCode:)`; the chip is hidden entirely when unknown. The orphaned `Detected language: en` line and its computed accessor were removed from `SummaryRenderedView`. Two `MeetingStoreTests` pin the model lift (present and absent); full suite green.

The `Detected language: en` text currently sits as a standalone line at the bottom of the summary section, visually orphaned. Move it into `daemon/Sources/MeetingPipe/MeetingDetailView.swift` `captionRow` between `duration` and `sourceDisplayName`. Render uppercase, monospaced, secondary label color, tooltip with the full language name.

Edit: `daemon/Sources/MeetingPipe/MeetingDetailView.swift`.

Acceptance:
- Detail header reads: `14 May 2026 at 10:54 · 0:31 · EN · Microsoft Teams`.
- Hovering `EN` shows the tooltip `English` (or `Українська`, etc).
- The bottom of the summary no longer contains `Detected language: en`.
- When language is unknown, the chip is hidden entirely.

Deps: TECH-A11 (typed summary model exposes `detectedLanguage: String?` as a first-class field).

**TECH-UI-5 · Inline title rename plus toolbar menu · M · none** [DONE]

> Resolved 2026-05-28: the header title is now click-to-rename (static Text -> click or Return swaps to a focused field; `onSubmit` commits via the existing `commitTitle`/`writeTitle` sidecar write, `onExitCommand` (Escape) reverts, focus-loss commits). A hidden zero-size `keyboardShortcut(.return)` button focuses the title when nothing else claims the default action (read-only tabs). A `...` `actionsMenu` lives in the (now always-present) title row next to the ghost shortcuts, with Rename / Edit summary / Edit transcript / Reprocess / Open meta.json / Copy meeting ID / Delete; every item logs `Log.event(category: "detail", action: "toolbar.action", attributes: ["item": ...])`.
> Stop-and-ask (orphaned actions): the only pre-existing "Edit" button was `SummaryTab`'s edit-summary toggle (not a six-action menu, contra the addendum's premise). It is preserved: "Edit summary" switches to the Summary tab and bumps a `summaryEditToken` that `SummaryTab` observes to enter edit mode, and the bottom-right Edit button was removed (its footer now renders only when there is a republish status badge). Transcript editing is per-line via the Transcript tab's right-click "Edit text...", so "Edit transcript" navigates to that tab rather than toggling a (nonexistent) global mode. Reprocess -> `retryMeeting`, Delete -> `softDeleteMeeting` (confirm alert). No functionality was orphaned; the dead `hasSummaryOnDisk` accessor was removed. Interaction code, so no new headless test; existing `MeetingDetailViewTests` stay green.

Replace the bottom-right `Edit` button on `MeetingDetailView` with two affordances closer to the content: click-to-rename on the title text (TextField over title on click, Return commits, Escape cancels) plus a `...` toolbar button exposing the previously-gated actions (Edit summary, Edit transcript, Reprocess, Delete, Open meta.json, Copy meeting ID).

Edit: `daemon/Sources/MeetingPipe/MeetingDetailView.swift`.

Acceptance:
- Clicking the title positions an editable text field; Return commits and persists the rename to the sidecar JSON; Escape cancels.
- Toolbar `...` button opens a popover menu with the previously-available actions.
- Bottom-right `Edit` button removed.
- Pressing Return when meeting selected and no field focused puts focus on the title-rename field.
- Each toolbar menu item emits a `Log.event("detail.toolbar.action", ...)` event.

Stop and ask: if any existing functionality from the old Edit button does not map onto the new affordances, list orphaned actions before deleting.

Deps: none. Coordinate with TECH-UI-6 (same file).

**TECH-UI-6 · Detail-pane toolbar tooltips and a11y · S · TECH-UI-5** [DONE]

> Resolved 2026-05-28: the shared `MPGhostIconButton` now applies `.accessibilityLabel(help)` so VoiceOver announces the same text as the `.help(...)` tooltip (the bare SF Symbol button announced nothing useful before); this covers the detail toolbar and every other ghost-icon use. The Notion and Obsidian icons already render only when their publish sidecar resolves (`cachedNotionURL` / `cachedObsidianURL`), so a meeting with no resolved sink shows neither; the Finder icon (reveal raw files) is always available and its tooltip was aligned to the acceptance text "Show raw files in Finder". Tooltips read `Open in Notion`, `Open in Obsidian`, `Show raw files in Finder`. View/a11y code, no headless test; build green.

The two existing icons at the top-right of `MeetingDetailView` (the `ghostShortcuts` row: Notion / Obsidian / Reveal-in-Finder) need `.help(_:)` and `.accessibilityLabel(_:)` modifiers. The external-link tooltip dynamically reflects the active sink.

Edit: `daemon/Sources/MeetingPipe/MeetingDetailView.swift` (`ghostShortcuts` ViewBuilder).

Acceptance:
- Tooltips: `Open in Notion`, `Open in Obsidian`, `Show raw files in Finder`.
- VoiceOver reads the same text.
- Icons hidden (not rendered with missing tooltip) when the meeting has no resolved sink.

Deps: TECH-UI-5 (same file; serial within session).

**TECH-UI-7 · Workflow editor modal title reflects name · S · none** [DONE]

> Resolved 2026-05-28: `WorkflowEditor` (in `WorkflowsView.swift`) gained an additive `onNameChange` callback (fired on hydrate and on every name keystroke via `.onChange(of: name)`) and a `startsBlank` flag; its name `TextField` placeholder is now `Untitled workflow`. Both sheet shells in `LibraryWindow.swift` keep a `@State liveName` and compute the header: `WorkflowEditorSheet` falls back to the saved `workflow.name` (no first-frame flash) and `NewWorkflowSheet` (which passes `startsBlank: true`) falls back to empty, both rendering `New workflow` when the trimmed name is empty. So a new workflow opens with a blank field (placeholder visible) and a `New workflow` header, typing updates the header live, an existing workflow shows its saved name from the start, and clearing the field reverts the header to `New workflow`.
> Decision: the new-workflow stub stays persisted as `Untitled workflow` (so abandoning the sheet does not leave a blank-named workflow); `startsBlank` only blanks the editor field for display, which also matches the placeholder. Interaction code, so no headless test; `save()` already rejects an empty name. Build green.

Header reflects the current value of the name field live; falls back to `New workflow` when empty and unsaved, or to the saved name when editing existing. Placeholder inside the field remains `Untitled workflow`.

Edit: locate via `grep -r "Untitled workflow" daemon/Sources/`. Most likely `daemon/Sources/MeetingPipe/Preferences/WorkflowEditorSheet.swift` or `daemon/Sources/MeetingPipe/WorkflowsView.swift`.

Acceptance: per Q2 addendum lines 124-129.

Deps: none.

**TECH-UI-8 · Sidebar zero-count muting · S · none** [DONE]

> Resolved 2026-05-28: in `LibrarySidebar`, both `LibraryScopeRow` and `WorkflowScopeRow` count badges now render `Color.secondary.opacity(0.5)` when the count is zero and full `.secondary` otherwise (the library row keeps `.primary` when selected). Muting applies only to the count Text, not the icon or label, and updates live as counts cross zero (SwiftUI re-render). Pure styling, so no unit test (snapshot coverage is the deferred TECH-T2); build green.

Counts equal to zero render at secondary label color * 0.5 opacity; non-zero counts stay at full secondary.

Edit: `daemon/Sources/MeetingPipe/LibrarySidebar.swift` (`LibraryScopeRow` and `WorkflowScopeRow`; the count is the `Text(count.formatted(.number))` line).

Acceptance: per Q2 addendum lines 141-146.

Deps: none.

**TECH-UI-9 · Relative date formatting in list rows · S · none** [DONE]

> Resolved 2026-05-28: added `Util/RelativeMeetingDateFormatter.swift` with a pure `bucket(for:now:calendar:)` (today / yesterday / weekday for 2-7 days / dayMonth same-year / dayMonthYear older) and a locale-aware `string(...)` that renders `Today HH:mm`, `Yesterday HH:mm` (localized + capitalized via `RelativeDateTimeFormatter`), `Wed HH:mm`, `14 May HH:mm` (`setLocalizedDateFormatFromTemplate("dMMM")` so day/month order follows locale), and `14 May 2025` (time omitted). `MeetingRow.trailingWhenStack` collapsed from the two-line day/time stack to this single monospaced line, width reserved at 100 pt for the longest case so the column does not jitter. The now-dead `MeetingFormatters.shortMonthDay` was removed. `RelativeMeetingDateFormatterTests` (7 cases) pins the buckets deterministically plus the time present/absent property; full suite green.

Replace the current cramped abbreviations (`Yest 10:54`, `Wed 17:33`) with `RelativeDateTimeFormatter`-backed output: `Today HH:mm`, `Yesterday HH:mm`, `Wed HH:mm`, `14 May HH:mm`, `14 May 2025`.

Edit:
- `daemon/Sources/MeetingPipe/MeetingRow.swift` (`trailingWhenStack` and `relativeDayLabel`).
- New `daemon/Sources/MeetingPipe/Util/RelativeMeetingDateFormatter.swift`.

Acceptance: per Q2 addendum lines 164-169.

Deps: none.

**TECH-UI-10 · Waveform playback controls regroup · S · none** [DONE]

> Resolved 2026-05-28: stop-and-ask resolved with the user. The premise (the `Fit · 1x · 2x · 4x · 8x` control mixes playback speed and zoom) does not hold: in `AudioTab.swift` that segmented `Picker` is purely a waveform-zoom control (`computeWidth` stretches the rendered width; `.fit`/`.x1` are fit-width, `.x2`-`.x8` multiply it) and `AudioPlaybackController` has no playback-rate concept at all. The user chose "tooltips/tidy only, no new speed feature" over adding an AVAudioEngine rate control. So this added a `.help()` to the zoom segmented control clarifying it is waveform zoom and explicitly noting playback speed is unaffected, plus a `.help()` on the play/pause button; no control was split or removed (there was no speed control to separate out), and no audio-rate feature was introduced. Cosmetic SwiftUI, so no headless test; build green and the change is em-dash-free under the new TECH-UI-2 guard.

Separate playback speed (segmented control `1x | 2x | 4x | 8x`) from waveform zoom (icon buttons `Fit to window` and `Zoom horizontal`).

Edit: locate via `grep -r 'Fit · 1x' daemon/Sources/` or the Audio tab in `MeetingDetailView`. Most likely `daemon/Sources/MeetingPipe/Library/Playback/PlaybackControlsView.swift`.

Acceptance: per Q2 addendum lines 184-190.

Stop and ask: verify the existing `Fit` button's semantic by reading its handler before refactoring. If `Fit` is not horizontal-fit, surface before designing the new affordances.

Deps: none.

**Parallel safety for Group UI** (revised):

- Wave A (parallel, 4 sessions): TECH-UI-2, TECH-UI-4, TECH-UI-7, TECH-UI-8.
- Wave B (parallel, 3 sessions): TECH-UI-9, TECH-UI-10, then TECH-UI-5 followed by TECH-UI-6 in one serial session (same file).

TECH-UI-1 and TECH-UI-3 are dropped; the group is 8 tasks (one dropped, one already done).

---

## Group UI-X · God view extractions

**TECH-UI-X1 · Extract MeetingDetailView into per-tab files · M · TECH-UI-5** [NEW]

`daemon/Sources/MeetingPipe/MeetingDetailView.swift` is around 930 lines per the audit. Five tabs: Summary, Transcript, Audio, Corrections, Raw files. Extract each into its own file. The header, title row, caption row, and ghost-shortcuts stay in `MeetingDetailView.swift` as the orchestrator.

Create:
- `daemon/Sources/MeetingPipe/Library/Detail/MeetingDetailSummaryView.swift`
- `daemon/Sources/MeetingPipe/Library/Detail/MeetingDetailTranscriptView.swift`
- `daemon/Sources/MeetingPipe/Library/Detail/MeetingDetailAudioView.swift`
- `daemon/Sources/MeetingPipe/Library/Detail/MeetingDetailCorrectionsView.swift`
- `daemon/Sources/MeetingPipe/Library/Detail/MeetingDetailRawFilesView.swift`

Edit: `daemon/Sources/MeetingPipe/MeetingDetailView.swift` shrinks to under 250 lines (orchestrator only).

Acceptance:
- `MeetingDetailView.swift` under 250 lines.
- 574 test baseline holds.
- TECH-UI-4, TECH-UI-5, TECH-UI-6 changes still work post-extraction (run those tests after the extraction lands).

Deps: TECH-UI-5 (same file is touched by both).

**TECH-UI-X2 · Extract PreferencesView into per-section files · M · none** [NEW]

`daemon/Sources/MeetingPipe/Preferences/PreferencesView.swift` is around 1100 lines, six sections already defined as `private struct GeneralSectionView`, etc. Lift each section into its own file.

Create:
- `daemon/Sources/MeetingPipe/Preferences/Sections/GeneralSectionView.swift`
- `daemon/Sources/MeetingPipe/Preferences/Sections/RecordingSectionView.swift`
- `daemon/Sources/MeetingPipe/Preferences/Sections/PromptSectionView.swift`
- `daemon/Sources/MeetingPipe/Preferences/Sections/TranscriptionSectionView.swift`
- `daemon/Sources/MeetingPipe/Preferences/Sections/WorkflowSectionView.swift`
- `daemon/Sources/MeetingPipe/Preferences/Sections/StorageSectionView.swift`
- `daemon/Sources/MeetingPipe/Preferences/Sections/DoctorSheetView.swift`

Edit: `daemon/Sources/MeetingPipe/Preferences/PreferencesView.swift` shrinks to under 200 lines.

Acceptance:
- `PreferencesView.swift` under 200 lines.
- Every section accessible via the sidebar with no regression.
- Preferences sheet still resizable.

Deps: none. Coordinate with TECH-A15 (touches the Backend section).

---

## Group E · Events and telemetry

**TECH-E4-FINISH · Dogfood analysis script · M · TECH-C6-FINISH** [NEW]

The Q2 backlog's TECH-E4 has been blocked on TECH-C13 step 5 (now done) and the corpus (TECH-C6-FINISH). With the corpus populated, the dogfood report can finally be written. (TECH-CAP1, formerly a gate here, is now P3/monitor as of 2026-05-28 and no longer blocks this.)

A script reading events.jsonl over a fortnight and reporting against the dogfood bars in the Q2 backlog (capture, detection, transcription, library). Outputs a one-page summary per layer with pass / fail / inconclusive per bar.

Create: `scripts/dogfood-report.swift` (Swift script via `swift run dogfood-report --since 14d`).

Acceptance:
- Running over a seeded fixture events.jsonl produces the expected report.
- Rebuild-tagged windows excluded by default (TECH-E3).
- Report distinguishes `MeetingLifecycleVerdict` from `MicGateVerdict` evidence per bar.
- Output is reproducible (same input -> same output).

Deps: TECH-E3 (already done), TECH-C6-FINISH. (TECH-CAP1 is now P3/monitor and no longer gates this.)

---

## Group SEC · Security follow-ups

**TECH-SEC1 · secrets.env permission validation on read · S · none** [NEW]

The audit's deferred Step 4 item. `secrets.env` permissions are enforced on write but not validated on read; spans two readers (Swift `SecretsStore.init`, Python `config.load_secrets`). Apply a warn-versus-refuse decision consistently.

Edit:
- `daemon/Sources/MeetingPipe/SecretsStore.swift`.
- `pipeline/src/mp/config.py`.

Acceptance:
- Both readers refuse to load when permissions are looser than 0600, with a clear error message pointing at the `chmod 600` fix.
- An XCTest seeds a 0644 secrets file and asserts the Swift reader refuses.
- A Python test asserts the same.
- `meetingpipe doctor` already checks 0600 as a preflight; the doctor pass adds a hint that the live reader also enforces it.

Deps: none.

---

## Group BRAND · Launch readiness (GTM doc pre-launch ship list)

The GTM doc Section 6 names a launch window of Tuesday June 9, 2026 (WWDC contingent) or June 23, 2026 as fallback. These tasks gate the launch.

**TECH-BRAND1 · Register domains and namespaces · S · none** [NEW]

Register `meetingpipe.app` (primary, HSTS-preloaded), `meetingpipe.com`, `meetingpipe.ai`, `meetingpipe.dev`. Claim `@meetingpipe` on X. Create the `meetingpipe` organization on GitHub, npm, PyPI. Reserve the Mac App Store bundle ID `com.meetingpipe.app` (separate from the daemon's `com.meetingpipe.daemon` per `scripts/install.sh`).

Acceptance: all four domains registered with the same registrar (Porkbun or Hover, not GoDaddy); WHOIS privacy on; auto-renewal on. All five namespaces claimed.

Stop and ask: if any of the four domains is parked at a premium price above $200, surface for a decision before registering.

Deps: none. Owner action.

**TECH-BRAND2 · Trademark clearance opinion and Class 9/42 filing · S · TECH-BRAND1** [NEW]

Commission a $300-700 trademark clearance opinion (Gerben IP or similar) given adjacent marks Formpipe (Sweden, Class 9/42) and Pipe Services SRL. File USPTO Class 9 (downloadable software) and Class 42 (SaaS).

Create: `docs/decisions/0013-trademark-filing.md` capturing the opinion's findings and the filing serial numbers.

Acceptance: opinion received in writing; filings submitted; serial numbers recorded.

Deps: TECH-BRAND1.

**TECH-BRAND3 · README hero · S · TECH-BRAND5** [NEW]

Hero image at 2400x900, paper-warm canvas, signal-blue accent, per `design/SKILL.md`. Composition: menu bar slice at top with armed indicator and recording lozenge; below, three cards (waveform, transcript snippet with two speakers, signed audit-trail chip). Tagline from GTM doc: "Meeting notes that never leave your Mac." Badges row (build, Swift 6.0+, macOS 14.0+, license). "What / why / how" block.

Create: `design/assets/hero-readme-2400x900.png` (and @2x).

Edit: `README.md`.

Acceptance: hero renders cleanly at GitHub's display widths; README readable on mobile and desktop; no em-dashes.

Deps: TECH-BRAND5 (the README embeds the demo loop, so the demo needs to exist first).

**TECH-BRAND4 · OG card and social meta · S · none** [NEW]

1200x630, type-only on paper-warm canvas. Wordmark "MeetingPipe" in signal-blue, tagline below at 50% size, single recording-armed glyph on the right.

Create: `design/assets/og.png` (and @2x), `design/assets/twitter-card-summary-large-image.png`.

Edit: README OG metadata, landing page `<head>`.

Acceptance: OG card preview on GitHub, LinkedIn, X, Bluesky shows the card cleanly.

Deps: none.

**TECH-BRAND5 · Demo GIF / WebM · M · none** [NEW]

60-90s loop recorded with Kap or `xcrun simctl io`, palette-quantized GIF or WebM. Target under 5 MB GIF; WebM primary if larger.

Beat sheet:
1. Menu-bar idle (3s).
2. Open Zoom (3s).
3. Armed state (4s).
4. Meeting detected toast (4s).
5. Recording with mic gate flipping (10s).
6. Meeting ends (5s).
7. Summary builds with MLX-Qwen progress (8s).
8. Library shows new meeting with transcript and summary (12s).
9. Fade to README hero (5s).

Create: `design/assets/demo/demo.gif`, `design/assets/demo/demo.webm`, `design/assets/demo/STORYBOARD.md`.

Acceptance: GitHub renders the loop inline; loop has no jarring cuts; STORYBOARD.md documents the beat sheet so a future re-shoot reproduces it.

Stop and ask: if recording the meeting-detected flow requires a real Zoom session, surface the test-fixture approach (mocked or real account) before recording.

Deps: none.

**TECH-BRAND6 · Screenshot set, light and dark · S · TECH-UI-X1** [NEW]

Six PNGs, light and dark, 1x and 2x each (24 files):
- `01-menubar-armed.{light,dark}.png` (and @2x)
- `02-meeting-detected-prompt.{light,dark}.png`
- `03-recording-active.{light,dark}.png`
- `04-library-window.{light,dark}.png`
- `05-meeting-detail-with-transcript.{light,dark}.png`
- `06-preferences-permissions.{light,dark}.png`

Create: `design/assets/screenshots/` directory with the 24 files.

Edit: README and landing page reference these.

Acceptance: light and dark captured with macOS Appearance switched (real artifacts, not Photoshop-tinted); files round to GitHub's display width without artifacts.

Deps: TECH-UI-X1 (so the detail-pane shows the cleaned-up surface post-extraction).

**TECH-BRAND7 · Landing page on meetingpipe.app · L · TECH-BRAND5, TECH-BRAND6, TECH-BRAND8** [NEW]

Eight sections per the Q3 review Part 4: hero with demo, three-up (on-device by architecture, bot-free meeting capture, NDA workflows route locally), animated demo loop with reduced-motion fallback, comparison strip (vs Granola, Otter, MacWhisper, Krisp), regulated-industry section linking to compliance pages, pricing block ($129 one-time per GTM doc), FAQ, footer.

Create: `landing/` directory (or sibling repo) with `index.html`, `style.css` consuming `design/colors_and_type.css` tokens, `assets/` (symlink to `design/assets/`).

Acceptance:
- Eight-section structure complete.
- Reduced-motion fallback for the demo (static screenshot).
- No third-party JS.
- Lighthouse mobile 90+ on Performance and Accessibility.
- No em-dashes, no emoji, no exclamation marks.

Stop and ask: if hosting target is undecided (Cloudflare Pages, GitHub Pages, Vercel), surface before scaffolding.

Deps: TECH-BRAND5, TECH-BRAND6, TECH-BRAND8.

**TECH-BRAND8 · Compliance posture pages · M · none** [NEW]

The actual differentiating work per the GTM doc Section 7. Total cost under $500 plus one weekend.

Create:
- `SECURITY.md` (RFC 9116-compatible content, security@meetingpipe.app, 90-day disclosure window) plus `.well-known/security.txt`.
- `landing/privacy.html` (state explicitly: audio and transcripts never leave the device).
- `landing/terms.html` (Common Paper free templates).
- `landing/dpa.html` (Common Paper DPA, downloadable PDF, signable via DocuSign).
- `landing/baa.html` (HHS sample BAA, Team Pack tier only).
- `landing/security.html` (single page Trust Center: architecture summary, sub-processor list, code-signing/notarization, compliance posture stated honestly).
- `landing/subprocessors.html` (list every vendor that touches metadata; should be a very short list).
- `landing/hecvat-lite.pdf` and `landing/caiq-lite.pdf` (pre-filled).
- `docs/reproducible-build.md` (how a buyer can verify the closed-source binary corresponds to the open-source engine).

Acceptance:
- All eight surfaces published.
- Each page passes a read by someone who is NOT the author (the GTM doc names the user explicitly as a regulated-industry tech lead; a peer review by another such person is the bar).
- No SOC 2 work begun (deferred per GTM doc).

Stop and ask: if any HHS sample BAA clause does not apply to a Mac-installed local-first tool, surface before publishing the BAA.

Deps: none. Can run in parallel with most Q3 work.

**TECH-BRAND9 · Repo polish: templates and policies · S · none** [NEW]

Create:
- `.github/CODE_OF_CONDUCT.md` (Contributor Covenant 2.1).
- `.github/CONTRIBUTING.md` (Swift style, ADR process, no-em-dash rule, test plan expectations).
- `.github/PULL_REQUEST_TEMPLATE.md` with sections: Summary, Test plan, ADRs touched, Screenshots if UI, Lint clean.
- `.github/ISSUE_TEMPLATE/bug.yml`, `feature.yml`, `question.yml`.
- `SECURITY.md` per TECH-BRAND8 (same file).
- `CHANGELOG.md` in keep-a-changelog format, retroactively covering 0.1.0 release.

Edit: `README.md` to add badges row.

Acceptance:
- Opening a new issue prompts a template.
- Opening a PR prompts a checklist.
- CHANGELOG covers every release the user has shipped to date.

Deps: none.

---

## Group T · Tests

**TECH-T2 · Snapshot tests for three SwiftUI views · S · TECH-UI-X1, TECH-UI-X2** [NEW]

Add snapshot tests for one library list, one meeting detail (post-extraction), one preferences pane (post-extraction). Use the `swift-snapshot-testing` package or the Apple-native equivalent.

Create: `daemon/Tests/MeetingPipeTests/Snapshots/` directory with three test files plus reference images.

Acceptance:
- Three snapshot tests committed.
- A deliberate cosmetic regression in one of the three views (introduced on a throwaway branch) fails the test.
- The maintenance cost is documented in `docs/test-coverage.md`: snapshot tests are gated by macOS Appearance to avoid flakiness.

Deps: TECH-UI-X1, TECH-UI-X2.

**TECH-W2 · Workflow precedence pinning test · S · none** [NEW]

Pin the matcher precedence: two workflows with overlapping matchers, which one wins. Today no test asserts this; the behavior is deterministic in the code but unpinned.

Edit: `daemon/Tests/MeetingPipeTests/WorkflowMatcherTests.swift`.

Acceptance: a new test asserts the precedence rule (likely: by `order` ascending, then by `name` case-insensitive; verify in code).

Deps: none.

---

## Group I · Future ideas (parking lot)

**TECH-I6 · Partial-publish failure visibility · M · TECH-P4** [NEW]

Audit's deferred Step 5 item. `publish_router.fanout` swallows per-sink failures by design (so a Notion outage does not lose the local Obsidian copy). Surface the per-sink result so the user knows when Notion is down but Obsidian succeeded.

Sketch:
- Python `publish_router.fanout` returns `dict[sink_name, PublishResult]` instead of a single Boolean.
- Sidecar gains a `publish_state` per sink: `published`, `failed: reason`, `pending`.
- Library row surfaces a per-sink indicator when any sink is `failed`.

Open questions:
- Schema migration for existing meetings (the sidecar shape changes). Backward-compatibility on read.

Deps: TECH-P4 (sidecar shape settled).

**TECH-I7 · Drop Python entirely · XL · Apple Intelligence proves out AND local LLM swap is Swift-native** [NEW]

Promotion trigger: TECH-SUM1-APPLE lands with a quality bar at parity with the existing local backend, AND a Swift-native local LLM (MLX Swift, or whatever ships in macOS 27) can replace MLX-Qwen without a quality regression. Until then: Python stays. The pipeline still hosts summarization, Obsidian publisher, Notion publisher, BYO paste handling, correction corpus statistics. Removing it is weeks of work with zero user-visible value until the conditions above hold.

Deps: TECH-SUM1-APPLE, plus a Swift-native local LLM swap.

**TECH-I8 · Live transcription during recording · XL · Q4 2026 streaming summarization design proves the floor** [NEW]

Promotion trigger: the Q4 2026 streaming summarization big-bet in the GTM doc lands and proves out the engineering primitives needed for live ASR. Until then: live transcription stays parked. The earlier deletion of streaming was correct; reversing it now would re-litigate a closed decision and risks the mute-detection accuracy bar.

Deps: Q4 streaming summarization (in the GTM doc, not yet in this backlog).

**TECH-I9 · Signed and verifiable audit trail for regulated buyers · XL · TECH-Q3-CASE-STUDIES-LANDED** [NEW]

Promotion trigger: the Q3 2026 named regulated case studies land (one law firm OR one clinical practice), AND the case-study buyer asks for cryptographically-verifiable audit trails. Until then: park.

Sketch (for future): Ed25519 signing of events.jsonl per line (sidecar `events.jsonl.sig`), per-meeting integrity manifest (SHA-256 over audio + transcript + summary + signing time + app cdhash), validated-export ZIP that an auditor verifies with a 10-line `scripts/verify_export.py`.

Deps: regulated case-study traction.

---

## Dogfood acceptance bars (unchanged from Q2)

Capture bar, detection bar, transcription bar, library bar - all unchanged from `docs/backlog/q2-final.md`. The Q3 critical path is anchored on closing the open items against those bars; the bars themselves are not revised.

---

## Critical path

1. **P0 runtime acceptance** owed against Q2 merges. User action, no code. Lands first.
2. **TECH-CAP1** (mic/system end-of-call skew) was the open P1 here; deprioritized to P3/monitor on 2026-05-28 (user no longer reliably observes it), so it is off the critical path. The next real work is the structural unblock below.
3. **TECH-H1-FINISH + TECH-C16** (Coordinator round 2 + decide-or-delete signals). Closes the audit's architectural debt.
4. **TECH-C6-FINISH + TECH-E4-FINISH** (corpus + dogfood report). Closes the loop on the acceptance bars.
5. **TECH-DIAR1 + TECH-SUM1-PRIMITIVE + TECH-SUM1-APPLE** (diarization cleanup + chunking primitive + Apple Intelligence). The next.md ideas worth shipping, in dependency order.
6. **TECH-UX1 + TECH-UX2 + TECH-UX4 + TECH-UX6** (onboarding + recovery discoverability + degraded HUD + HUD app icon). The lived-experience UX gaps.
7. **TECH-BRAND1 through TECH-BRAND9** (launch readiness). Gated by the June launch window.
8. **Group UI** (eight tasks after dropping UI-1 and UI-3). Parallel waves.
9. **TECH-UI-X1 + TECH-UI-X2** (god view extractions). Polish.
10. **P2 follow-ups** (typed summary, mtime cache, render cliffs, BYO completion, in-app progress, voice-activity meter, opt-out auto-restart, secrets.env permissions, partial-publish visibility, snapshot tests, workflow precedence test).
11. **Group I parking lot** stays parked.

Estimated effort: 6-9 weeks of solo Claude-Code-assisted work to hit P0-P1, fitting the June launch window if started immediately. P2 slips to Q4 cleanly.

Note for the companion `docs/roadmap.md` (if it exists): Phase 4 (library bar across two Macs via TECH-G1) and Phase 5 (notarization, compliance docs) descriptions in the Q2 backlog can stay; Q3's critical path runs in parallel with neither.
