---
id: MIC17
title: A mic that records speech far too quietly passes the dead-mic check, so nobody is told, and the owner's own voice becomes the hardest to transcribe and to separate
category: Recording
status: partial
priority: P2
comment: Shipped 2026-11-18 with provisional thresholds (300 s un-muted, under 5 s at or above -40 dBFS): micVeryQuiet stop tier with notification, live 30 s HUD notice (Mic very quiet, once per recording, click to dismiss), recorder/mic_very_quiet with phase, scripts/mic_level_probe.py. Owed: the owner's probe run on the work library (must fire on under 1 in 10 usual-mic meetings) to confirm or move the thresholds, and the live test call with a lowered input level.
---

# MIC17: A mic that records speech far too quietly passes the dead-mic check, so nobody is told, and the owner's own voice becomes the hardest to transcribe and to separate

Band origin: filed 2026-10-24 (go-live assessment FQ-3 and FQ-8 evidence; [DIAR6](./DIAR6.md) names this warning as observed but unfiled). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

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

## Amendment 2026-11-13 (audit band)

From the [recording-reliability audit](../../audits/2026-11-13-recording-reliability-audit.md) D053 (low, speculative, "On the built-in microphone the app judged the owner silent for two whole calls, and the dead-mic check passed them"), with the audit's field check and a re-read of the home Mac's event log while filing.

**The two October stems in the table above, seen from the event log.** In `~/Library/Logs/MeetingPipe/events.jsonl`: 20261016-095827 (`coordinator`/`recording_started` 2026-10-16T06:58:27.584Z, `bundle_id` com.apple.Safari, `recorder`/`input_device_resolved` the built-in microphone) and 20261016-122748 (09:27:48.278Z, Safari, same device). Before each start the gate's last `micgate`/`verdict_changed` was `silent_by_rms` (2026-10-15T21:01:42.977Z and 2026-10-16T07:33:29.745Z), and no `verdict_changed` row appears between `recording_started` and `lifecycle`/`ending_provisional` (07:33:10.750Z and 09:46:08.612Z), so the RMS gate stayed closed for about 34.7 and 18.3 minutes of call. The first `hot` (`rms_above_open_threshold`) came at 07:33:15.468Z and 09:46:14.390Z, about 4 s after `recorder`/`configuration_change_recovered` (07:33:11.271Z and 09:46:10.395Z), in the call's teardown. No `mic_recorded_nothing` row, as this spec already says.

**What the audit concluded, and what it did not.** It does not show `RMSGateProbe`'s defaults (`closeThresholdDb: Float = -55.0`, `openThresholdDb: Float = -45.0`) to be the defect. The real gap is `MicCoverageWarning.evaluate`'s single whole-file peak (`peakUnmutedRmsDb < floorDb ? .micRecordedNothing : .none`, floor -65): a mic sitting between about -65 and -45 dBFS passes, and so does a dead in-call stretch followed by a few loud seconds, which is what the teardown `hot` rows above look like. On the work laptop D053 does not reproduce: 0.7% of owner speech fell under `silent_by_rms`, built-in mic included, on a machine that records from the built-in mic 65 times in 71.

Correction at filing: the gate never opening is not fully explained by a quiet mic. This spec's table measures 3.6 s and 1.5 s above -45 dBFS on these two WAVs, and the gate opens on 80 ms at or above -45, so either the recorder's per-buffer RMS reads far lower than the offline 100 ms measure (the table already records a 20 dB gap on 20260707-150057), or the gate was not fed during the call and the re-arm restarted it. Scope item 7 settles which; a feeding defect would be filed on its own.

Added scope:

