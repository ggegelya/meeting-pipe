---
id: REC22
title: Capture write failures shorter than 32 consecutive buffers are never counted, so intermittent disk errors can drop up to 15% of a meeting with no trace in any log or event
category: Recording
status: new
priority: P2
comment: Filed 2026-10-25 (observability band, O19: SW-12): failed capture writes go only to redacted os.Logger and WriteFailureTracker resets on success, so failures under 32 in a row are never counted and up to 15% of a meeting can drop below the 0.85 parity floor. Total and first error per channel in the tracker, a once-per-recording WARN, totals on the stopping line and a capture_write_failures event. [Spec](./REC22.md) Amended 2026-11-13 by the audit band: the writer backlog warn is event and log only for about 15.5 minutes before the 512 MiB force-stop, so show it on the HUD and put the backlog peak on the stopping line (F155).
---

# REC22: Capture write failures shorter than 32 consecutive buffers are never counted, so intermittent disk errors can drop up to 15% of a meeting with no trace in any log or event

Band origin: filed 2026-10-25 from the 2026-10-25 observability audit band ([audit](../../audits/2026-10-25-observability-audit.md) row O19: SW-12). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Re-verified against `main` at `01e904a` on 2026-10-25 (after ARCH8 moved the system writer into `SystemAudioChannel`). Not observed on this Mac: `recorder.log` shows two recordings at 100% duration parity and `events.jsonl` holds no `recording_error` row. The path runs on every buffer of every recording.

**Each failed write goes only to os.Logger.** The mic writer closure in `MeetingRecorder` is:

    do { try micFile.write(from: buffer); ok = true }
    catch { Log.recorder.error("mic write: \(error.localizedDescription)"); ok = false }

and `SystemAudioChannel`'s system writer is the same shape (`"system write: ..."`). `Log.recorder` is an os.Logger with default privacy, so the reason is stored as `<private>` and nothing reaches `~/Library/Logs/MeetingPipe` (the OBS1 class).

**The tracker keeps no total.** Both closures feed `MeetingRecorder.noteWriteOutcome(channel:success:)`, which folds the outcome into that channel's `WriteFailureTracker`. `WriteFailureTracker.record(success:)` resets on success (`if success { consecutiveFailures = 0; return false }`) and escalates only when `consecutiveFailures >= threshold`, `defaultThreshold = 32` (about 2.7 s of unbroken failure at the 4096-frame tap). That escalation, REC3's `recorder.recording_error` event plus force-stop, is the only failure record. A run of 31 failures, or one failure every few buffers for an hour, is never counted anywhere.

**The stop line does not say.** `MeetingRecorder.mergeIntermediates` writes `"stopping: mic_fires=... system_fires=... mic_bytes=... system_bytes=..."` to `recorder.log` with no failed-write count, and `StopSnapshot` carries only `micFires` and `systemFires`.

**The one backstop has a 15% hole.** The only other detector is REC9's duration parity check, which fires `recorder.duration_parity_low` when the WAV is shorter than `RecordingDurationParity.minimumRatio = 0.85` of wallclock. A flaky external SSD or a nearly full disk that fails a write every few buffers shortens the WAV by up to 15% with nothing recorded. The dropped buffers are not padded, so later audio on that channel shifts earlier and drifts out of sync with the other channel, which the summary then reads as a transcript with missing passages and misattributed turns.

## Scope

1. **Count in the tracker.** `WriteFailureTracker` gains `totalFailures` and a `firstFailure` (the `NSError` domain and code of the first failed write), both mutated in `record`. It stays pure and lock-free: each channel owns one tracker on its own serial writer queue, which is the ownership its doc comment already relies on. `record(success:)` takes the error (or a separate `recordFailure(_:)`) so the domain and code travel with it. Both trackers are already reset at recording start and not by a system-capture restart, so a total spans the whole recording.
2. **One WARN per channel per recording.** `record` returns an outcome rather than a bare Bool (`none`, `firstFailure`, `escalate`), so the once-per-recording decision is pure and testable. On `firstFailure`, `noteWriteOutcome` writes one `Log.writeLine("recorder", "WARN: mic writer failed a write (domain=... code=...); counting further failures")`, so the file log has the first occurrence even when it never escalates. Further failures are counted, not logged.
3. **Totals at stop.** After `drainWriters` (step 7) and before `finalizeFiles`, read both trackers' totals; add `mic_write_failures` and `system_write_failures` to the `stopping:` line, and when either is non-zero emit `recorder.capture_write_failures` with both totals and each channel's first domain and code. Read them after the drain, not in `endSession`'s snapshot: writes enqueued before stop are still landing until the drain completes. When the drain wedged, the writer queue still owns the tracker, so skip the read and log `write_failures=unknown (writer wedged)` rather than race it.
4. **Escalation unchanged.** REC3's 32-consecutive force-stop and its `recording_error` event keep their threshold and meaning.

## Explicitly not / out of scope

- Padding the gap a failed write leaves with silence to keep the channels in sync. That changes the audio, needs its own measurement of what the merge does with it, and is a recording fix rather than an observability one.
- Lowering the escalation threshold or escalating on a failure rate. A user-visible stop on a rate is a product call; the counts this task adds are what that decision would need.
- A HUD state or notification for a non-escalating failure. The `capture_write_failures` event is what OBS1's file-log rule and any later surface would key on.
- The `Log.failure` helper and the migration of the redacted `Log.recorder.error` sites (OBS1). This task adds file lines of its own and leaves the os.Logger calls for OBS1.
- The 32-bit WAV size cap that makes every write fail at about 3 h 6 min (REC19), and the free-space preflight and live low-space stop (REC20).

