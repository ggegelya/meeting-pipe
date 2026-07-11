# DEP1 spike: native AVFoundation vs ffmpeg for merge + transcode

Verdict, 2026-07-11. Harness: [`daemon/scripts/dep1-native-audio-spike.swift`](../../daemon/scripts/dep1-native-audio-spike.swift) (throwaway, not in the SPM target). Run with `swift daemon/scripts/dep1-native-audio-spike.swift` (needs ffmpeg on PATH).

## Question

ffmpeg is the heaviest external dependency. Can native CoreAudio (`AVAudioFile` / `AVAudioConverter`) replace the two uses DEP1 scopes, at parity with the ffmpeg artifacts?

1. The recording mic+system merge (`MeetingRecorder.mergeViaFFmpeg`): mic -> 16 kHz mono -> left, system -> 16 kHz mono -> right, 16-bit stereo.
2. The STOR1 retention transcode (`AudioTranscoder.compressToFLAC`): WAV -> FLAC.

No production switch inside the spike; this returns go/no-go only.

## Method

Synthesize a mono mic (3.0 s @ 48 kHz, 440 Hz) and a **stereo** system source (3.5 s @ 44.1 kHz, 880/1320 Hz) with deliberately different lengths and sample rates. Run each operation both natively and via the exact ffmpeg command the daemon uses, then inspect both outputs (frames, duration, per-channel RMS, size).

The native merge downmixes the stereo system source to mono **explicitly** ((L+R)/2), then resamples mono -> 16 kHz through `AVAudioConverter`, then interleaves the two mono streams into a stereo buffer by hand. This avoids `AVAudioConverter`'s channel-layout inference, which the repo already documents as unreliable on the app's untagged mic-L/system-R WAVs (`FluidAudioRunner`). Only the safe mono -> mono rate conversion goes through the converter.

## Results (measured on this Mac, Apple Silicon, macOS 26)

### Transcode (WAV -> FLAC)

| | duration | frames | size | vs WAV |
|---|---|---|---|---|
| source WAV | 3.500 s | 55994 | 228072 B | - |
| native `AVAudioFile` FLAC | 3.500 s | 55994 | 54351 B | 24% |
| ffmpeg `-c:a flac` | 3.500 s | 55994 | 64961 B | 28% |

Frame-exact and lossless both ways; the native output is duration-verified against the source (0.05 s tolerance, the same bar `AudioTranscoder` already uses) and, on this synthetic tone, slightly smaller. Native transcode ran in ~15 ms.

### Merge (mic-L, system-R, 16 kHz stereo)

| | duration | channels | frames | RMS L / R |
|---|---|---|---|---|
| native | 3.500 s | 2 | 55994 | 0.327 / 0.250 |
| ffmpeg `amerge` | 3.000 s | 2 | 48000 | 0.354 / 0.250 |

Both produce a correct 16 kHz 16-bit stereo file with the mic on the left and the system on the right, channel separation intact. Two differences, neither a blocker:

- **Not sample-identical.** `AVAudioConverter` and ffmpeg's `aresample` are different resamplers, so the samples differ; the RMS is close but not equal. Frame-parity and channel-correctness are the achievable bar, not bit-exactness.
- **Length policy differs.** The native prototype pads the shorter input to the longer (3.5 s); ffmpeg's `amerge` stopped at the **shorter** input (3.0 s). Note this also contradicts the `MeetingRecorder.swift` comment that "the ffmpeg merge pads to the longer input." In production the two channels are captured over the same wall-clock window, so the delta is the small CAP1 skew, but a port must pick a policy explicitly.

## Two porting gotchas (both real, both handled in the harness)

1. **FLAC needs `AVEncoderBitDepthHintKey`.** Without it, `AVAudioFile(forWriting:settings:)` for `kAudioFormatFLAC` throws an empty ObjC nil-error.
2. **Reads must be position-bounded.** `AVAudioFile.read(into:)` past EOF throws an empty nil-error on this SDK rather than returning a 0-frame buffer; loop while `framePosition < length` and read an explicit `frameCount`.

## Verdict: GO (both), with scope caveats

- **Transcode: clean GO.** Native FLAC is frame-exact, lossless, fast, and `AudioTranscoder` already opens the result with `AVAudioFile` for its duration verify, so the verify step is unchanged. Lowest-risk to port first.
- **Merge: GO on feasibility.** The native path reproduces the artifact's essential properties (rate, format, channel assignment, separation). The port must (a) downmix the stereo system source explicitly, not via converter layout inference; (b) fix a length policy (pad-to-longer is arguably better: no data loss); (c) keep the single-source mono fallback.
- **The "three files with hardcoded path lists" premise is stale.** HYG1 (shipped the same day the DEP1 spec was written) already consolidated ffmpeg discovery into one `ExecutableResolver` + `MeetingRecorder.findFFmpeg`. Three files *spawn* ffmpeg, they do not each carry a path list.
- **A GO here does not delete the ffmpeg dependency.** `MuteRedactor` is a third ffmpeg spawn site (offline mute redaction) outside DEP1's scope. Deleting the binary (the DIST1 payoff) needs MuteRedactor ported too, or the dependency kept for it. DIST1 sizing should not assume ffmpeg disappears from a merge+transcode port alone.

## Follow-on

The production port (merge + transcode, and separately MuteRedactor) is deliberately out of this spike. It is prerequisite work for DIST1 ("shrink what needs bundling"); DIST1's row records this verdict as its gate.
