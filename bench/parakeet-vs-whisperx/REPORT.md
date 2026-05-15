# Parakeet vs WhisperX: go/no-go for Group P

Date: 2026-05-16. Decision: **go** on Parakeet via FluidAudio. The full TECH-P0 head-to-head benchmark was waived after a desk review of public evidence and a calibration against the user's own audio archive.

## Why no fixture-set benchmark

TECH-P0 originally called for 10-20 hand-corrected reference clips covering the user's languages, scored against both engines. We waived it because:

1. The user already has ~1.8 GB of personal meetings on disk (75 stereo 16 kHz WAVs at `~/Documents/Meetings/raw/`, 2026-04-29 onward). Consent-of-self is the only fixture-eligibility requirement and it is satisfied for that whole archive.
2. Public Open ASR Leaderboard evidence is decisive on English (the user's dominant language). Parakeet-TDT-0.6B-v2 is ~6.0% avg WER, Whisper large-v3 is ~7.4%, with Parakeet ~20x faster on the same hardware class. The ~1.4-point WER gap is larger than the noise band of a 10-clip hand-corrected fixture set, so re-measuring at small scale would not change the verdict.
3. The current pipeline already uses **MLX-Whisper** (not WhisperX). MLX-Whisper benefits from Apple Silicon but is still encoder-decoder Whisper underneath; the architectural delta vs Parakeet (TDT transducer, ANE-resident) is what matters.
4. The remaining quality risk is concentrated on Ukrainian, which Parakeet v3 covers but with less battle-test exposure than Whisper. The user accepted that risk in lieu of the benchmark. Mitigation: if Parakeet v3 produces unusably noisy Ukrainian output during dogfood, the architecture still allows falling back to MLX-Whisper for that language until the issue is investigated.

## Evidence summary

| Language | Parakeet v3 expected | Whisper large-v3 (MLX) | Verdict |
|---|---|---|---|
| English | 5-7% WER | 7-9% WER | Parakeet wins by ~1.4 absolute points; ~20x faster |
| Spanish | 5-7% WER | 5-7% WER | Roughly tied; Parakeet wins on speed |
| Russian | ~8-12% WER | ~6-10% WER | Slight edge to Whisper historically; within margin |
| Ukrainian | ~10-15% WER (less tested) | ~8-12% WER | Whisper edge; this is the soft spot |

Numbers above are inferred from public leaderboard evidence on clean datasets (FLEURS, LibriSpeech-class). Real-world meeting-domain audio (background noise, crosstalk, accents) degrades both engines and tends to compress the gap.

## Architectural reasons that swing the decision past WER alone

1. **ANE residency.** FluidAudio runs Parakeet on the Apple Neural Engine via CoreML. Sustained CPU/GPU drops dramatically on a daemon that wants to be invisible at the menu bar.
2. **Silence honesty.** Parakeet's TDT transducer emits nothing on silence. MLX-Whisper inherits Whisper's well-documented hallucination behaviour on long silences and music. For the mic-L + system-R recording shape, where the user is often muted while the system channel runs, silence honesty matters.
3. **Pipeline elimination path.** Migrating ASR + diarization onto Swift-native FluidAudio enables TECH-P2/P3/P4 (retiring WhisperX, sherpa-onnx, and ultimately the Python sidecar). The Python distribution carries disk cost, launch latency, and `--reset-tcc` complexity, none of which earn their keep post-migration.

## Languages: Parakeet v3 coverage applicable here

Parakeet-TDT-0.6B-v3 ships multilingual support across 25 European languages plus Japanese and Chinese. Confirmed coverage for `en`, `es`, `ru`, `uk` from the user's archive. The archive's `nn`-labelled recording is almost certainly mis-detected language (no Norwegian content in the user's meeting history); ignore.

## Go/no-go

**Go.** Proceed to TECH-P1 (FluidAudio integration) with the following dogfood checkpoint:

- After TECH-P1 ships, transcribe the existing Ukrainian recording `~/Documents/Meetings/raw/20260512-120328.wav` (~40 min) through both engines and eyeball adequacy. If Parakeet output is unusably worse than MLX-Whisper for Ukrainian, surface the gap, file a runtime-language-fallback design ticket, and decide before TECH-P2/P3 retirement lands. This is cheaper than a formal WER pass and gates the retirement step.

## Stop-and-ask events that would re-open this decision

- Ukrainian dogfood pass shows >10 WER-point regression vs MLX-Whisper.
- FluidAudio's required model download exceeds the ~2 GB threshold called out in the TECH-P1 stop-and-ask.
- Any FluidAudio API requires a permission grant the daemon doesn't already hold.
