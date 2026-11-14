---
id: PIPE45
title: A redaction that lands after the PIPE36 deadline makes the suggested Retry hold the meeting back and overwrite the kept original with the redacted copy
category: Pipeline
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). PIPE36 (done) does not hold for a redaction that finishes late: `MuteRedactor.redactIfNeeded` returns `timeline_missing` on the surviving `.offrecord` marker before it reaches its kept-original check, so the Retry the timeout row suggests holds the meeting back and `MuteRedactor.quarantine` deletes the kept full recording and moves the redacted WAV over it; a quit between `.redacted` and the marker removal leaves the same state with no deadline involved. Code-derived, not yet reachable in the field (no installed build carries PIPE36). Run the kept-original check before the missing-timeline arm and never let a quarantine replace an existing file, pinned with the real redactor and quarantine.
---

# PIPE45: A redaction that lands after the PIPE36 deadline makes the suggested Retry hold the meeting back and overwrite the kept original with the redacted copy

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: G009 in [2026-11-12-independent-audit.md](../../audits/2026-11-12-independent-audit.md) (confirmed, data lens). Every code claim below was re-read at HEAD `3a2da4fc` on 2026-11-13.

**PIPE36's fix does not hold for a redaction that returns late.** [PIPE36](./PIPE36.md) (done, commit `4949c9c0`, 2026-11-12) put a job deadline over the redaction and transcription phases and fenced every late exit of `SinkDispatcher.runDaemonTranscription`. Its redaction-phase fence makes this promise in a comment: "A redaction that landed after the deadline leaves the MIC14 marker in place; the retry's redactor finds the work already done (its own idempotency check) and the marker goes then." That is false. PIPE36's test, `test_a_redaction_that_never_returns_fails_the_job_and_the_next_one_runs`, covers a redactor that never returns. Nothing covers one that finishes after the deadline.

**The chain, step by step.**

1. The deadline expires in the redact phase. `deadlineExpired` fails the job with `TranscriptionTimedOut(phase: .redact)` and writes `<stem>.error.json` with `timedOutReason`, which ends "Retry; if it stops again, quit and reopen MeetingPipe first."
2. The redaction keeps going. `MuteRedactor.runFFmpeg` parks a thread in `proc.waitUntilExit()` and ignores cancellation (its ceiling and kill belong to [CONC5](./CONC5.md)). When ffmpeg exits 0, `redactIfNeeded` carries on as if the job were still live:
   - `moveOriginalAside` moves the full recording to `originals/<stem>.wav`.
   - The redacted temp is promoted to `raw/<stem>.wav`.
   - The timeline is deleted ("Reap the timeline so a re-run no-ops at the read guard above").
3. Back in `runDaemonTranscription`, `isLive(job)` is false. `logLateReturn` writes one file-log line and returns before `OffRecordMarker.remove(forFinal:)`, so `<stem>.offrecord` stays on disk.
4. The owner presses Retry. `MeetingLibraryService.retryMeeting` re-enqueues the job, and a Re-transcribe goes through the same function. Either way, `redactIfNeeded` runs again:
   - `MuteTimelineFile.load` returns `.missing`.
   - The `.missing` arm runs `if OffRecordMarker.exists(forFinal: wav) || CaptureMode.recorded(forFinal: wav) == .captureFirstRedact { return fail(.timelineMissing, ...) }`.
   - That return comes before the idempotency check (`let kept = originalsURL(for: wav, in: dir)`, then "fileExists(atPath: kept.path), !contentsEqual"), so the check is never reached.
5. `.failed(.timelineMissing)` sends the job to `SinkDispatcher.quarantineHeldBack`, which calls `MuteRedactor.quarantine`:
   - Its `dest` is `originalsURL(for: url, in: dir)`, the same path as the kept original.
   - It runs `try? FileManager.default.removeItem(at: dest)` and then `moveItem(at: url, to: dest)`.
   - So the only full recording is deleted, and the redacted copy takes its place.
   - The row now shows `heldBackReason` ("The full recording is kept in MeetingPipe's originals folder"), which is no longer true, and every later Retry repeats the hold.

Correction at filing (reach): only the `.offrecord` marker reaches step 4. A redact-opt-in (`.captureFirstRedact`) recording loses its `.capturemode` marker at a clean stop: `MeetingRecorder.persistAfterMerge` removes it when "producedUsableFinal, !timelineWriteFailed". So after a late redaction, its Retry reads `.missing` with no marker, returns `.notNeeded`, and correctly consumes the redacted WAV. The defect needs two things:

- a manual off-the-record span (`MeetingSessionController` writes `OffRecordMarker` when off-the-record starts under a lossless capture mode);
- a redaction that outlasts the deadline (10 minutes plus 0.2 s per audio second), for example on a slow or dataless volume.

It is not limited to regulated mode, because the regulated gate cuts muted audio in real time and writes no timeline.

