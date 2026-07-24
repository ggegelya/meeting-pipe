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

Worth knowing: the three `LocalSummaryClient` constructions **have already drifted**, and the drift was left in place because closing it is a behaviour change, not a refactor. `summarize` passes `summary_language`, `map_reduce_above_chars`, and LOCAL9's `adapter_path`; `engine._local_client` passes none of the three; `diarize_cleanup` additionally skips both timeout knobs, so `local_startup_timeout_sec` / `local_request_timeout_sec` silently do not apply to the cleanup pass. Each difference is arguably deliberate (a summarization-tuned LoRA on an ask/digest turn is questionable) but none is documented as such. **Deciding whether ask/digest/cleanup should honour those knobs is a behaviour question that wants its own task.**

### One intended copy change

The two single-meeting Trash confirmations disagreed: `MeetingDetailView+Header` said the files "goes to the Trash", `MeetingRow` said "will go to the Trash". Converged on "goes to", which matches the batch pane and is the majority spelling. This is the only user-visible string that changed.

## Remaining, still promote-on-touch

Both remaining legs move behaviour-carrying code on the summarize path, which is what the spec's "do not refactor speculatively" rule protects. They stay unshipped until a task actually touches the file:

- **`PipelineLauncher.swift`** (1015 lines): the embedded in-Swift Apple-Intelligence summarization flow (`summarizePreviewViaApple` / `completeViaAppleIntelligence` / `writeAppleRunSidecar` / `appleContext`, ~120 lines) wants to move beside `AppleIntelligenceSummarizer`, and the 17-method `PipelineDriver` protocol carries ~180 lines of NSError stub defaults that a typed command enum would collapse.
- **`summarize_local.LocalSummaryClient`** (981 lines): extract an `MLXServerSupervisor` from the server-supervision half. **Unblocked**: the spec said to sequence this against LOCAL12 because a Swift port would delete the file, and LOCAL12 returned NO-GO (keep the embedded-Python runtime), so the file is the end state.
