# ASR6: transcription and diarization depend on one vendor package pinned exact, with a known macOS 27 Neural Engine issue tracked only in a manifest comment and no fallback runner

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) DI-15). A watch task: P3, promote on a real macOS 27 transcription failure, or on upstream confirming the restriction. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

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
