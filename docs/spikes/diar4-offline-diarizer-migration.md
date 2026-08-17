# DIAR4 spike: the offline-diarizer migration for the failures no threshold can reach (closed, NO-GO)

Spike, 2026-08-18. **Verdict: NO-GO**, measured. Probe: [`daemon/scripts/diar4-offline-diarizer-probe/`](../../daemon/scripts/diar4-offline-diarizer-probe/), a standalone SwiftPM package that runs both diarizers over one existing recording and prints a READ line. Like END6 and unlike CAL1 / MIC7 / DET2 / MIC8, this probe was **session-runnable**: it needs no live meeting, no microphone, no screen capture and no TCC grant, only file I/O over a WAV that already exists plus CoreML inference, so it was built and run here rather than queued on the owner.

The offline diarizer does not split the mid-segment speaker change either, and the second half of the finding is the more useful one: **both diarizers already emit a boundary at that change and label both sides the same speaker**, so the case is cluster assignment rather than the segmentation limit DIAR2 recorded and this task was filed on.

## Question

DIAR2 closed by settling `transcription.diarization_clustering_threshold` at 0.55 and by establishing that the lever is spent, with two residual failures a single global distance cut cannot reach. The one that most directly implicates segmentation is a **speaker change inside one segment**: at 2:01 in `20260727-103155` a phrase starts in Sudip's voice and continues in Yash's, and it stays one undivided turn at 0.55. Clustering decides which cluster a segment joins, never where a segment ends, so no threshold value can split it.

FluidAudio 0.14.8 puts the `stepRatio` dial on `OfflineDiarizerConfig` / `OfflineDiarizerManager`, which is a different pipeline from the online `DiarizerManager` the daemon runs. The question this spike answers, and the only one that gates the rest:

**Does the offline diarizer's finer segmentation step actually split that mid-segment speaker change on the real recording that shows one?**

Three further questions gate behind it, in the spec's order: what the offline result type costs the callers, whether the latency is still acceptable, and whether community-1's published DER advantage shows up on this corpus. A NO-GO on question 1 closes all three, and closes a line open since DIAR2 was filed.

## The case, pinned exactly

`~/Documents/Meetings/raw/20260727-103155.wav`, stereo 16 kHz, 574.42 s. The transcript on disk (re-transcribed at 0.55 on 2026-07-31, so it is the settled configuration and not a stale one) carries this segment:

```
112.32 - 118.32  Sudip            Mm-hmm. Okay. Okay, and shadow. Thank you. ...
120.48 - 121.84  speaker_unknown  Thank you.
121.84 - 147.12  Sudip            Let's go next with Yesh. Laiash. Yes, hello everyone. Uh so for today uh on Friday Prajwal have ...
```

The third row is the defect. It opens with Sudip handing over ("Let's go next with Yash") and continues with Yash answering ("Yes, hello everyone"), and the whole 25.3 s carries one speaker id. The handover phrase is roughly the first three seconds of it, so the true change is near 125 s, inside a segment that runs to 147.12 s.

## Candidate mechanisms, and what closes without measurement

Four mechanisms could in principle produce a boundary at 125 s. Three of them close from the code and the documentation.

**Lowering the clustering threshold further. Closed, out of scope by the spec and by construction.** Clustering assigns a segment to a cluster; it never subdivides one. DIAR2 measured the remaining range at 0.05 and rejected spending it.

**`speakerManager.reset()`. Closed twice by measurement (DIAR2), and here it is moot in a third way**: `OfflineDiarizerManager` has no `speakerManager` at all. Its only retained state is the loaded `MLModel` set; `process()` builds its extractor, its clustering and its centroids per call (`OfflineDiarizerManager.swift:135-200`). The offline pipeline is stateless across calls by construction, so the ASR2 cross-meeting drift the online path needs `reset()` to prevent cannot arise on it.

**The LLM cleanup pass. Out of scope, DIAR5 owns it**, and it is a merge source rather than a split source, so it cannot produce this boundary.