5. (D053) **A running tally, shown on the HUD during the call.** This replaces the "Explicitly not" bullet on a live HUD warning above. The scope-item-1 accumulator is already per-second; snapshot it to the main actor at a low cadence (every 30 s, never from the render thread) and, once the un-muted floor is passed with system audio present and the loud-seconds count still under the bar, show a one-line notice in `RecordingHUDWindow` naming the device and the System Settings fix, once per recording, dismissible. The at-stop notification stays for a call whose HUD was hidden. Same thresholds as the stop tier, so the probe still sets them before either surface ships. `recorder`/`mic_very_quiet` carries `phase` (`live` or `stop`).
6. **Which device the call used** is [MIC22](./MIC22.md)'s measurement, not this task's. The notice names the captured device (`recorder.lastInputDevice?.displayName`); if MIC22 finds the meeting app on a different input, the copy names that in its follow-up.
7. **Probe addition.** Item 4's probe also prints, for 20261016-095827 and 20261016-122748, the recorder-measure seconds at or above -45 dBFS before `ending_provisional`, so the gate-never-opened reading above is settled before thresholds are trusted.

Added acceptance:

- A pure test of the live decision: fires once at the floor with system audio and loud seconds under the bar; does not fire before the floor, without system audio, or a second time in one recording.
- A test that a dead in-call stretch followed by a few loud seconds at the end (for example 1,800 s un-muted with 4 s loud, all in the last 10 s) fires the quiet tier, where today's single-peak check passes it.
- `docs/GUIDE.md`'s recipe describes the HUD notice, in the same commit.
- [owner] After install, one short test call with the built-in mic's input level turned down in System Settings, Sound, Input, held past the un-muted floor: the HUD notice appears once and names the device. [session] confirms one `mic_very_quiet` row with `phase` `live`.

**Progress (2026-11-18):** Shipped with the spec's starting values as provisional constants on `MicCoverageWarning`. The probe (`scripts/mic_level_probe.py`, stdlib only, read-only, aggregate levels only, 85.3 ms buffers like the recorder's 4096-frame tap at 48 kHz) was run on the home Mac's five reference stems: the quiet tier fires on 20261016-095827 (2114.8 s un-muted, 1.7 s loud, peak -26.5) and 20261016-122748 (1118.6 s, 0.9 s, -30.2), not on 20260911-123613 (185.1 s loud) or 20260911-124913 (67.9 s un-muted, under the floor). **The -74.9 dB gap is explained, and it is a finding about MIC15:** -74.9 is 20260707-150057's whole-file RMS (the probe prints it, `file_rms_db`), not a buffer peak; its loudest 85 ms buffer is -51.3 dB. So by the recorder's measure (loudest un-muted buffer under -65) MIC15's dead tier would likely not have fired on its own trigger recording, and at 269.7 s un-muted this quiet tier's 300 s floor misses it too. The dead tier is unchanged, as this spec requires; whether its -65 floor should move is a follow-up for the owner. **Item 7 settled for these two stems:** on the probe's measure the mic spent 0.1 s and 0.0 s at or above -45 dBFS before `ending_provisional`, so the gate never opening in call reads as the level, not a feeding defect (the loud seconds come after the teardown, as D053 described). Code: the tally moved into the recorder's per-buffer `GateAccess` lock as a `MicCoverageTally` (no second lock, no allocation), read at stop and every 30 s on main via `liveMicCoverage`; `MicQuietLiveCheck` fires once per recording; the HUD's state label shows `Mic very quiet` (below the loss states, above off-record) with the device and fix in its tooltip and a click to dismiss; the stop notification always posts when the tier fires. Tests: 22 (17 in `MicVeryQuietMIC17Tests`, including a click on a presented HUD's label; 5 in `MicVeryQuietSessionMIC17Tests`, including a real start that must arm the check and a real stop that must post the notification and a `phase: stop` row, both shown red with the wiring removed). **Decision outside the spec:** the live notice is the HUD's existing state label (`Mic very quiet`, the slot `Disk falling behind` and `Mic lost` use), with the device and the System Settings fix in its tooltip and accessibility help, not a new one-line row; a sentence does not fit the pill and a new row is a geometry change. The owner's acceptance step ("the HUD notice appears once and names the device") therefore reads the device on hover. The label also comes down by itself on the next tick once the tally is no longer quiet, so it never outlives the fix; it does not come back in that recording. The probe replays the live check too (`live_notice_s`, every 30 s of recording, assuming the far side was live), so the work-library run answers for both surfaces: on 20261016-122748 it would have shown at 300 s.
