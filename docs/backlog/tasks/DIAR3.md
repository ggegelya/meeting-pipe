# DIAR3: Speaker-accuracy controls in Preferences (separation threshold + cleanup pass)

Band origin: filed 2026-07-29 (owner exploratory sweep, item 10: "Anisha was defined as sudip for some reason... perhaps we can have a switch/slider/smart system that will allow fine tune it from inside of the settings"; converged with the item 16 invisible-capability sweep, which independently ranked both of these knobs among the top UI gaps). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

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

Owner eyeball: set More distinct, confirm `config.toml` reads 0.55, Re-transcribe the 2026-07-27 meeting where Anisha was labeled as Sudip, and check whether the voices split (the result feeds DIAR2's calibration either way).
