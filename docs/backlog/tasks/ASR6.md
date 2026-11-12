---
id: ASR6
title: Transcription and diarization depend on one vendor package pinned exact, with a known macOS 27 Neural Engine issue tracked only in a manifest comment and no fallback runner
category: Transcription
status: new
priority: P3
comment: Filed 2026-10-24 (audit band, go-live DI-15): FluidAudio is the only TranscriptionRunner, pinned exact at 0.14.8, and upstream #738 (macOS 27 ANE access) lives only in a Package.swift comment with no doctor check. Watch task: on promotion re-check upstream, qualify any bump on ASR4's golden set plus voiceprint compatibility, add a doctor check, and only then spike a second runner. [Spec](./ASR6.md) Amended 2026-11-12 (upgrade review): #738 closed 2026-08-19; FluidAudio is 0.18.3, whose 0.15.8 pins diarizer artifacts to an immutable revision, 0.18.1 fixes all-blank CTC on M4 under macOS 27, and 0.17.3 adds Parakeet Ultra; a bump is now ready to qualify, with ModelHub (0.15.5) the one breaking API.
---

# ASR6: transcription and diarization depend on one vendor package pinned exact, with a known macOS 27 Neural Engine issue tracked only in a manifest comment and no fallback runner

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) DI-15). A watch task: P3, promote on a real macOS 27 transcription failure, or on upstream confirming the restriction. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Verified on 2026-10-24:

- **One runner, one package.** `FluidAudioRunner`'s doc comment calls it "The default (and only) ASR runner, returned by `TranscriptionService.makeRunner()`". It owns ASR (Parakeet TDT v3) and diarization (pyannote via `DiarizerManager`), and the per-speaker embeddings the voiceprint and roster are built on. The `TranscriptionRunner` protocol in `daemon/Sources/MeetingPipe/Transcription/TranscriptionRunner.swift` is the seam a second runner would plug into.
- **Pinned exact, deliberately.** `daemon/Package.swift` has `.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.14.8")`. LOCAL5 (archived in [q5-final.md](../q5-final.md)) pinned it because a floating `from:` drifted 0.12.4 to 0.14.8 and "diarization/embedding output is load-bearing". The go-live read put the pin at about five months old with newer releases unchecked.
- **The risk is tracked in a comment.** The same manifest comment says "Track before bumping: upstream #738 (macOS 27 ANE access) and #726". LOCAL5's archived spec set the promotion trigger for this leg as "macOS 27 GM or a confirmed ANE restriction". Nothing in the open backlog carries it, and no check in the app or `doctor` would notice the Neural Engine being unavailable before a meeting's transcription fails.
- **What a failure costs today.** The recording is kept either way (the WAV is written before transcription), so the loss is the transcript and everything downstream, until a fix ships. A Re-transcribe (ASR3) can recover the backlog once the stack works again.
- **Not checked from here:** whether macOS 27 has shipped, and the current state of FluidAudio #738 and #726. This Mac runs Darwin 25.5 (macOS 26.5). If macOS 27 is already generally available, LOCAL5's own trigger has fired and this task should be promoted rather than watched.

## Scope (on promotion)

1. **Re-check upstream.** Read #738 and #726 and the FluidAudio releases since 0.14.8; record what changed, and whether a bump fixes the issue.
2. **Qualify a bump against measurement, not taste.** A FluidAudio bump moves transcripts and embeddings, so it goes through [ASR4](./ASR4.md)'s golden set (WER, DER) and a voiceprint-compatibility check (do enrolled roster and self voiceprints still match the same people), the risk DIAR4 ([spike](../../spikes/diar4-offline-diarizer-migration.md)) named for a model change.
3. **Make the failure visible early.** A `MeetingPipe doctor` check, and a one-line notice, that says on-device transcription cannot run on this OS version, rather than learning it from a failed meeting.
4. **Only if 1 and 2 leave no working FluidAudio:** evaluate a second `TranscriptionRunner` (Apple's on-device speech APIs are the obvious candidate) for the languages the owner uses. Ukrainian coverage, diarization (a second runner may have none, which degrades the roster to the channel heuristic) and embedding compatibility are the questions; it is a spike, with thresholds set before measuring.

## Explicitly not

- Building a fallback runner before there is a failure. Two runners double the speech stack this repo has to keep calibrated, for a risk that may resolve upstream.
- Floating the pin. LOCAL5's reason for pinning still holds.
- The 0.15.x bump LOCAL5 deferred for streaming and enrolment features; that is a feature decision, not this risk. Live transcription stays I8 (P3).
- CI coverage of the declared macOS floor, which is [CI9](./CI9.md).

## Acceptance (on promotion)

- The upstream status of #738 and #726 recorded with dates in this spec or a short spike note.
- If a bump lands: ASR4 golden-set WER and DER before and after in the commit body, and a test or probe result showing enrolled voiceprints still resolve the same people; `cd daemon && swift build` and `swift test` green.
- If the doctor check lands: a test that it reports the unsupported state from an injected capability probe; `swift test` green with the new test count in the commit body.
- `python3 scripts/truth_fences.py both` green.

## Amendment 2026-11-12 (upgrade review)

Upstream re-check (GitHub releases and issues, read 2026-11-12):

**Watch reasons**
- **#738**, "MacOS 27 Beta 2 Release Notes mentions ios 27 locking down ANE", was **closed 2026-08-19**. Upstream treated it as an Apple-side change and filed Feedback FB23457001. The manifest comment's "Track before bumping" reason is now stale.
- **#726** (Sortformer BNNS Graph Error) closed 2026-07-06.

**FluidAudio releases since our 0.14.8**, latest v0.18.3 (2026-11-07). The ones that matter here:
- **v0.15.5:** the download stack becomes `ModelHub`, replacing `DownloadUtils`. **Breaking for us:** we use `DownloadUtils.DownloadProgress` at one site.
- **v0.15.7:** the offline diarizer warns about BNNS-crash-prone builds on macOS 14 (upstream #878).
- **v0.15.8:** "Pin diarization artifacts to immutable revision" (upstream #927). This closes the diarizer half of DIST7's `resolve/main` gap.
- **v0.17.3:** `AsrModelVersion.ultra` (Parakeet Ultra), "a post-trained v3 that is more accurate everywhere at the same speed", with the same 25 languages and API. `.v3` stays the default. `.redux` is a 2-bit variant of about 220 MB.
- **v0.18.1:** "The CTC mel spectrogram runs on the CPU, fixing all-blank CTC on M1/M4 with macOS 27.0.1". The owner's Mac is an M4 Max on macOS 27.2, which bears on ASR5's vocabulary-boosting spike.
- **v0.18.2:**
  - the offline diarizer keeps overlapping speech by default (`exclusiveSegments: false`), a behaviour change;
  - CAM++ `_v2` speaker embeddings (AMI EER 4.67% to 2.85%), which would move voiceprints.

Added scope:
- On promotion, bump to the latest 0.18.x and port the one `DownloadUtils.DownloadProgress` use to `ModelHub`.
- Keep `.v3`, the current diarizer and the current embedding model for the bump itself.
- Offer Parakeet Ultra as a separate measured switch on ASR4's golden set.
- CAM++ v2 or Nemotron 3 diarization are spikes with a re-enrolment plan, per DIAR4's voiceprint reasoning.

Added acceptance: the bump's commit records ASR4 WER and DER before and after on `.v3`, and Ultra's numbers if it is tried.