Correction at filing (fix direction): the audit's first direction was to stop the redaction ffmpeg on a redact-phase expiry. That does not close the class. A daemon that quits or crashes between `redactIfNeeded` returning `.redacted` and `OffRecordMarker.remove` leaves the same disk state: kept original present, timeline deleted, `.offrecord` still there. On relaunch, `reconcileStrandedJobs` marks the meeting interrupted (a final WAV and no terminal sidecar), and its Retry walks steps 4 and 5. The window is one main-queue hop wide, so it is rare, but the overwrite is identical. That is why the scope below fixes the redactor and the quarantine, not the deadline.

`moveOriginalAside` also calls `try? removeItem(at: dest)` before its move. That one is safe as things stand: the idempotency check returns before it whenever a different kept original exists, so it only ever removes a byte-identical copy (SEC16's carve-out).

**Field.** Not reachable yet. The field pack lists G009 as not seen, because the code is newer than any installed build. The same pack shows off-the-record redaction is used, but rarely: one `mute_timeline_written` and one `mute_redacted` with 1 span ([2026-11-13-field-evidence.md](../../audits/2026-11-13-field-evidence.md), the "Not seen" list).

Related:

- [SEC26](./SEC26.md) (new): its item 1 moves `quarantine`'s destination into `originals/held/`. That removes the overwrite once it lands, but not the permanent false hold. Whichever task lands second keeps both changes.
- [REC21](./REC21.md) (new): the reliability of the marker writes.
- [CONC5](./CONC5.md) (new): the redaction ffmpeg's ceiling and kill.
- [DEP2](./DEP2.md) (new): replaces that ffmpeg.
- [MIC18](./MIC18.md) (P1): on GO, offline redaction becomes the regulated path, and this defect then reaches regulated meetings too.

## Scope

1. **Kept-original check before the missing-timeline arm.** In `MuteRedactor.redactIfNeeded`, when `MuteTimelineFile.load` returns `.missing`, first ask whether a kept original exists at `originalsURL(for: wav, in: dir)` and is not byte-identical to `wav`. If so, return `.redacted`, the same answer the existing idempotency check gives. Only otherwise fall through to the `.offrecord` / `.capturemode` test and `timeline_missing`. The `.unreadable` arm and SEC16's byte-identical carve-out stay as they are: an identical copy still means the full recording was copied back by hand and must be redacted. The job then removes `.offrecord` on its normal path.
2. **A quarantine never replaces a file.** `MuteRedactor.quarantine` drops its `try? FileManager.default.removeItem(at: dest)`. When `dest` exists, it throws without moving anything. `quarantineHeldBack` already has a failure arm for that (the WAV stays in place, never transcribed, and `recording_held_back` is logged with `kept` null). The orphan caller in `OrphanRecordingRecovery` logs and returns nil; the pickup confirms that nil never sends the file on to processing.
3. **Fix the comment.** The late-return comment in `runDaemonTranscription` becomes true after item 1. Keep it and name this task beside it.

## Explicitly not

- Stopping the redaction ffmpeg on a redact-phase expiry. That needs CONC5's per-process runner, and on its own it misses the quit/crash route above.
- Removing `.offrecord` on the abandoned exit. It would break PIPE36's "an abandoned job's exits write nothing" fence, and it also misses the quit/crash route.
- The `held/` folder, and Show recording instead of Retry on a held row: SEC26.
- The marker writes themselves: REC21.
- A restore UI for held recordings: still an owner decision, as SEC26 records.

## Acceptance

- `MuteRedactorTests`, the late-redaction disk state: `raw/<stem>.wav` holds redacted bytes, `<originalsDir>/<stem>.wav` holds different full bytes, there is no timeline, and `.offrecord` is present. `redactIfNeeded(wav:originalsDir:)` returns `.redacted`, emits no `mute_redaction_failed`, and leaves both files byte-unchanged.
- The same state with byte-identical copies still fails `timeline_missing`, which pins the SEC16 carve-out.
- `MuteRedactorTests`: `quarantine` into a directory where `dest` already exists throws and leaves both files byte-unchanged.
- `SinkDispatcherTests`, the late return followed by a Retry, with an injected originals directory:
  - First job: the redactor waits on a gate past a short deadline. Once released, it does the real on-disk work (moves the full fixture into the originals directory, writes a redacted WAV, deletes the timeline) and returns `.redacted`.
  - Second job: the same stem enqueued again, with `MuteRedactor.redactIfNeeded(wav:originalsDir:)` as its redactor. It reaches the runner, `.offrecord` is removed, the kept original's bytes equal the fixture's full recording, and no `recording_held_back` is emitted.
  - The redactor must be the real one so the test can fail at HEAD.
- `cd daemon && swift build` and `swift test` green, with N new tests named in the commit body; `bash scripts/ci-local.sh` green.
