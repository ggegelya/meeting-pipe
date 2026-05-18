# ADR 0002: ASR engine path, sherpa-onnx then FluidAudio

| Property            | Value              |
| ------------------- | ------------------ |
| **Status**          | Accepted           |
| **Date**            | 2026-05-18         |
| **Decision Makers** | Project owner      |
| **Technical Area**  | Transcription      |
| **Related Tasks**   | TECH-P0, TECH-P1, TECH-P2, TECH-P3 |

## Context

The pipeline needs offline, on-device ASR plus speaker diarization for
arbitrary-length meetings on Apple Silicon. The initial implementation
chose sherpa-onnx for diarization paired with MLX-Whisper and
faster-whisper for ASR, both invoked from the Python sidecar. Group P of
the Q2 backlog re-evaluated that stack against a Swift-native,
ANE-accelerated option (FluidAudio with Parakeet-TDT and
pyannote-Community-1).

## Decision Drivers

- **On-device, no network.** Outbound HTTP for transcription is
  unacceptable; the daemon-stays-offline rule (`CLAUDE.md`) forbids it
  for the daemon, and the pipeline-side rule of "no audio leaves the
  Mac" still applies.
- **ANE residency.** The user's Apple Silicon Mac has the Neural Engine;
  burning the CPU when the ANE is idle is wasteful and noisier.
- **Latency under 1.5x recording duration.** The transcription bar in
  the Q2 backlog requires this for daily use.
- **Quality bar: WER under 8% on the user's own voice; under 12% on
  typical interlocutors.** Measured against a hand-corrected reference
  set (TECH-P0).
- **Single language path.** The user runs multilingual meetings;
  English-only engines (Parakeet v2) do not meet the bar.

## Options Considered

### Option A: sherpa-onnx diarization + MLX-Whisper / faster-whisper ASR

This was the shipped path for Phase 0. Pros: known-good quality from
WhisperX-class models; Python ecosystem is well documented for both
runners. Cons: Python sidecar overhead (cold-launch time, venv size),
GPU/CPU mix is not ANE-resident, two ASR engines means two failure
modes.

### Option B: WhisperKit (Apple Silicon Whisper port)

Pros: actively maintained; Swift-native. Cons: as of Q2 evaluation,
multilingual quality on the user's interlocutor languages was not
measured to clear the bar in TECH-P0's fixture set, and diarization is
not bundled.

### Option C: FluidAudio (Parakeet-TDT-0.6B-v3 + pyannote-Community-1)

Pros: Swift package; one runner for ASR plus diarization; ANE-resident
on Apple Silicon; Parakeet v3 added multilingual support that v2 lacked.
Cons: a newer SDK with less production track record; depends on Parakeet
v3 clearing the WER bar on the user's languages (TECH-P0 gate).

## Decision

**Phase 0 ships Option A. Phase 1 migrates to Option C** once TECH-P0
clears the quality bar on the user's languages.

The rationale for not staying on Option A: every additional code path in
the Python sidecar (streaming subprocess, offline ASR, sidecar JSON
assembly) is a maintenance cost that the personal-use app cannot
amortize. Consolidating onto a single Swift-native runner shrinks the
shipped surface and removes the launch-time tax of importing torch +
whisperx + sherpa-onnx.

The rationale for the staged migration rather than a direct jump: the
benchmark fixture (TECH-P0) is the gate. If Parakeet quality regresses
on the user's interlocutor mix, Option A is the fallback and the
migration stalls without shipping a worse experience.

## Consequences

- TECH-P1 brings FluidAudio in behind a build flag. TECH-P2 retires
  WhisperX. TECH-P3 retires sherpa-onnx. TECH-P4 decides whether the
  Python sidecar survives for orchestration (resolved separately in
  ADR 0007).
- Sidecar JSON schema does not change for the library; the runner
  swap is transparent to library code.
- `events.jsonl` `transcription.engine` field changes from `whisperx`
  to `fluidaudio` for new recordings. Older recordings keep their
  original engine tag.
- A FluidAudio regression after WhisperX retirement has no automatic
  fallback. The trigger to restore one is a single failed dogfood
  fortnight.
