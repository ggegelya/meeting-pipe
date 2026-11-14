---
id: MIC22
title: The recorder captures the system default input, not the microphone the meeting app opened, and nothing records which device the call used
category: Recording
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). MeetingRecorder records AVAudioEngine.inputNode (the system default) and logs only input_device_resolved; MIC15's mismatch nudge never changes the device and fired once in 74 starts (2026-11-05T15:57:01Z, Bluetooth). Consistent with MIC17's faint owner channel but unproven. Measure first: log the input devices the meeting client's process objects hold (kAudioProcessPropertyDevices) beside the captured device at every start and device change; capture the client's device only if mismatches are real.
---

# MIC22: the recorder captures the system default input, not the microphone the meeting app opened

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

**Sources.** [Recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md) D054 (medium, consistent but unproven, code derived) and its [evidence](../../audits/2026-11-13-recording-reliability-evidence.md) timeline row for 20261105-175701; [field evidence](../../audits/2026-11-13-field-evidence.md) metrics row "Input device at start".

**The code, re-verified at HEAD on 2026-11-13.** `MeetingRecorder` captures "Mic via AVAudioEngine.inputNode" and taps it with `engine.inputNode.installTap(onBus: 0, ...)`; macOS binds `inputNode` to the System Settings default input. After resolving it, the recorder logs `recorder` `input_device_resolved` with `InputDeviceIdentity.eventAttributes` (name, transport, sample rate). Before the engine arms, `MeetingSessionController.beginRecording` runs MIC15's nudge, `if InputDeviceResolver.defaultInputIsMismatched()`, which notifies and logs `input_device_mismatch_warned` when the default input is idle while another input device is running; its own comment says "Never a gate: we still record what we captured". MIC15 is done and archived in [q6-final.md](../q6-final.md).

**Field evidence (work laptop, 74 recordings, 2026-09-29 to 2026-11-13).** Input at start: built-in 48 kHz on 68, Bluetooth 48 kHz on 6 (2026-11-04 to 2026-11-06). `input_device_mismatch_warned` fired once, at 2026-11-05T15:57:01Z before 20261105-175701, with the recorder on a Bluetooth input. recorder.log shows 11 mid-recording input changes in the window. No row anywhere says which device the meeting client itself had open, so whether the owner's channel ever recorded the wrong mic cannot be answered from the log. A faint owner channel ([MIC17](./MIC17.md)) is what a wrong device would look like, but MIC17 has its own explanation (a quiet built-in mic), so D054 stays unproven.

Correction at filing: two premises are narrower than stated. (1) There is no `MicHolderMonitor` at HEAD; it is proposed in shadow by [DET23](./DET23.md), filed in the same band. The per-process HAL objects are resolved today by `ProcessAudioSignal` and `ProcessAudioScanProbe` (enumerating `kAudioHardwarePropertyProcessObjectList`), which read only `kAudioProcessPropertyIsRunningInput`. (2) `InputDeviceIdentity`'s header says "there is no macOS API to read the input device the meeting client itself chose", but the SDK's `AudioHardware.h` defines `kAudioProcessPropertyDevices`, "the devices currently used by the process for input" when read in the input scope. So the measurement below needs no new mechanism, only a second property read on objects the daemon already resolves. Whether it reports correctly for the Teams SlimCore helper is what leg 1 finds out.

## Scope

1. **Leg 1, measure.** At every recording start (after `input_device_resolved`) and at every mid-recording input change (the recorder's configuration-change handler), read `kAudioProcessPropertyDevices` in the input scope on the meeting client's resolved process objects (the `ProcessAudioSignal` resolution, or DET23's monitor once it exists) and emit one `recorder` `input_device_holder_compared` row: the holder's device names and transports, the captured device, and `match` (true, false, or unknown when the read failed or the list was empty). The comparison is a pure function beside `InputDeviceIdentity.shouldWarnMismatch`, behind injectable seams like `defaultInputIsMismatched`. Fix the stale header sentence in `InputDeviceIdentity` in the same commit.
2. **Leg 2, only if leg 1 finds mismatches.** If a week of rows shows at least one start or change where the holder's device differs from the captured one during a real call, capture the holder's device (bind the engine's input to it) and re-resolve when the holder switches. Leg 2 is scoped from leg 1's rows, in this task, and needs the owner's go-ahead since it changes what is recorded.

## Explicitly not

- Changing MIC15's nudge or its notification copy before leg 1 has numbers.
- A device picker in Preferences: the point is to follow the call, not to add a setting.
- The engine's own recovery after a device change: [REC15](./REC15.md) and [REC16](./REC16.md). Naming the device in the mic-change log line: [OBS5](./OBS5.md).

## Acceptance

- Leg 1: unit tests of the comparison on a fake backend: holder on the captured device (match), holder on a different device (mismatch), holder listing two input devices one of which is captured (match), empty or failed read (unknown). A host test that a start and a simulated input change each emit one `input_device_holder_compared` row. The new action documented in `CONVENTIONS.md`'s event-log schema; `swift test` and `bash scripts/ci-local.sh` green, with the number of tests added in the commit body.
- After a week on the landed build: the count of starts and changes with `match` false, true and unknown, by transport, written into this file, with a GO or NO-GO for leg 2 (GO on at least one `match` false inside a real call).
- Leg 2, if GO: a test that the engine binds to the holder's device and follows a holder switch, and the recorder's existing device-change tests stay green.

## Owner walkthrough

1. [session] Confirm the installed build is newer than leg 1's landing commit.
2. [owner] Work normally for a week; on at least one call, switch the meeting app's microphone (for example to a headset) without changing the system default. Cost: one switch.
3. [session] Count the `input_device_holder_compared` rows and write the leg 2 verdict into this file.
