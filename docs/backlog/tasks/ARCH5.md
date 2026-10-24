# ARCH5: Refactoring band

Band origin: assessment review 2026-07-12. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

**ARCH5 (P3): refactoring band, promote when touching the files.** The unfiled structural debt the principles pass named, for green-to-green extraction whenever a task next touches these files (do not refactor speculatively): `MeetingRecorder.swift` (the repo's largest file: extract a RecordingPostProcessor for the ffmpeg merge / plausibility / recordfail / orphan-recovery half; `stop()` spans ~211 lines); `PipelineLauncher.swift` (hosts the whole in-Swift Apple-Intelligence summarization flow plus a 17-method driver protocol with NSError stub defaults; extract the engine beside AppleIntelligenceSummarizer and consider a typed command enum); `summarize_local.LocalSummaryClient` (~590 lines mixing server supervision, HTTP client, retry policy, and map-reduce; extract an MLXServerSupervisor, but sequence against LOCAL12 since a port deletes the file); and the small duplication list: `_parse_summary` byte-identical across both PROV1 providers, the six-way backend dispatch duplicated between `summarize._select_backend` and `engine.complete_text`, LibraryWindowModel's ~11 identical continuation bridges, the tri-plicated delete/export dialog copy (already drifted), and daemon config defaults written three to four times. Suites green after each extraction; no behavior change.

## Shipped 2026-07-24 (owner-promoted, mechanical half only)

The owner invoked `/tech-task ARCH5` and chose the mechanical subset. Everything below landed in one commit with both suites green (1641 Swift, 982 Python, ruff + pyright + CI5 fences clean).

- **`RecordingPostProcessor` extracted** from `MeetingRecorder.swift` (1899 to 1594 lines). Every member moved was already `static` and touched only files on disk, so the split is a move, not a rewrite: `recoverOrphan`, `produceFinal`, `promoteMerged`, `mergeToTempViaFFmpeg`, `convertToTempViaFFmpeg`, `runFFmpeg`, `writePostProcessFailure`, `recordFailURL`, `mergingTempURL`, `producedPlausibleOutput`, `fileSize`, `findFFmpeg`, `audioDurationSec`, plus the `mergeCeilingSeconds` ceiling. Call sites repointed in `OrphanRecordingRecovery`, `MuteRedactor`, `AudioTranscoder`, and four test files. `checkDurationParity` stayed on the recorder (it is an instance method that logs).
- **`json_extract.parse_summary`** promoted out of both PROV1 providers, which each carried a private copy.
- **`ConfigDefaults`** now holds the 14 daemon defaults that `Config.load`, `Config.defaultFallback`, and `ConfigStore.init` each used to spell.
- **`LibraryDialogs`** now holds the Trash-confirm and export-folder dialogs the three call sites duplicated.
- **`LibraryWindowModel.bridge`**, one generic continuation helper, replaced 12 hand-spelled `CheckedContinuation` wrappers.
- **`config.BackendName`** is now the single backend vocabulary; `BACKENDS` derives from it with `get_args` instead of restating the same six strings.

### Spec corrections found while implementing

The 2026-07-12 filing drifted in four places. Recorded so the next session does not re-derive them:

- `_parse_summary` was **not** byte-identical. The two copies differed in the exception each raises (`ClaudeCLIError` against `OpenAIError`) and in a docstring, which is why the shared helper takes `error` and `message` rather than raising one type.
- `summarize_local.LocalSummaryClient` is **981 lines**, not ~590; it grew ~400 lines since the filing.
- The six-way dispatch is **tri**-plicated, not duplicated: `diarize_cleanup._select_cleanup_backend` is a third site.
- LibraryWindowModel had **12** continuation bridges, not ~11.

### The six-way dispatch, deliberately not merged

Only the backend *vocabulary* was single-sourced. The three dispatch bodies were left alone on purpose: they legitimately differ (`summarize` returns a `SummaryClient` factory, `engine` performs the call and returns an `EngineResult`, `diarize_cleanup` wraps a `LocalCleanupClient`), and the shared machinery they do have (`effective_backend`, `parse_local_endpoint`, `run_with_local_fallback`) was already extracted by PIPE7. Merging the bodies would mean a speculative abstraction over three things that are not the same thing.

Worth knowing: the `LocalSummaryClient` constructions **have already drifted**, and the drift was left in place because closing it is a behaviour change, not a refactor. `summarize._select_backend` passes `summary_language`, `map_reduce_above_chars`, and LOCAL9's `adapter_path`; `engine._local_client` passes none of the three; `diarize_cleanup` additionally skips both timeout knobs, so `local_startup_timeout_sec` / `local_request_timeout_sec` silently do not apply to the cleanup pass. Each difference is arguably deliberate (a summarization-tuned LoRA on an ask/digest turn is questionable) but none is documented as such. **Deciding whether ask/digest/cleanup should honour those knobs is a behaviour question that wants its own task.**

**Correction (LOCAL19, 2026-08-15): there are four constructions in the backend dispatch, not three.** This paragraph read the three dispatch bodies and missed `summarize._AutoFallbackClient._local`, the `auto` backend's local rung, which is a fourth site with its own argument list. That omission mattered: it was the only one not passing `memory_floor_pct`, so the whole `auto` backend ran the free-RAM watchdog at `resource_guard.DEFAULT_FLOOR_PCT` regardless of `summarization.local_memory_floor_pct`. LOCAL19 closed the floor half of the drift at every site, `dogfood`'s three included, and added `test_local_client_contract.py` so a fifth construction that forgets the floor is a red build. The rest of the drift this paragraph names (language, map-reduce, adapter, timeouts) is untouched and still wants its own task.

### One intended copy change

The two single-meeting Trash confirmations disagreed: `MeetingDetailView+Header` said the files "goes to the Trash", `MeetingRow` said "will go to the Trash". Converged on "goes to", which matches the batch pane and is the majority spelling. This is the only user-visible string that changed.

## Remaining, still promote-on-touch

Both remaining legs move behaviour-carrying code on the summarize path, which is what the spec's "do not refactor speculatively" rule protects. They stay unshipped until a task actually touches the file:

- **`PipelineLauncher.swift`** (1015 lines): the embedded in-Swift Apple-Intelligence summarization flow (`summarizePreviewViaApple` / `completeViaAppleIntelligence` / `writeAppleRunSidecar` / `appleContext`, ~120 lines) wants to move beside `AppleIntelligenceSummarizer`, and the 17-method `PipelineDriver` protocol carries ~180 lines of NSError stub defaults that a typed command enum would collapse.
- **`summarize_local.LocalSummaryClient`** (981 lines): extract an `MLXServerSupervisor` from the server-supervision half. **Unblocked**: the spec said to sequence this against LOCAL12 because a Swift port would delete the file, and LOCAL12 returned NO-GO (keep the embedded-Python runtime), so the file is the end state.

## Amended 2026-10-24 (audit band)

Three findings from the 2026-10-24 audit band land on this task's two remaining legs rather than becoming new tasks: [architecture review](../../audits/2026-10-24-architecture-review.md) A7 and B4, and [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) SA-14 (go-live SA-12 already pointed here for the driver leg). Re-measured against `main` on 2026-10-24. The band stays P3, promote-on-touch; what changed is that both legs grew while parked, and the view leg is new.

### The driver leg has grown

- `PipelineLauncher.swift` is 1,483 lines, against the 1,015 the "Remaining" list above recorded.
- `protocol PipelineDriver` now has 24 requirements (it was 17), and the `extension PipelineDriver` defaults return an `NSError` from 16 of them. There is one production conformer (`final class PipelineLauncher: PipelineDriver`) and four test fakes (`RestoreFlowTests`, `MeetingLibraryServiceTests`, `PipelineJobDispatcherTests`, `SinkDispatcherTests`). Because the defaults exist, a signature change on `PipelineLauncher` that stops matching a requirement compiles, and the call silently reaches the `NSError` default at runtime.
- Five views build their own launcher outside the shared one and the job lane: `@State private var launcher = PipelineLauncher()` in `TranscriptTab`, `PeopleView`, `PreferencesView+Pipeline` and `PreferencesView+Storage`, plus `RestoreFlow(launcher: PipelineLauncher())` in `PreferencesView+Storage`.

When this leg is promoted, the shape is: split `PipelineDriver` by caller into three or four role protocols (run lane, library operations, Ask and digest, roster and backup), remove the defaults on the run-lane protocol so drift is a compile error, and inject the one `Coordinator`-owned launcher through the SwiftUI environment instead of the five local constructions. The typed command enum named above remains an option for the run lane only. ARCH12 removes the Library's concrete `Coordinator` reference and does not touch these views' launchers; ARCH11 may move the Apple Intelligence flow out of `PipelineLauncher` entirely, so promote this leg after ARCH11's ADR, not before.

### New leg: oversized views

- `PipelineSectionView` (`Preferences/PreferencesView+Pipeline.swift`): `var body` is about 261 lines.
- `TranscriptTab.swift`: 494 lines on 2026-06-29, 1,573 on 2026-10-24, one `TranscriptTab: View` plus 12 computed `some View` properties.
- `MeetingPromptWindow.makeContentView`: about 216 lines of hand-placed AppKit constraints, in a 1,378-line file.
- Go-live SA-14: `MeetingDetailView+Header.swift` is `extension MeetingDetailView` with 15 computed `some View` properties, and `MeetingDetailView.swift` has 9 more, its `body` included. Computed properties on the same struct are evaluated inside the parent's `body`, so a change to any of `MeetingDetailView`'s 13 `@State` / `@StateObject` / `@ObservedObject` properties re-evaluates the header too. Splitting by extension organises the source without creating an invalidation boundary; a separate `View` struct with only the inputs it reads is the boundary.

Rule for this leg, the same promote-on-touch rule as the rest of the band: when a task edits one of these files for another reason, extract the part it touches into its own `View` struct with explicit inputs, green to green, and no sweep. Start with Preferences, one section per backend, if a task touches `PipelineSectionView`. [PERF12](./PERF12.md) owns the 15 Hz playback re-render specifically and should land its `PlaybackClock` split first; [UX27](./UX27.md) owns the prompt's keyboard operability, which a `makeContentView` extraction should not change.

Acceptance for whichever session promotes a piece: `swift test` green, no behaviour or copy change, the extracted view named in ARCHITECTURE.md's file index in the same commit, and for the SA-14 case a test or `Self._printChanges()` note in the commit body showing the extracted header no longer re-evaluates on an unrelated state change.