**The offline diarizer's segmentation step. Not closeable from documentation, and the reason this is a spike.** `OfflineDiarizerConfig.Segmentation` carries `windowDurationSeconds: 10.0` and `stepRatio`, defaulting to 0.2 with the upstream comment "This with 1.0 min speech duration gives us ~1.4% worse DER but 2x the speed" (`OfflineDiarizerTypes.swift:46-55`). At 0.2 the 10 s window advances 2 s at a time; at 0.1 it advances 1 s. That is the finer time grid the spec means, and whether it resolves a change mid-phrase on this audio is an empirical question about this recording, not a documented property.

## What the migration would cost, settled a priori (question 2)

Read before the probe ran, from FluidAudio 0.14.8's own sources, so a GO on question 1 lands on a costed migration rather than an open one.

**The result type is the same type, not a different one.** `OfflineDiarizerManager.process` returns `DiarizationResult` with `[TimedSpeakerSegment]`, exactly what `performCompleteDiarization` returns (`DiarizerTypes.swift:161-213`; the offline manager's three `process` overloads all return it). The spec's expectation of "a different result type that FEAT3 voiceprints depend on", inherited from DIAR2's 2026-07-17 reading, is **wrong for 0.14.8**: `speakerId`, `embedding`, `startTimeSeconds`, `endTimeSeconds` and `qualityScore` are all present, so `FluidAudioRunner.runDiarization`'s two consumers (`SpeakerSpan` construction and `weightedMeanEmbeddings`) compile against it unchanged.

**Three real differences remain, and one of them is a trap.**

1. **The raw speaker id changes shape**, from the online `"1"`, `"2"` (`SpeakerManager.swift:470`) to the offline `"S1"`, `"S2"` (`OfflineReconstruction.swift:344`). This is absorbed: `mp.diarize.resolve_speaker_labels` maps raw ids to `THEM-A` by first-appearance order and never parses them as integers. Worth a check rather than a worry: `MeetingCast.isPlaceholder` tests `hasPrefix("THEM-")` or `hasPrefix("speaker_")`, so a raw `S1` that somehow reached the UI would not read as a placeholder.

2. **`TimedSpeakerSegment.embedding` stops being per-segment.** The offline reconstruction stamps every segment of a cluster with that cluster's centroid (`OfflineReconstruction.swift:343-345`). `weightedMeanEmbeddings` then computes a duration-weighted mean of identical vectors, which is the centroid again. Not a defect, but it means the sidecar's voiceprint becomes the clustering centroid rather than an independent duration-weighted average, and any future code that assumed per-segment variation would be reading a constant.

3. **The embedding model is a different model, and the dimension hides it.** The online path embeds with `wespeaker_v2.mlmodelc` (7,243,904 bytes of weights, already cached on this Mac); the offline path embeds with `Embedding.mlmodelc` (13,412,288 bytes, per the HuggingFace tree for `FluidInference/speaker-diarization-coreml`). Both emit 256 floats. So every enrolled FEAT3 roster voiceprint and every `<stem>.embeddings.json` on disk would keep loading, keep comparing, and keep producing cosine distances, in a space where those distances mean nothing. The failure mode is not a crash or a dimension mismatch; it is silent wrong roster matches. **Any migration must re-enroll the roster and treat old embeddings sidecars as stale**, and that cost is the owner's, not the session's.

There is also a one-time download: the offline pipeline needs four CoreML bundles (`Segmentation`, `FBank`, `Embedding`, `PldaRho`, 21.5 MB total) that the online path never fetches. They land in the same `~/Library/Application Support/FluidAudio/Models/speaker-diarization/` the online models already occupy, from the same pinned repo. `plda-parameters.json` is already there.

**Question 4's premise is shakier than it looks, and it is upstream's fault, not the spec's.** DIAR4 asks whether "community-1's lower published DER (~17.7% AMI)" shows up on this corpus, which presumes the daemon is not running community-1 today. FluidAudio 0.14.8 says both things about itself: `Documentation/Models.md` attributes the online `DiarizerManager` to pyannote/speaker-diarization-3.1 and only the offline manager to community-1, while `Documentation/Benchmarks.md` says flatly that "Both offline and online versions use the community-1 model", and the **online** `SegmentationProcessor.swift:227` carries the comment "These values come from the pyannote/speaker-diarization-community-1 model configuration". `ARCHITECTURE.md`'s "pyannote-community-1 for diarization" is therefore defensible on one upstream reading and wrong on another, so this spike does not rewrite it on a contested point. What is not contested, and is what actually separates the two pipelines, is measured above: different embedding weights, and VBx / PLDA clustering offline against `SpeakerManager` online.

The published numbers worth carrying, from `Documentation/Benchmarks.md` in the pinned 0.14.8: offline on AMI SDM averages **10.6% DER at 69.8 RTFx** over the 16-meeting split, and upstream's own note on the online path is "expect +10-15% worse DER for the streaming implementation". On voxconverse it measures the two offline operating points directly: **15.07% DER at `stepRatio` 0.2 with `minSegmentDurationSeconds` 1.0**, against **13.89% at 0.1 with 0.0**, and it names that second pair as the configuration "for highly critical use cases".

## Pre-registered verdict thresholds

Written before the probe was built and before any number was measured. The primary criterion is question 1 alone; questions 2 to 4 are gated behind it and do not vote on this verdict.

The measurement is over the interval **[121.84, 147.12]**, the exact bounds of the offending transcript segment, on the exact same mono samples the daemon would feed the diarizer (explicit `(L+R)/2` downmix, per `FluidAudioRunner.readMonoFloat32`).

The offline configuration under test is **`stepRatio` 0.1 with `minSegmentDurationSeconds` 0.0**, not 0.1 alone. That pairing is upstream's own "highly critical use cases" setting and its better-measured operating point (13.89% against 15.07% DER on voxconverse), and leaving `minSegmentDurationSeconds` at its 1.0 default would discard every sub-second span before it is embedded, which is the size of evidence a mid-phrase change turns on. Fixing that before measuring is configuring the mechanism at its documented best; changing it after seeing a number would be fitting, which is what this section exists to prevent.

| Verdict | Criterion |
|---|---|
| **GO** | The offline run assigns **two or more distinct speaker ids** inside [121.84, 147.12], each holding at least **1.0 s** of it, and the earliest change point falls inside **[122.0, 132.0]** (the handover region; the handover phrase is about the first 3 s of the segment, and 132.0 leaves a 7 s margin for word-timing slop). |
| **MARGINAL** | A split is found inside the segment but either the earliest change point falls outside [122.0, 132.0], or one side of it holds less than 1.0 s (that reads as debris, not a turn). Decided by the owner rather than by this spike. |
| **NO-GO** | The offline run covers [121.84, 147.12] with a **single** speaker id, which is the same failure the online run at 0.55 produces, or it cannot produce output on this file at all. |

Secondary readings recorded but **not** part of the verdict, because fitting a verdict to them after the fact is the failure mode this section exists to prevent:

- **Latency (question 3).** PASS at offline diarization wall time <= 120 s for this 574 s file (>= 4.8x real time). MARGINAL 120 to 300 s. FAIL above 300 s (under 2x real time, where a one-hour meeting costs over half an hour).
- **Cluster count and debris.** The online control at 0.55 and the offline run both report their cluster count and how many clusters hold under 5 s of speech, the two numbers DIAR2's sweep used. Recorded for the record; a GO on question 1 does not require them to improve.
- **Question 4 (community-1 DER on this corpus)** is deliberately not attempted here. It needs the hand-corrected corpus and `scripts/valid1_check.py --der`, and it only becomes worth spending on a GO.

## The probe

```bash
cd daemon/scripts/diar4-offline-diarizer-probe
swift run -c release diar4-offline-diarizer-probe ~/Documents/Meetings/raw/20260727-103155.wav
```

Read-only: it opens one existing WAV, runs both diarizers in memory, prints, and writes nothing except the CoreML model cache FluidAudio manages itself. It touches no production code, no config, and no meeting sidecar. It is its own SwiftPM package so `swift build` in `daemon/` neither builds it nor is affected by it, and it pins the same exact FluidAudio 0.14.8 the daemon pins.

The first run downloads the four offline model bundles (21.5 MB); later runs use the cache. `--window <start> <end>` re-points the measured interval at a different case, `--step-ratio` overrides the 0.1 default, `--threshold` moves the online control off the shipped 0.55, and `--skip-online` / `--skip-offline` run one side alone. `--skip-offline` is the half that needs no download, since the online models are already cached wherever the daemon has ever transcribed.

## Where it ran

The TCC objection this project applies to owner-run probes does **not** bite here, and that was checked rather than assumed. Probe question 1 is file I/O over a WAV that already exists plus CoreML inference: no microphone, no screen capture, no Accessibility, no calendar, so the disclaimed-parent problem that voids TCC probes in this harness has nothing to void. The session read `~/Documents/Meetings/raw/20260727-103155.wav` (9,190,720 samples at 16 kHz), built the probe, and ran both pipelines, with no permission prompt at any point.

The one thing that did need asking was not a permission grant but a **21.5 MB download**: the four CoreML bundles (`Segmentation`, `FBank`, `Embedding`, `PldaRho`) the offline pipeline needs and this Mac had never fetched, since the online path does not use them. The owner approved it on 2026-08-18 and FluidAudio's own loader fetched them into `~/Library/Application Support/FluidAudio/Models/speaker-diarization/`, beside the online models already there.

### Raw output, 2026-08-18

Both pipelines, one command, the same samples. Copied verbatim from the run:

```
DIAR4 probe
  wav:        /Users/userinverita96/Documents/Meetings/raw/20260727-103155.wav
  window:     [121.84, 147.12] s
  step ratio: 0.1   (offline)
  threshold:  0.55   (online control)
  samples:    9190720 at 16 kHz (574.4 s)

--- offline ---
  spans returned:        90
  distinct clusters:     3
  clusters under 5 s:  0
  wall time:             23.4 s
  spans inside the window:
    121.84  ->  124.65   S1
    125.96  ->  147.12   S1
READ: offline stepRatio=0.1 minSegDur=0.0 clusters=3 window=[121.84,147.12] ids_in_window=1 change_points=0 at=none
  embedding dims present: [256]

--- online ---
  spans returned:        108
  distinct clusters:     10
  clusters under 5 s:  3
  wall time:             3.9 s
  spans inside the window:
    121.97  ->  124.61   1
    125.92  ->  129.94   1
    130.00  ->  139.94   1
    140.00  ->  147.12   1
READ: online threshold=0.55 clusters=10 window=[121.84,147.12] ids_in_window=1 change_points=0 at=none

VERDICT INPUT: online control split inside the window? NO
VERDICT INPUT: offline split inside the window? NO
```

An earlier online-only run of the same probe returned the identical four spans and the identical single id at a 9.2 s wall time; 3.9 s above is the warm figure from the combined run.

## Verdict: NO-GO

The offline run covers [121.84, 147.12] with a **single speaker id** (`S1`), which is the pre-registered NO-GO criterion's first clause, word for word. It is not MARGINAL: that band requires a split to be found somewhere inside the segment, and there is none. It is not GO: that needs two or more ids each holding at least 1.0 s, and there is one.

**The offline diarizer does not split the 2:01 speaker change either.** The `stepRatio` lever is closed, and with it the migration DIAR2's own step 5 pre-registered for exactly this outcome. Questions 2 to 4 were gated behind question 1 and do not open; what was already settled about question 2 is recorded above and stands as the cost estimate for anyone who reopens this.

The secondary readings, recorded as pre-registered and voting on nothing:

| | online, 0.55 (control) | offline, stepRatio 0.1 / minSegDur 0.0 |
|---|---|---|
| Spans returned | 108 | 90 |
| Distinct clusters | 10 | 3 |
| Clusters holding under 5 s | 3 | 0 |
| Distinct ids in [121.84, 147.12] | 1 | 1 |
| Change points in the window | 0 | 0 |
| Diarization wall time | 3.9 s | 23.4 s |

**Latency PASSES its pre-registered bar** and is not close: 23.4 s against a 120 s bar, which is 24.5x real time on this 574.4 s recording (that multiple is the two measured figures divided, not a separate measurement). Question 3 is answered in the affirmative and it does not matter, because question 1 gates it.

**The cluster counts are the second reason not to migrate, and they point the opposite way from the hope.** The offline pipeline returns **3 clusters** where the online path returns 10 and where this meeting's shipped `<stem>.embeddings.json` carries 9 speaker keys. Under-clustering at that scale is precisely the defect DIAR2 called the broken core promise, the one the 0.55 sweep bought back at real cost. It also explains the clean debris column: 0 clusters under 5 s is not tidiness, it is what collapsing everything into three buckets looks like. One meeting is one meeting and cluster count is not ground truth, so this is a caution rather than a measurement of accuracy. But a migration whose first observed behaviour is a harder merge, in exchange for re-enrolling every roster voiceprint, has no case to answer.

## The correction this spike actually delivers

The verdict closes a line of inquiry. This part reaches further, and it is the half worth carrying, so it is stated with the numbers attached rather than as a conclusion to be inherited.

**DIAR2 recorded, and DIAR4 was filed on, the claim that the 2:01 case is a *segmentation* failure**: "clustering decides which cluster a segment belongs to, never where a segment ends, so no value of any threshold can split it". `ARCHITECTURE.md` inherited the same sentence. The reasoning is sound and the conclusion about thresholds is correct. The premise, that no boundary exists at 2:01, is false, and both pipelines say so:

- **online at 0.55**: `121.97 -> 124.61`, then `125.92 -> 129.94`. A boundary at 124.61 / 125.92.
- **offline at stepRatio 0.1**: `121.84 -> 124.65`, then `125.96 -> 147.12`. A boundary at 124.65 / 125.96.

Two pipelines that share no clustering algorithm, no embedding model and no segmentation step size put a boundary within 0.04 s of each other, in the middle of the transcript row, and then label both sides the same speaker. The boundary is a 1.31 s silence in the audio, which is why both find it and why finding it is cheap; the thing neither does is decide that the voice after the silence is a different person.

Where the handover falls is still an inference and should be read as one: the ASR text opens "Let's go next with Yesh. Laiash. Yes, hello everyone", six words of Sudip before Yash answers, which places the change around three seconds into a row starting at 121.84, inside the gap both pipelines found. Listening to those four seconds would settle it outright, and that is an owner action nobody should spend on its own.

So the defect is **cluster assignment across an existing boundary**, not segmentation resolution. Three consequences:

1. `stepRatio` was never going to reach it, which the verdict above confirms independently.
2. The case belongs in the same family as the multi-person `THEM-A` in `20260803-103042`, rather than in a family of its own. Whatever picks it up works on assignment: per-span re-scoring against enrolled voiceprints, or an overlap-aware pass.
3. **A transcript row is not the diarizer's unit.** `SegmentBuilder` attributes ASR tokens to speaker spans and `coalesce` folds consecutive same-speaker fragments into one turn, so an undivided row is equally consistent with a correct split whose halves got the same label. That reading trap is what produced the original claim, and it is now written down in `daemon/docs/gotchas.md` so the next session checks the diarizer's spans instead of inheriting a conclusion. Re-run the probe to check this; it is two lines of output.

This bears on **DIAR5**, which is live work on the same surface: its merge source sits downstream of exactly this assignment step, on a pass that sees `[i] Label: text` and no audio. Nothing here changes DIAR5's scope, and this spike deliberately touched none of its files.

## Hard rules honoured

No production code changed, and no migration task was filed, which is what a NO-GO buys. The probe is a separate package under `daemon/scripts/`, read-only, and safe to run during a real meeting (it holds no audio device and writes no sidecar).

The thresholds were written into this file before the probe existed and were not touched after a number appeared; the verdict quotes the NO-GO row's own wording rather than paraphrasing it. Every figure in the Result section is copied from the probe's stdout, except three that are labelled where they appear: the 24.5x real-time multiple (the two measured wall figures divided), the 9 speaker keys in this meeting's shipped `<stem>.embeddings.json` (read off the file on disk), and the upstream benchmark numbers in the question-4 paragraph, which come from FluidAudio 0.14.8's own `Documentation/Benchmarks.md` and were never measured on this machine.
