# DIAR3: Speaker-accuracy controls in Preferences (separation threshold + cleanup pass)

Band origin: filed 2026-07-29 (owner exploratory sweep, item 10: "Anisha was defined as sudip for some reason... perhaps we can have a switch/slider/smart system that will allow fine tune it from inside of the settings"; converged with the item 16 invisible-capability sweep, which independently ranked both of these knobs among the top UI gaps). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Progress (2026-07-31, shipped; owner-owed eyeball)

Both rows ship in **Preferences ▸ Pipeline ▸ Speaker labels**, placed after Languages so they sit beside the transcription-language row (the other knob read at the same moment for the same recording). Both suites green: **1980 Swift, 1157 Python**; ruff, pyright, and `truth_fences.py both` clean.

**The blocker clause clears.** Scope item 2 asked whether the cleanup path really routes through the seam the egress clamp lives on, and it does, by both halves of the AI/DV standing rule:

1. `diarize_cleanup.cleanup_transcript` calls `entry.prepare(cfg, transcript_json)` as its first statement, which resolves the per-meeting workflow overlay (the thing that sets `workflow_nda_mode`), then arms the egress guard on the resolved config, then loads secrets, in that order, before any client is constructed.
2. `_select_cleanup_backend` resolves through `config.effective_backend(cfg)`, the single TECH-ARCH1 chokepoint that returns `local` whenever `zero_egress(cfg)` holds and the configured backend is not already local. `effective_backend`'s own docstring names this call site as one of the three it replaced. `auto` cannot slip past it: the clamp runs before the key-presence branch. `apple_intelligence` collapses to local here too, because the pass runs in Python and the Foundation Model is Swift-only. `test_diarize_cleanup.py::test_regulated_mode_forces_local` pins it.

What is *not* true, and was worth checking rather than assuming: this is not literally `engine.complete_text`. ARCH5 recorded `_select_cleanup_backend` as the third of three deliberately separate dispatch bodies (they return different things), while the shared machinery they do have (`effective_backend`, `parse_local_endpoint`) is extracted. So the clamp is honoured through the shared policy layer rather than a shared call path, which is what the rule actually requires. No change was needed and nothing was papered over.

**Two spec corrections, both found by reading the source before writing copy.** The spec's proposed sublabel ("Applies to new meetings; use Re-transcribe on an existing one") is wrong on both clauses, in opposite directions, and shipping it would have taught the owner two false things about their own app:

