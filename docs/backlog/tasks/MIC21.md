---
id: MIC21
title: HAL voice activity is never available, so the VAD-gated idle backstop and both VAD heuristics are a raw level gate, and no row says which speech evidence a recording had
category: Recording
status: partial
priority: P2
comment: Shipped 2026-11-17 - FloorSpeechDetector (floor margin or level modulation for voice; a separate held stationary reading) feeds MicGate's VAD input where HAL VAD is unsupported (speech_detected; rms_stationary_noise keeps audio and counts quiet in IdleStopBackstop), never currentVadActive; one micgate speech_evidence row per recording at the stop; IdleStopBackstop header corrected. Remaining - the owner's week read of each source's share, and a check of rms_stationary_noise time inside live calls.
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

**Progress (2026-11-17):** items 1 to 3 shipped; the field week's share report is owed.

- `FloorSpeechDetector` (`MicGate/Probes/`), allocation-free on the tap thread, fed the level `MicGate.ingest(rmsDb:)` already gets. **Voice** on either of two pieces of evidence held 120 ms: the level 10 dB over a noise floor that drops at once and rises 3 dB/s, or a smoothed buffer-to-buffer step of at least 1.5 dB; both need the level over -65 dBFS; voice ends after 600 ms of neither. **Stationary**, a separate reading: the smoothed step under 0.6 dB, the level within the floor margin and no voice, held 30 s. The modulation evidence and the separate stationary reading were not in the spec; both came from testing the backstop in the expensive direction (and from the independent review).
- Spec conflict resolved toward the safe side (advisor-reviewed): acceptance 2's bed at -40 dBFS sits above the RMS gate's -45 open threshold, so a VAD input alone could not make it read silent, and making it non-hot would zero the mic under the regulated gate on the detector's word. `decide` keeps that cell hot with a new reason, `rms_stationary_noise`, only when the detector holds the level stationary (not merely "no voice"), and `IdleStopBackstop` counts that reason as quiet, as it does `confidently_unmuted`. The detector can therefore only add hot time or relabel; pinned over every combination of the old inputs, with `decide` unchanged whenever the detector is absent and ignored whenever HAL VAD reports.
- `currentVadActive` stays HAL-only (decision beyond the spec's "both VAD heuristics"): it feeds MIC10's muted-but-speaking contradiction, which clears the app mute in a capture-first mode, and under `.captureFirstRedact` a level detector firing on far-side bleed through laptop speakers would leave muted asides un-redacted. The review caught the first version doing exactly that.
- `MicGate` caches HAL VAD support under its lock from the probe's `onSupportChange` (the tap thread never calls the probe's queue-sync getter), starts from a state with the detector feeding (`detectedVoice: false`), so a bed present from the first buffer still reaches `decide`, and writes `State.detectedVoice` and `detectedStationary` only while HAL is unsupported.
- `speech_evidence`: `SpeechEvidenceLedger` (pure) on MicGate's publish queue, begun at `recording_started` and emitted in `stopRecording` before `micGate.stop()`, scoped to the recording, not to the gate's start; one row per committed recording stopped through `stopRecording` (an uncommitted start and a quit write none). `State.axMuteSource` names the oracle behind a mute. Change times are read on the calling thread; concurrent updates can reach the ledger slightly out of order (the same ordering MIC23 names), and a system sleep is credited to whichever source held the verdict.
- Limits, stated in the detector's header: at a 256 ms (Bluetooth) buffer a 3 dB talker who never breathes is called stationary; the synthetic talkers that do pause read voice throughout, so the stationary margins are set from the bed's side and are not pinned red against a talker. The owner's week should check `rms_stationary_noise` time inside live calls.
- Tests: 14 in `FloorSpeechDetectorTests` (the detector both ways at the 85 ms and 256 ms cadences with power-averaged syllable envelopes, a bed from the first buffer, `decide`'s invariants against the verbatim pre-MIC21 rule, and the real `IdleStopBackstop` on a mic-only recording: a stationary bed reaches the auto-stop, red before this change; far-field talkers 3 and 6 dB deep, a monologue and quiet speech never do), 4 in `SpeechEvidenceTests` (through `MicGate`: quiet speech hot with HAL unsupported and `currentVadActive` still false, the detector standing down when HAL supports VAD, one row naming the detector; the ledger's arithmetic), 2 in `SpeechEvidenceSessionTests` (one row per stop through the real controller, for an app's recording and for one with no source; neither engages the gate). `FakeSessionHost`'s gate now logs to `micGateLog`.