## Acceptance

- `WriteFailureTrackerTests`: an interleaved pattern of failures and successes that never reaches the threshold leaves `totalFailures` equal to the failure count and `hasEscalated` false; the first failure's domain and code are kept and later ones do not overwrite it; a run of 32 still escalates exactly once and the total keeps counting past it.
- `WriteFailureTrackerTests`: `record` returns `firstFailure` once per tracker lifetime and `none` for later sub-threshold failures, which is what makes the WARN once-per-recording without a `MeetingRecorder` harness (none exists for `noteWriteOutcome` today).
- A pure formatter for the `stopping:` line, or for the `capture_write_failures` attributes, is unit-tested for the zero case (no event), a non-zero case, and the wedged case.
- `cd daemon && swift build` and `swift test` green; `bash scripts/ci-local.sh daemon` green; N new tests named in the commit body.
- `CONVENTIONS.md` documents `capture_write_failures` in the event-log section's `recorder` paragraph, together with REC3's `recording_error`, which is not documented there today either; `python3 scripts/truth_fences.py` clean.

## Amendment 2026-11-13 (audit band)

From the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md), low F155 ("Writer backlog warning is log-only until 512 MiB of audio is held in RAM"), re-read in code at HEAD on 2026-11-14. It is the sibling of this task's subject: this task counts writes that throw, and REC25 (done 2026-11-12) added the watch for writes that never finish. Both end the same way, with the owner learning nothing while the recording is live.

**What the code does today.** `WriterBacklogPolicy.evaluate` runs on the two existing 1 Hz liveness ticks and answers `.warn(pendingSec:)` once per channel per recording when that channel holds more than `softThresholdSeconds = 30` of its own audio, and `.stop` once when both channels together hold more than `hardCapBytes = 512 << 20`, which its own comment puts at "about 15.5 minutes of both channels at 48 kHz" (576,000 B/s for both, so 932 s). In `MeetingRecorder`, `.warn` writes `recorder`/`writer_backlog` (`channel`, `pending_bytes`, `pending_sec`) and a `WARN: ... writer is ...s behind` line to `recorder.log`, and nothing else: no HUD state, no notification. `.stop` goes through `WriteFailureRouter.escalateBacklog` to `onWriteFailure`, REC3's force-stop that keeps the prefix that reached the disk. So between second 30 and roughly minute 15.5 of a stalled output volume the HUD shows live levels, the owner is told nothing, and the audio held in memory is what a crash or the eventual force-stop can lose. Correction at filing: the soft threshold is not silent, it already has an event and a file-log line, which is more than this task's sub-threshold write failures get today; what it lacks is an owner-facing surface. REC25's spec did not decide against one; its Explicitly not is about dropping buffers and QoS.

**This amendment lifts one line of the Explicitly not above for this one case.** "A HUD state or notification for a non-escalating failure" stays out of scope for sub-threshold write failures (a few failed writes in an hour are not worth interrupting a meeting for). A writer backlog past 30 s is different: the volume has stopped finishing writes, and the only remaining outcome is a force-stop. The owner may strike this addition at pickup and keep the backlog log-only.

### Added scope

5. **Surface the backlog warn on the HUD (F155).** On `.warn`, besides the event and the WARN line, show a HUD state through the seam REC20's low-space countdown already uses: `RecordingHUDWindow.setLowSpace` feeding `HUDStateLabel.resolve(micCaptureLost:lowSpace:offRecord:confirmingEnd:)`. Add one input (for example `writerBehind: Bool`) with alert tone, ranked below `micCaptureLost` and `lowSpace`, cleared at `dismiss` like `lowSpaceText`, and wired from the recorder to the session controller the way `lowSpaceWatch.onUpdate` is. Short copy in the HUD's register ("Disk falling behind"); no banner, since the force-stop already posts one.
6. **Say it at stop.** Add the per-channel backlog high-water mark REC25's `SerialBufferWriter` already keeps to item 3's `stopping:` line (`mic_backlog_peak_sec`, `system_backlog_peak_sec`), so a recording that warned and then recovered leaves a trace on the same line as its write-failure totals.

### Added acceptance

- The `HUDStateLabel` tests (pure; today in `RecordingLowSpaceREC20Tests`): the backlog state shows with alert tone when it is the only state, yields to `micCaptureLost` and `lowSpace`, and outranks `offRecord` and `confirmingEnd` (or the order the pickup session picks, pinned).
- Tests at the levels `RecordingLowSpaceREC20Tests` already uses for REC20's wiring: a session-level test with the fake host that a backlog warning sets the HUD state once (the shape of `test_a_warning_sets_the_label_and_notifies`, minus the notification) and a new recording clears it, plus a fit test that the new label fits the shared pill width (the shape of `test_the_longest_countdown_fits_the_pill`).
- Item 3's pure `stopping:` formatter test covers the peak-seconds fields.
- [GUIDE.md](../../../docs/GUIDE.md) gains one sentence beside its other recording-panel states ("Mic lost", "Confirming end"), in the same commit.