- **The threshold applies on the next daemon *launch*, not the next recording.** `Coordinator.init` reads `config.transcription.diarizationClusteringThreshold` once and bakes it into the `TranscriptionRunner` it hands `SinkDispatcher` (a `private let`), and `ConfigRefreshCoordinator` only refreshes the model prefetch and the regulated glyph on a config save. So it behaves exactly like `transcription.language`, whose row already says "Applies on the next daemon launch", and exactly like DIAR2's own owner walkthrough, which tells the owner to quit and let launchd relaunch. `README.md` and `config.example.toml` both claimed "applies on the next recording, no rebuild"; both are corrected here. Re-transcribe *is* an apply step for this knob, but only after the relaunch, since it runs on the same baked runner. Making it genuinely live was considered and rejected as out of scope: the runner is a `let` on a `@unchecked Sendable` type with GCD threading, so a live swap is a concurrency change in the transcription hot path, not a copy fix.
- **Re-transcribe is *not* an apply step for the cleanup toggle.** `mp finalize` (the tail of ASR3's re-transcribe ratchet) does not run the pass, and Re-summarize only re-runs the summary over the transcript already on disk; only `run-all` runs it. So the honest sentence is that the toggle applies to meetings recorded from then on, with `mp cleanup-diarization <stem>.json` as the on-demand path for an existing one. The row says that.

**Decisions the spec delegated, recorded:**

- **Segmented control over a slider**, as the spec preferred, and the reasoning lives in `SpeakerAccuracy.swift` next to the table rather than only here: the range is narrow, the effect is coarse, and a bare number explains nothing, while a slider would imply a precision the knob does not have and invite fine-tuning a value whose only honest calibration is DIAR2's DER sweep.
- **Custom is a readout, not a target.** `SpeakerSeparation.options(forValue:)` appends it only when the stored value is already a non-preset one, and `value(forID:)` returns nil for it, so the setter's guard cannot swallow a selection a user could actually make. That is the shape "minus its UX43 setter bug" has to take for a segmented control: UX43's defect is an option that is always offered and always does nothing, so the fix here is to not offer it rather than to make it do something. Its label carries the number (`Custom (0.60)`) because a segmented control has no second field to reveal it in, unlike the local-model picker's model-id row.
- **The store clamps on read**, through the same `SpeakerSeparation.clamp` `Config.load` now calls (replacing two inline literals). Without it a hand-edited `0.2` would render as some position while the running daemon used `0.5`. The clamp bounds and the 0.65 default are unchanged; both stay DIAR2's.
- **`ConfigDefaults` gets the threshold, not the cleanup flag.** The threshold now has three readers (`Config.load`, `Config.defaultFallback`, `ConfigStore.init`) plus `FluidAudioRunner.defaultClusteringThreshold`, which is now an alias so there is one literal, so it is exactly what ARCH5's rule is for. `diarize_cleanup` has one Swift reader, and `ConfigDefaults`'s own docstring carves single-reader knobs out ("moving them here would only add a lookup"), so its `false` stays at the `ConfigStore` call site beside the other summarization keys.
- **The cleanup sublabel is backend-keyed and pure** (`DiarizeCleanup.sublabel(backendID:)`), reading `SummarizationEngine.Locality` rather than re-deriving cloud-vs-local (UX31's rule). The regulated/NDA clause is stated only for a backend the clamp would actually move; under `local` it would be noise implying a cloud call the user never configured, and under `apple_intelligence` the true sentence is a different one (the pass runs on local MLX). An unknown backend id gets the cost sentence alone, never an invented locality.

**Files:** `daemon/Sources/MeetingPipe/SpeakerAccuracy.swift` (new: `SpeakerSeparation` + `DiarizeCleanup`), `ConfigDefaults.swift`, `ConfigStore.swift`, `Config.swift`, `Transcription/FluidAudioRunner.swift`, `Preferences/PreferencesView+Pipeline.swift`, `Tests/MeetingPipeTests/SpeakerAccuracyTests.swift` (new, 13 cases), `Tests/MeetingPipeTests/ConfigStoreTests.swift` (+5). Docs: `README.md` (the threshold bullet's apply step, a new `summarization.diarize_cleanup` bullet, the speaker-labels troubleshooting entry), `config.example.toml` (both key blocks), `ARCHITECTURE.md`, `daemon/CLAUDE.md`, `design/ui_kits/macos_app/PreferencesWindow.jsx`. No Python change, as the spec predicted.

**Owner-owed:** the eyeball below. Its result feeds DIAR2's calibration either way, which is the point of running it.

## Context

The misattribution class the owner reported (two very different voices sharing one label) is DIAR2 leg (a), and its calibration is DIAR2's still-owner-owed DER sweep (`scripts/valid1_check.py --der`, the MERGED CLUSTERS line). This task does not re-litigate the default or the calibration; it gives the two existing knobs the UI the de-CLI standing rule says a user-facing capability owes.

Knob 1: `transcription.diarization_clustering_threshold`. Wired end to end since DIAR2 (default 0.65, clamped to FluidAudio's 0.5-0.9; `Config.swift:103-107` reads it, threaded through `Coordinator.swift:120` to `FluidAudioRunner.swift:141`; documented in `config.example.toml`). It is absent from `ConfigStore` entirely, so Preferences cannot show it and the only way to move it is a hand-edit of `config.toml`. Lower means more distinct speakers (over-split beats naming the wrong owner); higher merges more.

Knob 2: `summarization.diarize_cleanup`. The LLM pass that merges same-speaker labels after transcription (`mp cleanup-diarization`, prompt at `pipeline/src/mp/prompts/diarize_cleanup.md`, loader `diarize_cleanup.py:275-294`). It is off by default, has no Preferences control, and its only in-app trace is a status label (`MeetingRow.swift:396`). A knob whose entire job is repairing the most visible transcript defect should not be reachable only by TOML.

The apply loop that makes tuning actionable already ships: ASR3's Re-transcribe (detail menu and batch pane) re-runs the same audio under current settings at zero engine cost, with overlay carry. The FEAT11 Vocabulary footer's "name the exact action" pattern (`VocabularyEditor.swift:74-88`) is the copy precedent.

## Scope

In Preferences, Pipeline pane (beside the transcription language row):

1. **"Speaker separation" control** over the threshold: a three-position segmented control (More distinct / Balanced / Merge more) mapped to pinned values (0.55 / 0.65 / 0.75), with a "Custom" position appearing only when the config already holds a non-preset value (the LocalModelPreset fall-through idiom, minus its UX43 setter bug). Sublabel in plain language: "If two different people keep getting one name, choose More distinct. Applies to new meetings; use Re-transcribe on an existing one." A segmented control is preferred over a raw slider: the useful range is narrow, the effect is coarse, and three named positions are explainable; record this decision.
2. **"Clean up speaker labels after transcription" toggle** wiring `summarization.diarize_cleanup`, with an honest cost sublabel (it is an extra model call per meeting; it follows the meeting's backend, so NDA/regulated meetings run it locally). Verify at pickup that the cleanup path routes through the engine seam so the egress clamp genuinely applies (the AI/DV standing rule); if it does not, that is a blocker to surface, not to paper over.
3. Both rows require `ConfigStore` to model the two keys (round-trip already preserves unknown keys; add typed bindings), honoring `ConfigDefaults` as the single default home (ARCH5 rule).

## Explicitly not in scope

Changing the 0.65 default or the clamp (DIAR2's, calibrated by the owner-owed sweep). The offline `stepRatio` lever (`OfflineDiarizerManager`-only; DIAR2 records it as a spike-sized migration). Auto-tuning from named-voice feedback (interesting, unfiled; noted as an adjacency for a future AI9-shaped counter over re-labeling events). Per-meeting threshold overrides.

## Acceptance

Daemon tests: ConfigStore round-trips both keys (typed binding writes the value, unknown keys and `[fuzzy]`-style siblings survive); the segmented mapping is pure and table-tested (position to value, non-preset value to Custom); the cleanup toggle's sublabel derivation includes the local-under-NDA clause only when truthful.

`python3 scripts/truth_fences.py config` green (both keys already documented; the fence's dead-knob direction now sees a Preferences control WITH a reader, which is the passing shape).

Both suites green (baselines at filing: 1770 Swift, 1050 Python; the pipeline side should need no change).

Owner eyeball: set More distinct, confirm `config.toml` reads 0.55, Re-transcribe the 2026-07-27 meeting where Anisha was labeled as Sudip, and check whether the voices split (the result feeds DIAR2's calibration either way). Walkthrough below; note the relaunch step, which the acceptance as filed did not have and the run needs.

## Owner walkthrough (for the session that picks this up)

Every task gated on an owner action carries one (2026-07-30 rule). Walk the owner through it step by step; the owner does not read code. Steps are tagged [owner] / [session] by who acts.

1. [session] Install the build so Preferences has the new group: `./scripts/rebuild.sh` from the repo root.
2. [owner] Open **Preferences ▸ Pipeline** and scroll to **Speaker labels**. Confirm it reads **Balanced** (that is the shipped default), then choose **More distinct**.
3. [session] Confirm the write landed: `grep diarization_clustering_threshold ~/.config/meeting-pipe/config.toml` should show `0.55`. If it still shows the old value, wait a second and re-run; the store debounces its save by 500 ms.
4. [owner] Quit MeetingPipe from the status-bar menu. launchd relaunches it. **This step is not optional and is the one the acceptance as filed missed**: the threshold is read once when the daemon starts, so a Re-transcribe before the relaunch would re-run on the old value and the whole check would report a false negative.
5. [owner] In the Library, open the 2026-07-27 meeting where Anisha was labelled as Sudip, and run **Re-transcribe…** from its `...` menu. It costs no engine call and keeps the existing summary.
6. [owner] When it finishes, read the cast strip above the transcript. The question is only whether the two voices are now separate clusters, not whether they are named correctly: an over-split shows an extra unnamed `THEM-*` chip, which is the safe direction and is fixable in-app.
7. [session] Record the outcome against DIAR2, whichever way it goes, since this is a data point in its owner-owed sweep. Split: 0.55 is a candidate value, and the next round is watching for over-splitting on normal meetings. Still merged: 0.55 is not enough for this meeting, which is evidence for the offline-diarizer spike DIAR2 names rather than for stepping lower again.
8. [owner] Second half, independent of the first: turn **Clean up speaker labels after transcription** on and leave it on for a few meetings. It only affects meetings recorded from then on, so there is nothing to re-run; judge it on whether new transcripts stop showing one person under two labels. Turn it back off if the extra per-meeting model call is not paying for itself.
9. [session] Once both halves have been judged, DIAR3 moves to done. Nothing is owed on the engineering side.
