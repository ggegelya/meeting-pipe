---
id: SEC37
title: HeldEndTrim.trimSeconds reads meta.json with try?, so an unreadable sidecar transcribes the post-call tail the trim was meant to drop
category: Security
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). HeldEndTrim.trimSeconds(forAudio:) folds an unreadable or unparseable <stem>.meta.json into "no trim", so a retry or re-transcribe while iCloud has the sidecar dataless (the SEC25 incident shape, 2026-10-16) writes the held post-call tail into <stem>.json, and a later re-summarize or publish carries it; not seen in the field (4 held_end_excluded rows, all read cleanly). Read through MeetingMetaRead and fail the job with no transcript written on unreadable.
---

# SEC37: HeldEndTrim.trimSeconds reads meta.json with try?, so an unreadable sidecar transcribes the post-call tail the trim was meant to drop

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: F051 in the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md) (medium, confirmed by its verifier), and the "G001 trim path is live in the newest build; its destructive form was not seen" row of the [field evidence](../../audits/2026-11-13-field-evidence.md), which lists F051 among the trim findings it could not demonstrate. Code re-read at HEAD 3a2da4fc on 2026-11-13.

**The reader.** `HeldEndTrim.trimSeconds(forAudio:)` in `daemon/Sources/MeetingPipe/Transcription/HeldEndTrim.swift` builds the `<stem>.meta.json` path beside the audio and reads it as `guard let data = try? Data(contentsOf: meta), let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }`. Absent, unreadable (an I/O error with the file present) and unparseable all return nil, which the caller reads as "no trim".

**The caller.** `SinkDispatcher`'s transcription pass, below the PIPE36 commit point (`claimCompletion(of: job, passSucceeded: true)`), does `if let trimAt = HeldEndTrim.trimSeconds(forAudio: job.file) { sidecar = HeldEndTrim.apply(sidecar, at: trimAt) ... }` and then `try sidecar.write(to: jsonURL)`. It is the only caller of the `forAudio:` overload, and it runs for both `.full` and `.retranscribe` jobs. On a nil it writes every segment of the pass, tail included, and logs no `held_end_excluded` row, so nothing records that the cut was skipped.

**Why the sidecar can be unreadable.** SEC25 (done, 2026-10-26) exists because iCloud made `<stem>.meta.json` dataless on 2026-10-16 (EDEADLK), and it added the three-state `MeetingMetaRead` (`absent`, `loaded`, `unreadable(kind:domain:code:)`) for the Swift readers that make a privacy or routing decision from the sidecar: `cloudSecretPolicy`, `MeetingLibraryService.isZeroEgress`, `reassignWorkflow`, the `MeetingStore` row build, and since then `AudioRetentionSweep` and `OrphanRecordingRecovery`. `HeldEndTrim` landed with END17 on 2026-10-24, two days before SEC25 shipped, and was not added to that list. `MeetingStore`'s row build already reads the same key through `MeetingMetaRead` (`heldEndTrimSec: meta.flatMap(HeldEndTrim.trimSeconds(meta:))`), so the Library and the transcription pass can disagree about one meeting.

