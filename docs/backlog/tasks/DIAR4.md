# DIAR4: spike, offline-diarizer migration for the failures no threshold can reach

Band origin: filed 2026-08-04 by DIAR2's closing sweep. This is the successor DIAR2's own walkthrough step 5 pre-registered ("If no value in 0.5-0.9 works, open `/spike` for the offline-diarizer migration (the stepRatio lever) instead of forcing it"), filed on measurement rather than on suspicion. Read DIAR2's `[DONE]` entry in [`q6-final.md`](./q6-final.md) first; it carries the numbers that justify this and they are not repeated here in full.

## Why this exists

DIAR2 swept `transcription.diarization_clustering_threshold` across the owner's real corpus and settled it at 0.55, which is a large measured win: the median raw cluster count per meeting went 3 (at 0.7) to 4 (at 0.65) to 9 (at 0.55), and the over-splitting that lower thresholds risk never appeared in 14 hand-corrected meetings. What it also established is that the lever is **spent**, with two residual failures it structurally cannot reach.

**(1) Simultaneous over-split and merge in one meeting.** `20260803-103042` at 0.55 produced 9 clusters, of which three held under 5 seconds of speech (debris from short noisy fragments) while `THEM-A` still held at least four different people across 3.9 minutes. A clustering threshold is one global distance cut, so it cannot shatter the quiet fragments and hold the loud multi-person cluster together at the same time; the fact that it is doing both at once is the signature of a cut that has run out of room. Only 0.05 of range remains below 0.55, and 0.5 is the floor.

**(2) A speaker change inside one segment.** At 2:01 in `20260727-103155` a single phrase starts in Sudip's voice and continues in Yash's, and it stays one undivided turn at 0.55. Clustering decides which cluster a segment belongs to, never where a segment ends, so no value of any threshold can split it. This is the failure that most directly implicates segmentation rather than clustering.

## What the spike has to answer

The migration itself is the thing to size, not to assume. FluidAudio 0.14.8 puts the `stepRatio` dial (0.1 vs 0.2) on `OfflineDiarizerConfig` / `OfflineDiarizerManager`, a different API with a different result type; the daemon runs the online `DiarizerManager` via `performCompleteDiarization` (`daemon/Sources/MeetingPipe/Transcription/FluidAudioRunner.swift`). Questions, in the order they gate each other:

1. Does the offline diarizer's finer step actually split a mid-segment speaker change on the real recording that shows one? `20260727-103155` at 2:01 is the pinned case, and it is a probe over an existing wav, not a code change.
2. What does the offline result type cost the callers that depend on the online one? FEAT3 voiceprints and the `<stem>.embeddings.json` sidecar are the named dependants; `MeetingCast` and the speaker overlay read what comes out of it.
3. Is the latency still acceptable? VALID1 measured a median 91x real time with headroom, and recorded 0.1 stepRatio as effectively free at that budget, but that was a note about the offline configuration, not a measurement of this daemon running it.
4. Does community-1's lower published DER (~17.7% AMI) show up on this corpus, measured the way DIAR2 measured, or is the published number about a benchmark this owner's meetings do not resemble?

Pre-register the verdict thresholds before running anything, per `/spike`'s shape. A NO-GO that says "the offline diarizer does not split the 2:01 case either" is a genuinely useful result and closes a line of inquiry that has been open since DIAR2 was filed.

## Out of scope

Re-opening the threshold. It is settled at 0.55 with the corpus numbers behind it; a spike that ends by proposing 0.5 is answering DIAR2's question again rather than this one. Removing `speakerManager.reset()`, which DIAR2 rejected by measurement twice (it reintroduces the ASR2 cross-meeting drift and does not touch a within-meeting merge). The LLM cleanup pass, which is DIAR5 and is a separate merge source.

## Acceptance

A `docs/spikes/` writeup with a GO or NO-GO verdict against thresholds registered before the probe ran, and the migration filed as its own task only if the verdict is GO. No production diarizer change lands from this task.
