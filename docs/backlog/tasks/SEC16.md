# SEC16: off-the-record redaction fails open (a failed or skipped redaction publishes the uncut recording), and it silences only the microphone channel

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) S1, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) fix 5 and PD-6). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

MIC14 (shipped, archived in [q6-final.md](../q6-final.md)) built the off-the-record toggle. Two properties of what shipped break the promise [GUIDE.md](../../../docs/GUIDE.md) makes in its "Off the record" recipe ("the marked stretch is cut out before anything reads the audio, so it never reaches the transcript, the summary, or anything you publish"). Both were re-read in the code on 2026-10-24.

**1. Every failure of the offline redaction is a silent no-op.** `SinkDispatcher.runDaemonTranscription` calls `await MuteRedactor.redactIfNeeded(wav: job.file)` and discards the result (the function is `@discardableResult`), then transcribes `job.file` and invokes the pipeline whatever happened. `redactIfNeeded` returns the same `false` for "nothing to do" and for every failure:

- ffmpeg not found: `Log.writeLine("recorder", "WARN: ffmpeg not found - skipping mute redaction ...")`, no event at all.
- ffmpeg exits non-zero or produces no file: one `mute_redaction_failed` event.
- `moveOriginalAside` fails, or the promote of the redacted artifact fails: a WARN line, the full recording restored in place.
- The timeline exists but does not decode: `MuteTimelineFile.read` is `try? JSONDecoder().decode(...)`, so a corrupt file reads as "no timeline" and the redactor returns before it starts.

Two more holes sit upstream of the job. `MuteTimelineFile.write` is best-effort (a failed write is a WARN line), and `MeetingRecorder.stop` logs `mute_timeline_written` whether or not the write landed. And `MeetingSessionController` removes the MIC14 `<stem>.offrecord` marker on every clean finish, before the job runs, so by the time redaction runs nothing on disk still says "this recording had an off-the-record span" except the timeline itself. In each case the uncut recording is transcribed, summarized, published, and (on the default cloud engine) sent to the provider, and stays playable in the Library's `raw/` tree.

**2. The redaction zeroes only the mic channel.** `MuteRedactor.buildFilter` splits stereo, applies `volume=0` to `[L]` (mic) and re-merges `[R]` (system audio) untouched. `FluidAudioRunner.readMonoFloat32` then transcribes `(L+R)/2`, so everything the other participants say during the stretch is still in the transcript. The regulated and NDA path has the same shape live: in `MeetingRecorder`'s mic tap, `.regulatedGate` calls `writer.apply(verdict:forceMuted: offRecord, ...)` on the mic buffer only, and the system capture callback (`SystemAudioCapture { pcm in ... self.systemWriter?.enqueue(pcm) }`) never reads `manualOffRecord`. README's `detection.off_the_record_hotkey` entry repeats the stronger promise ("the span is kept out of the transcript, summary, and every published artifact").

Auto mute spans (`source == .mute`) are a different feature: muting your own mic is about your voice only, so those stay mic-only whichever way the decision below goes.

## Scope

1. **Owner decision first (the pickup session asks before writing code): does off the record cover both channels?**
   - **Option A, both channels.** A `.manual` span silences mic and system audio. Offline: `buildFilter` gains a manual-span term applied to `[R]` as well (auto spans stay `[L]`-only), frame count unchanged so ADR 0009 parity holds. Live under `.regulatedGate`: the system capture callback zeroes the buffer while `manualOffRecord` is on, read under the same `gateAccess` lock. Consequence: the transcript has a true gap, the summary cannot mention the stretch, diarization sees silence; the recovery copy in `originals/` still holds both channels under capture-first. The pickup session must confirm the span times line up on `[R]` after the REC9 system-offset alignment in the merge.
   - **Option B, mic only (today's behaviour).** No audio change. The GUIDE recipe, the GUIDE glossary entry, README's hotkey entry and the HUD wording are rewritten to say only your microphone is cut and the other side is still transcribed. Consequence: the feature stops promising "a stretch that should not reach your notes", which is what the recipe opens with; the fail-closed half below still ships.
2. **Fail closed.** `redactIfNeeded` returns a typed outcome (`.notNeeded`, `.redacted`, `.failed(reason)`) instead of `Bool`, and a corrupt timeline is `.failed(timeline_unreadable)`, not "no timeline". `runDaemonTranscription` treats `.failed` on a timeline that carries any `.manual` span (or on a `.captureFirstRedact` recording) as a hard job failure: it writes `PipelineFailureSidecar` with a named reason, moves the WAV out of `raw/` with the same move `OrphanRecordingRecovery.quarantine` uses (via `MuteRedactor.protectOriginalAtRest`), and never transcribes it. An auto-only `.captureFirstRedact` failure keeps today's degrade only if the owner says so at pickup; the default is to fail it the same way.
3. **Keep the evidence until redaction succeeds.** `OffRecordMarker.remove` moves from the clean-finish branch in `MeetingSessionController` to after a successful (or `.notNeeded`) redaction, so a failed `MuteTimelineFile.write` (which then returns a result instead of only logging) is caught: marker present and no readable timeline means `.failed(timeline_missing)`.
4. Copy in the same commit: GUIDE "Off the record" and glossary, README `detection.off_the_record_hotkey`, matching whichever option was picked, and a sentence that a failed redaction holds the meeting for you rather than publishing it.

## Explicitly not

- Replacing ffmpeg with AVFoundation for the redaction. That is DEP2's class (ffmpeg is still a runtime dependency at three call sites); this task only makes its absence fail closed.
- Auto mute-span policy (MIC9, MIC12's per-span speech withhold): unchanged.
- A recovery UI for quarantined recordings. They land where orphan quarantine already puts them; surfacing them in the Library is a separate ask.
- The consent and voiceprint posture (SEC24, P3).

## Acceptance

- `MuteRedactorTests` gains: missing ffmpeg returns `.failed`; a corrupt timeline file returns `.failed(timeline_unreadable)`; a manual-only timeline over a stereo file (Option A) zeroes both channels inside the span and leaves both intact outside it, while an auto span still zeroes `[L]` only; frame count is unchanged in each case.
- A `SinkDispatcher` test with a stubbed redactor returning `.failed` on a manual-span timeline: the transcription runner is never called, the pipeline is never invoked, a failure sidecar with the new reason is written, and the WAV is no longer in the library directory.
- A test that a clean finish with a manual span and a failed timeline write leaves `<stem>.offrecord` in place and the job fails closed.
- Option A only: a recorder test that a system buffer arriving under `.regulatedGate` with `manualOffRecord` on is written as zeros.
- `mute_redaction_failed` gains a `reason` attribute and the quarantine logs its own action, both under the existing `recorder` / `coordinator` categories in snake_case, so `python3 scripts/truth_fences.py` (CI5) stays clean.
- `cd daemon && swift build` and `swift test` green, new test count in the commit body; `bash scripts/ci-local.sh` green.
- Owner check after install (not a precondition): rename ffmpeg away, record with one off-the-record stretch, and see the row fail with the named reason and nothing published.