**When it bites.** The first transcription runs seconds after stop, against a sidecar the stop path just wrote locally, so the realistic trigger is a later pass over an older meeting: a Library Retry or Re-transcribe (ASR3) while the library sits in iCloud-synced `~/Documents` (STOR6, and the owner's library does) with the sidecar evicted. That pass is still clamped local by Python's `mp.workflow.load_meta`, which fails closed on unreadable. But the `<stem>.json` it wrote now holds the tail, so a later Re-summarize or publish, once the sidecar reads again, puts the post-call minutes into the summary and every sink.

**Correction at filing (scope of the harm).** The audit calls this a "privacy trim" that "fails open". It is narrower: under regulated mode or an NDA workflow, `CaptureMode.resolve` returns `.regulatedGate`, `capturesLosslessly` is false, and `MeetingSessionController.stopRecording` cuts the WAV at stop (`recorder.stop(limitSeconds: keepsHeldTail ? nil : trimSeconds)`) and writes no `held_end_trim_sec`. So there is no tail on disk to leak in those postures. What this defect exposes is the post-call tail of an ordinary capture-first meeting, which END17 keeps in the WAV only as a recovery copy and promises the words leave out. The fix stays fail-closed for that promise, and this task is not gated on regulated or NDA use.

**Field.** The newest build ran the suggested trim on 4 of its first 6 recordings (`held_end_trimmed` mode suggested and `held_end_excluded` on stems 20261112-163040, 20261112-163626, 20261112-172307, 20261113-093231, tails of 60 to 63 s). All four sidecars read cleanly, so the unreadable branch has not fired in the field. The path that would hit it runs on most recordings.

## Scope

1. **One reader.** Replace the `forAudio:` overload's `try?` read with `MeetingMetaRead.load(stem:in:)`, returning the three outcomes to the caller: `absent` means no trim, `loaded` means `trimSeconds(meta:)`, and `unreadable` is surfaced, never folded into nil. The `trimSeconds(meta:)` overload and `apply` stay as they are.
2. **Fail the job on unreadable.** In `SinkDispatcher`'s transcription pass, an `unreadable` outcome throws a typed error before `sidecar.write(to:)`, so the existing catch branch handles it: `engine_failed` is logged, a `.full` job writes a `PipelineFailureSidecar` at stage transcribe, and a `.retranscribe` writes nothing and lets the Library caller surface the error, as it does for any failed re-transcribe. No `<stem>.json` is written. The reason text says the meeting's settings file could not be read and to retry once it is available (it may still be downloading from iCloud). Reading the sidecar before the pass, so a dataless file does not cost a full ASR run first, is acceptable; the session decides where the read sits as long as the write never happens on unreadable.
3. **One event.** Emit `transcription` / `held_end_trim_unreadable` with `file`, `kind` (`io` or `parse`), `domain` and `code`, once per failed job, so the failure is greppable apart from a model or runner fault.

## Explicitly not

- Materialising dataless iCloud files before the read (`startDownloadingUbiquitousItem`, an EDEADLK retry loop): [STOR6](./STOR6.md) owns iCloud placement. This task makes the read failure safe, not rarer.
- Where the trim point sits, and the hold routes that stamp it: [END21](./END21.md) (the cut at the hold's first weak stamp however long the hold ran). This task only changes how the stamp is read.
- A Codable `MeetingMeta` owning every sidecar read: [ARCH10](./ARCH10.md). If it has landed by pickup, use its load result instead of calling `MeetingMetaRead` directly.
- Other stores that read unreadable as empty: [STOR9](./STOR9.md). Library-wide readers that skip unreadable sidecars: [PIPE35](./PIPE35.md).
- Python's `held_end_trim_sec` handling: the pipeline treats the key as informational (`mp.workflow`'s docstring) and never cuts the transcript itself, so there is no second reader to fix.
- Transcribing anyway and marking the transcript untrimmed: it still puts the tail on disk in the one file every later summarize reads.

## Acceptance

- `HeldEndTrimTests`: the existing by-stem test keeps passing for a present and a missing sidecar; new cases for an unparseable sidecar (garbage bytes) and an unreadable one (a directory at the `<stem>.meta.json` path) each return the unreadable outcome, never "no trim".
- A `SinkDispatcher` test with a fake runner and an unreadable sidecar beside the WAV: for a `.full` job no `<stem>.json` is written, a failure sidecar is written at stage transcribe, `held_end_trim_unreadable` is emitted with `kind` and `code`, and the pipeline is not invoked; for a `.retranscribe` job the existing `<stem>.json` is left byte-for-byte unchanged and the completion reports a failure.
- A `SinkDispatcher` test with a readable sidecar carrying `held_end_trim_sec` still writes the trimmed transcript and logs `held_end_excluded`, and one with no sidecar writes the full transcript.
- `cd daemon && swift test` green with the number of new tests in the commit body; `python3 scripts/truth_fences.py events` green; `bash scripts/ci-local.sh` green.
- `CONVENTIONS.md`'s sidecar section, same commit: the three-outcome table's unreadable row (Swift column) adds that the transcription pass fails the job and writes no transcript, and the `held_end_trim_sec` row says the key is read through `MeetingMetaRead`.
