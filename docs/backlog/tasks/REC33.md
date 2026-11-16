---
id: REC33
title: The system channel's head offset is stamped at the first callback, so the merge appears to over-delay the far side by 1.3 to 2.6 s
category: Recording
status: partial
priority: P2
comment: Measurement shipped 2026-11-17 (intermediate_durations.system_capture_lag_sec), merge unchanged by the owner's choice to measure first. Remainder: a work-laptop recording with a delay above 1 s logs the lag, then a one-line flip of the merge to the capture stamp behind the same test.
---

# REC33: The system channel's head offset is stamped at the first callback, so the merge appears to over-delay the far side by 1.3 to 2.6 s

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source finding: "System head offset appears to over-delay the far side by 1.3 to 2.6 s in 8 recordings" in [2026-11-13-field-evidence.md](../../audits/2026-11-13-field-evidence.md) (section "Mic, mute and capture health", low, new defect). The pack has no audio, so this is inferred from three logged durations per recording (`recorder`/`intermediate_durations`), not heard or cross-correlated.

**The field shape.** 28 of 74 recordings had `head_offset_sec` at or above `RecordingPostProcessor.systemHeadOffsetFloorSec` (1.0 s), so the merge prepended that much silence to the system leg (28 `system_delay` lines above zero in `recorder.log`). In 8 of those 28, head offset plus system audio exceeds mic audio by 1.26 to 2.59 s, although the mic is not short and the system stream is halted before the mic at stop: `20261016-163013` offset 3.03 s, excess 2.59 s; `20261014-123248` 3.12 s, 2.44 s; `20261021-103054` 17.38 s, 2.50 s. Among the 46 undelayed recordings the only excesses past 1 s are the three mic re-arm recordings, where the mic is the short side. By era: 3 before 2026-10-12, 5 between, 0 after 2026-11-12 (all six era 3 offsets are 0.4 s or less, so the delay never applied). If the shape is real, every delayed recording's far side lands up to 2.6 s late against the owner's mic, which skews turn order and diarization at every exchange.

**The code** (re-verified at HEAD `3a2da4fc` on 2026-11-13):

- `SystemAudioChannel.startSystemCapture`'s buffer closure stamps `if self.systemFirstFrameUptime == 0 { self.systemFirstFrameUptime = ProcessInfo.processInfo.systemUptime }` when the first buffer reaches it.
- `SystemAudioCapture.stream(_:didOutputSampleBuffer:of:)` converts the `CMSampleBuffer` with `pcmBuffer(from:)` and passes only the PCM on; the buffer's presentation timestamp is dropped.
- `MeetingRecorder.endSession` computes `systemHeadOffsetSec: firstFrame > 0 ? max(0, firstFrame - startedAtUptime) : 0`, and `RecordingPostProcessor.mergeLengths` turns an offset at or above 1.0 s into `adelay` on the system chain in `mergeToTempViaFFmpeg`.

So an SCStream whose first callback delivers audio captured some time before the callback runs is placed too late by exactly that much, and the system leg then reaches past the mic by the same amount, which is the excess the field shows.

**A second anchor biases the other way.** `startedAtUptime` is stamped in `MeetingRecorder.start` after the mic engine has started and after `systemChannel.start(systemURL:)` is called, so the mic file holds a little audio from before the anchor. That makes the computed offset smaller than the true one (under-delay), so it cannot explain the excess, but it is part of the same measurement and the verification below should read both anchors.

Related: [REC30](./REC30.md) (filed in this band) adds per-channel first and last buffer uptimes and keeps its notice threshold above this suspected overstatement; [REC16](./REC16.md) owns the mic gap pad; REC9 and [REC14](./REC14.md) own the length policy, which is not faulted.

## Scope

