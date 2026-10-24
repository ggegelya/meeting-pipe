# MIC17: A mic that records speech far too quietly passes the dead-mic check, so nobody is told, and the owner's own voice becomes the hardest to transcribe and to separate

Band origin: filed 2026-10-24 (go-live assessment FQ-3 and FQ-8 evidence; [DIAR6](./DIAR6.md) names this warning as observed but unfiled). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## What is wrong

MIC15(b)'s `MicCoverageWarning.evaluate` fires `.micRecordedNothing` only when the loudest un-muted per-buffer RMS (`MicCoverageSnapshot.peakUnmutedRmsDb`) stays under `plausibleSpeechFloorDb = -65`. That answers "did the mic ever carry anything", not "did it carry speech at a usable level". A mic that records the owner at a whisper, with one cough above -65 dBFS, passes.

Measured 2026-10-24 on this Mac's recordings in `~/Documents/Meetings/raw`: the final WAV's left (mic) channel cut into 100 ms buffers, RMS per buffer, exact-zero buffers dropped as muted or redacted. Aggregate levels only; no audio was listened to.

| Stem | Mic (`mic_device_name`) | Length | Mic peak | Seconds above -40 dBFS | Seconds above -45 dBFS |
|---|---|---|---|---|---|
| 20260911-123613 | AirPods Pro | 7.9 min | -10.0 | 186.9 | 194.3 |
| 20260911-124913 | AirPods Pro | 20.3 min, 1.1 min non-zero | -9.1 | 12.1 | 13.4 |
| 20261016-095827 | MacBook Pro Microphone | 35.3 min | -26.2 | 1.5 | 3.6 |
| 20261016-122748 | MacBook Pro Microphone | 18.7 min | -30.0 | 0.9 | 1.5 |
| 20260707-150057 (MIC15's dead-mic case) | not recorded (pre-MIC15) | 4.5 min | -52.0 | 0.0 | 0.0 |

Both October recordings peak far above -65, so MIC15 stayed silent, and this Mac's `events.jsonl` (which starts 2026-10-12 and holds three recordings) has no `mic_recorded_nothing` event. The go-live assessment measured the owner's own diarized segments in October at a median of about -61 dBFS against about -20 dBFS in September, and found 30 and 39 percent of the owner's cluster duration in the two October meetings was system-channel speech, against 0 percent in September. The mechanism is DIAR6's (an unnormalized mixdown); the missing piece here is that nothing told the owner their mic was the problem. The cause on this Mac is plain from the table: September used AirPods, October the built-in microphone.

The table's measure is not the recorder's. MIC15 recorded a -74.9 dB peak on 20260707-150057, where this script reads -52.0, so thresholds must be set on the recorder's own per-buffer RMS, not on these numbers.

## Scope

A second tier in `MicCoverageWarning`, evaluated only when `.micRecordedNothing` does not fire.

1. **Recorder tally.** Beside `micPeakUnmutedDb` in `MeetingRecorder`, count un-muted seconds whose per-buffer RMS clears a speech-level threshold, from the RMS the gate already computes, allocation-free on the render thread like the existing tally. Carry it in `MicCoverageSnapshot`.
2. **Evaluate.** New case `.micVeryQuiet`. Fires when system audio was present the whole call, the recording clears the existing 60 s floor, the un-muted span clears a longer floor (so a short call where the owner said little does not warn), and the loud un-muted seconds stay under a small count. Starting values: 300 s un-muted, fewer than 5 s above -40 dBFS. These are constants beside the existing three, and the measurement below sets them, not this spec.
3. **Surface.** A Notifier alert that names the device, which `recorder.lastInputDevice?.displayName` already holds at stop, and says plainly what to do: check the input level under System Settings, Sound, Input, or pick another input. Phrase it so a meeting where the owner barely spoke reads as possible ("If you spoke in this meeting, ..."). Emit `recorder`/`mic_very_quiet` with `mic_recorded_nothing`'s attributes plus the loud-seconds count. `recorder` is an existing category, so `CONVENTIONS.md` needs no edit (the REC7 precedent).
4. **Probe.** A small read-only, aggregate-only script under `scripts/` that prints, per stem, the mic device and the tier's inputs computed the way the recorder computes them. It must reproduce MIC15's -74.9 dB on 20260707-150057, or explain the gap, before either measure is trusted. The owner runs it on the work laptop's library.

## Explicitly not

- DIAR6's per-channel gain normalization before the mixdown. That fixes the mechanism; this task only tells the user.
- Changing MIC15's -65 dB dead-mic tier or its copy.
- A `mic_quiet` sidecar key and Library pill. That needs a `schema_version` bump and the CI2 fixtures regenerated; file it as a follow-up if the notification proves useful.
- A live warning during the call on the HUD. More useful, since the owner could fix the mic mid-meeting, but it is a different surface; observed, not filed.
- Raising input gain automatically. The macOS input volume is the user's setting.

## Acceptance

- `MicCoverageWarningTests`: the quiet tier fires with a long un-muted span, live system audio and loud seconds under the bar; it does not fire when the dead tier fires (dead wins), under the un-muted floor, with system audio missing, or at the threshold boundary.
- A tally test feeding buffers at known RMS through the accumulator (or a pure helper it calls) counts loud seconds correctly.
- Thresholds land only on measurement, recorded in the commit body. On this Mac's five stems the quiet tier fires on 20261016-095827 and 20261016-122748 and not on 20260911-123613 or 20260911-124913, and the dead tier is unchanged on 20260707-150057. On the owner's work library it fires on fewer than 1 in 10 of the meetings recorded with the owner's usual mic.
- `README.md`'s "my voice is missing" troubleshooting entry and the matching `docs/GUIDE.md` recipe updated in the same commit.
- `python3 scripts/truth_fences.py events` and `bash scripts/ci-local.sh` green, with the number of new tests in the commit body.
