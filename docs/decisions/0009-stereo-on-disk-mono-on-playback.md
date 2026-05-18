# ADR 0009: Stereo on disk, mono mixdown on library playback

| Property            | Value              |
| ------------------- | ------------------ |
| **Status**          | Accepted           |
| **Date**            | 2026-05-18         |
| **Decision Makers** | Project owner      |
| **Technical Area**  | Recording / library|
| **Related Tasks**   | TECH-LIB-MIX       |

## Context

The recorder writes a stereo WAV per meeting: microphone audio on the
left channel, system audio (the meeting app's output) on the right.
Frame-count equality between channels is a load-bearing invariant: the
diarization layer assumes alignment, the silent-system-audio backstop
compares per-channel RMS, and `MicGateWriter` preserves alignment by
emitting zero-amplitude frames on muted segments rather than skipping
them. The stereo layout is the right format for storage and for every
downstream pipeline stage.

The library window plays recordings back through headphones for review.
The stereo layout that is correct for processing produces a confusing
listening experience for the user: their own voice arrives only in the
left ear and the other participants arrive only in the right. The
report is "input in left ear, output in right ear."

## Decision Drivers

- **Storage format is fixed by downstream requirements.** Changing the
  on-disk layout would break diarization, backstop, and the
  MicGateWriter alignment invariant. It is not negotiable.
- **Playback format is independent of storage format.** The playback
  path can downmix at decode time without modifying the file.
- **The default should match the dominant listening case.**
  Headphone review is the dominant case; stereo review of mic-vs-system
  separation is a rare debugging case.
- **The on-disk WAV must remain byte-identical.** Verified by SHA-256
  before and after playback. Any decision that touches the file is
  wrong.

## Options Considered

### Option A: Keep stereo playback as the default

Pros: zero work. Cons: the headphone-listening experience is broken
for every meeting the user reviews.

### Option B: Mono mixdown as the default, stereo as a toggle

Pros: matches the dominant listening case; the rare stereo case is
one click away. Cons: the playback path becomes more complex
(per-buffer downmix or a downmix-aware audio engine).

### Option C: Mono mixdown only, no stereo option

Pros: simplest playback path. Cons: the user occasionally wants to
hear the channel separation (for example, when checking whether a
silent participant's mic was actually open). Removing the option
forecloses a real use case for no real benefit.

### Option D: Write a separate mono mix to disk alongside the stereo WAV

Pros: simple playback (just play the mono file). Cons: doubles disk
usage; introduces a second source of truth that has to stay in sync.
A failed mono-mix write becomes a new corruption mode.

## Decision

**Option B.** Library playback defaults to a mono mixdown computed at
playback time as `0.5 * L + 0.5 * R` per sample, applied to both ears.
The on-disk WAV stays stereo and is never modified by the playback
path. A toggle in the playback controls switches to original stereo;
the toggle state persists per library.

The mixdown is computed via explicit per-buffer summation in the
playback pipeline, not via an `AVAudioMixerNode` pan-to-center trick.
Pan-to-center on a stereo player node does not actually downmix; it
only re-positions a mono source. Explicit summation is the unambiguous
implementation.

## Consequences

- The on-disk WAV is byte-identical before and after playback
  (verified by SHA-256 in `TECH-LIB-MIX` acceptance).
- `AudioPlaybackController.swift` owns the channel-mode application.
  The `PlaybackChannelMode` enum (`.monoMixdown`, `.stereoOriginal`)
  is the public surface; the player rebuilds its buffer when the
  mode changes mid-playback so the switch is audible without a file
  re-read.
- The toggle is persisted via `UISettings` (the daemon's UI-only
  preferences singleton). It is not surfaced in `config.toml`
  because pipeline subprocesses do not read it.
- A future "export as mono mix" feature can reuse the same downmix
  function but would write a new file rather than altering the
  source.
- The downmix has the standard sum-of-two-correlated-sources risk:
  if the same speaker leaks into both mic and system audio (echo,
  bleed-through), the sum can clip. Acceptable for review playback;
  if it becomes audible on real recordings the fallback is to scale
  by `1 / sqrt(2)` rather than `0.5`.
