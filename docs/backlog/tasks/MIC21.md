---
id: MIC21
title: HAL voice activity is never available, so the VAD-gated idle backstop and both VAD heuristics are a raw level gate, and no row says which speech evidence a recording had
category: Recording
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). vad_unsupported on 70 of 70 MicGate starts in all three build eras, 0 vad_state rows: HALVoiceActivityProbe only reads the enable bit (writing it is a documented HAL hazard), so every hot verdict is the -45 dBFS RMS gate or the unmuted floor. A speech detector on the daemon's own mic samples feeding MicGate's VAD input, and one speech_evidence row per recording naming which evidence was live.
---

# MIC21: HAL voice activity is never available, so the VAD-gated idle backstop and both VAD heuristics are a raw level gate

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

**Sources.** [Recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md) and its [evidence](../../audits/2026-11-13-recording-reliability-evidence.md) D055; [field evidence](../../audits/2026-11-13-field-evidence.md) "Two of the gate's inputs never spoke on this Mac".

**The code, re-verified at HEAD on 2026-11-13.** `HALVoiceActivityProbe.start()` asks `enableProbe(device)` (the default reads `kAudioDevicePropertyVoiceActivityDetectionEnable`) and, when it reads off, emits `vad_unsupported`, sets `_support = .unsupported` and returns without subscribing. It never writes the bit, deliberately: its header says writing it "forces the device into voice-processing mode", which on a combined Bluetooth or USB headset silently drops system audio output, the same HAL corruption class `MeetingRecorder` documents for the VPIO unit. With no VAD input, `MicGate.decide` reaches hot only through `state.rmsState == .open` (the `RMSGateProbe` opens at -45 dBFS for 80 ms and closes at -55 dBFS after 350 ms) or the confidently-unmuted floor; its `.uncertain` reasons list `hal_vad_unsupported`. `IdleStopBackstop`'s header still says it is "gated on the MicGate verdict (which already fuses HAL VAD + RMS)", which is not true on this hardware.

**Field evidence (work laptop, 2026-09-29 to 2026-11-13).** `vad_unsupported` at 70 of 70 MicGate starts (23, 41 and 6 by build era), on the built-in mic and on the Bluetooth input used 2026-11-04 to 2026-11-06, for Teams, Zoom and Chrome; 0 `vad_state` rows and 0 `mute_state_cleared_vad_contradiction` rows. `system_mute_state` read muted false on 76 of 76. Hot Teams time was `rms` 47 percent and `confidently_unmuted` 15 percent. So the muted-but-speaking rescue (MIC10's VAD contradiction, audit F035 under [MIC19](./MIC19.md)) and F037 never ran here, and 1,294 s of owner speech under a wrong `muted_by_app` had nothing to contradict it ([MIC24](./MIC24.md) owns that inversion).

Correction at filing: the audit's owner-visible claims (a forgotten recording in a noisy room never reaching the 15 minute auto-stop; a quiet speaker treated as silent) are code-derived only; the pack has no case of either, which is why D055 is low. The probe's refusal to write the enable bit is a documented safety choice, not an oversight, so the fix is to stop depending on that property rather than to set it.

## Scope

1. **Say which speech evidence was live.** At every recording stop, emit one `micgate` `speech_evidence` row: for each of app mute from AX, app mute from the log, HAL VAD, the RMS gate and the new detector (item 2), whether it was available and the seconds it held the verdict. Emitted from the stop path in `MeetingSessionController.stopRecording` before `coordinator.micGate.stop()` resets state; the counters live in `MicGate`.
2. **A speech detector on the daemon's own samples.** A floor-relative detector in `daemon/Sources/MeetingPipeCore/MicGate/Probes/`, fed by the same per-buffer level `MicGate.ingest(rmsDb:)` already receives, allocation-free on the tap thread like `RMSGateProbe`: it tracks a slow noise floor and reports voice when the level rises a set margin above it with speech-like onsets. It feeds the VAD input of `MicGate.State` when `HALVoiceActivityProbe.support` is `.unsupported`; HAL VAD wins when the OS has it on. Thresholds come from the tests below, not from tuning against one recording. A model-based detector (FluidAudio is already a dependency) is the fallback only if the floor-relative one fails the acceptance, and only after asking the owner, since it moves model inference into the capture path.
3. **Keep `vad_unsupported` as a probe row**, and correct `IdleStopBackstop`'s header to say what it is actually gated on.

## Explicitly not

- Writing `kAudioDevicePropertyVoiceActivityDetectionEnable`: the documented HAL hazard above.
- Changing the RMS gate's thresholds, or warning on a quiet mic: [MIC17](./MIC17.md). The idle backstop's ceiling: [END25](./END25.md). MicGate's verdict carried across sessions: [MIC23](./MIC23.md).
- Owner talk share for routing: [AI15](./AI15.md) (P3) can read item 1's row later, and that is all.

## Acceptance

- A `MicGate` unit test where a speech-shaped signal at about -50 dBFS over a -70 dBFS floor (below the -45 dBFS open threshold) reads hot under the new detector with HAL VAD unsupported.
- A test where a stationary noise bed at about -40 dBFS is absorbed into the floor and reads silent after the adaptation window, so `IdleStopBackstop`'s streak advances; and a test where HAL VAD supported still takes precedence.
- A test that every stop emits exactly one `speech_evidence` row with the five sources, including a recording with no source (the manual path).
- `MicGate`, `RMSGateProbe`, `HALVoiceActivityProbe` and `IdleStopBackstop` suites stay green; the new action documented in `CONVENTIONS.md`'s event-log schema; `swift test` and `bash scripts/ci-local.sh` green, with the number of tests added in the commit body.
- After a week on the landed build, the share of recorded time each source held the verdict, from the `speech_evidence` rows, reported in this file.