1. **Verify first.** On one affected recording (owner walkthrough step 1), measure the true lag between the far side's bleed into the mic (left channel of the 16 kHz stereo final) and the system channel (right), by cross-correlating a stretch of far-side speech in the first minutes. If the system channel lags the bleed by about the excess the logs predict, the defect is confirmed; if it does not, close this task with the measurement and leave the code alone.
2. **If confirmed, stamp the offset from capture time.** Pass the first `CMSampleBuffer`'s presentation timestamp from `SystemAudioCapture.stream(_:didOutputSampleBuffer:of:)` alongside the PCM, convert it to the `systemUptime` timebase (the host clock both are measured on), and stamp `systemFirstFrameUptime` from it rather than from the callback's `systemUptime`. If the timestamp is unusable (invalid or not on the host clock), fall back to the callback stamp minus the frames already in that first buffer, and log which path was taken once per recording.
3. **Anchor the mic the same way if step 1 shows the under-delay matters.** Stamp the mic's first tap buffer time (its `AVAudioTime` host time) and compute the offset between first buffers rather than against `startedAtUptime`. Only if the measurement shows a material lag; otherwise leave the anchor and say so.

## Explicitly not

- Changing the 1.0 s floor or the REC9 length policy.
- Re-aligning existing recordings. A re-merge needs the intermediates, which are deleted after a verified merge.
- The channel coverage check and the stop notice: [REC30](./REC30.md).
- Fixing this without step 1. The pack's evidence is three durations per recording, and a wrong fix shifts every recording's far side.

## Acceptance

- Step 1's measurement (stem, the logged offset and excess, the measured lag, the method) recorded in this file before any code change, and the pickup's verdict stated.
- If confirmed: a recorder test with a fake system channel whose first buffer carries a presentation timestamp 2 s before its delivery: `systemHeadOffsetSec` reflects the capture time, not the delivery time, and `mergeLengths` gets the corrected delay; a buffer with an invalid timestamp takes the fallback and logs it; a pure test of the host-time conversion.
- If item 3 is taken: a test that the offset is computed between the two channels' first buffers.
- `cd daemon && swift build` and `swift test` green, with the number of new tests in the commit body; `bash scripts/ci-local.sh` green.

## Owner walkthrough

1. [owner] On the work laptop, find whether one of `20261016-163013`, `20261014-123248` or `20261021-103054` (or any recording with a `system_delay` above 1 s) still has its final WAV and was taken on speakers rather than headphones, so the far side bled into the mic. Hand that file, or the first five minutes of it, to a session. Cost: a few minutes; no meeting content needs to be read, only the waveform lag.
2. [session] Cross-correlate left against right over a stretch of far-side speech, report the lag against the logged excess, and record the verdict in this file.
3. [owner] If no affected recording is left, after a build with REC30's per-channel stamps: one call on speakers with a system delay above 1 s, then step 2 on it.

## Progress (2026-11-17)

**Step 1 could not run here.** This Mac's library has three recordings, all with `head_offset_sec` under 0.2 s, so no merge delay applied and none of the named stems is present; they are on the work laptop.

**Shipped instead, no behaviour change:** a measurement that makes step 1 unnecessary on the next affected recording. `SystemAudioCapture` now passes each buffer's capture time with its PCM (`SystemCaptureClock.captureUptime`, the SCStream presentation timestamp on the host clock that `ProcessInfo.systemUptime` also reads), the channel records the first frame's capture-to-delivery lag once per file open (`SystemCaptureClock.lag`, nil when the timestamp is invalid or implausible), and `recorder`/`intermediate_durations` logs it as `system_capture_lag_sec` beside `head_offset_sec`. The head offset, and so the merge, still keys off delivery, pinned by a source test so the flip is a deliberate one-line change. 5 new tests (the conversion, the invalid cases, a 2 s lag, the plausibility bounds, the unchanged merge anchor); REC28's delivery fence was updated for the new callback shape.

**Owner decision (2026-11-17): option (1), measure first.** The logging-only change above is what ships; the merge is unchanged.

**Remainder:** a recording on the work laptop with `head_offset_sec` above 1 s logs `system_capture_lag_sec`. If the lag matches the 1.3 to 2.6 s excess the field showed, a session makes the one-line flip of the head offset to the capture stamp (`systemFirstFrameUptime - lag`) and updates `test_the_lag_is_logged_and_the_merge_offset_is_unchanged` to pin the new anchor; if it does not, this task closes on the measurement with the code left alone. Item 3 (the mic anchor) waits on the same measurement.
