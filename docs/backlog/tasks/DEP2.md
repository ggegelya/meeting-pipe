# DEP2: ffmpeg is still a hard runtime dependency at three spawn sites although DEP1 measured the AVFoundation replacement as GO

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) DI-12). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Verified in code on 2026-10-24. The daemon spawns ffmpeg from three files, all resolving the binary through `RecordingPostProcessor.findFFmpeg` (`MEETINGPIPE_FFMPEG`, then `PATH`, then the DIST1 bundled `pipeline-runtime/bin/ffmpeg`, then three Homebrew and MacPorts paths):

1. **`RecordingPostProcessor`**: `mergeToTempViaFFmpeg` builds the stop-time stereo file (mic left, system right) with REC9's `apad` plus target-duration length policy and the `systemDelayMs` offset from `mergeLengths`; `convertToTempViaFFmpeg` handles the single-source case. With no ffmpeg, `produceFinal` moves `mic.wav` to final and keeps `system.wav` "for a later merge", so the meeting's other participants are not in the file the pipeline transcribes.
2. **`MuteRedactor.redactIfNeeded`**: offline off-the-record and mute redaction, a `volume=0:enable='between(t,...)'` filter from `buildFilter`. With no ffmpeg it logs "skipping mute redaction" and returns, which SEC16 is turning into a fail-closed outcome.
3. **`AudioTranscoder.compressToFLAC`**: STOR1's `compress` retention policy, WAV to FLAC, with an `AVAudioFile` duration check afterwards.

**DEP1 answered the feasibility question on 2026-07-11.** [`docs/spikes/dep1-avfoundation-vs-ffmpeg.md`](../../spikes/dep1-avfoundation-vs-ffmpeg.md): native `AVAudioFile` FLAC is frame-exact, lossless and smaller (54,351 B against 64,961 B on the test clip), "clean GO"; the native merge reproduces rate, format and channel assignment, "GO on feasibility", with two gotchas (FLAC needs `AVEncoderBitDepthHintKey`; reads must be position-bounded) and the caveat that the port must downmix stereo system audio explicitly and fix a length policy. It scoped out `MuteRedactor` and said deleting the binary needs that port too. No task picked up the production port.

**What the dependency costs.** `install.sh` installs ffmpeg through Homebrew, which is one of SETUP.md's prerequisites and the reason locked-down Macs cannot install at all (DIST1's own framing). `bundle-runtime.sh` has to fetch a static ffmpeg from an owner-pinned `FFMPEG_URL` with an LGPL or GPL licensing obligation, and prints "the bundle has NO ffmpeg" when unset. CI installs ffmpeg for the `MuteRedactorTests` data-safety cases, and `ci-local.sh` warns they skip without it. CONC5 exists partly because the ffmpeg spawns drain stderr after exit and never kill a timed-out child.

**A doc claim to fix on the way.** README's install step says "`ffmpeg` is used by the Python pipeline for audio loading". `grep -rli ffmpeg pipeline/src pipeline/tests` is empty: the pipeline never calls it.

## Scope

1. **Port the transcode first** (DEP1's lowest-risk leg; `daemon/scripts/dep1-native-audio-spike.swift` is the measured starting point for both ports): `AudioTranscoder.compressToFLAC` writes FLAC through `AVAudioFile` with the bit-depth hint; the existing duration verify is unchanged.
2. **Port the merge.** A native `StereoMerge` writes mic to the left channel and the system leg (explicitly downmixed to mono) to the right, applying `MergeLengths` as it stands after REC9 and REC14: the same pad, target duration and `systemDelayMs`. No ffmpeg fallback is kept beside it: two merge implementations is the drift this removes, and the golden tests below are the comparison.
3. **Port the redaction** after SEC16 lands, so it ports the fail-closed outcome and the channel semantics SEC16 decides rather than today's mic-only filter: zero the frames inside each span on the channels SEC16 names, write to the same `.redacting.wav` temp and rename, keeping `MuteRedactor`'s original-copy and event contract.
4. **Remove the dependency.** Once all three are native, delete `findFFmpeg` and its fallback list, ffmpeg from `install.sh`'s prerequisite loop, `FFMPEG_URL` and the ffmpeg step from `bundle-runtime.sh`, and the CI install step. SETUP.md, README (including the false pipeline claim and the retention note "Compression needs `ffmpeg` on your `PATH`") and the DIST1 runbook drop it in the same commit.

## Explicitly not / out of scope

- Changing the merge's length or offset policy. REC9 and REC14 own it; this ports it byte-for-behaviour.
- Deciding what off the record covers: SEC16.
- Making the ffmpeg spawns safe while they exist: CONC5. If CONC5 lands first its ffmpeg sites are deleted here, not migrated twice.
- Any other audio dependency change (FluidAudio, the ASR input path).

## Acceptance

- Golden comparisons, run in the daemon suite against fixture WAVs built in the test (no ffmpeg needed): the native FLAC decodes to the source's exact frame count and samples; the native merge of a 10 s mic and a 3 s system leg matches REC9's expected length and channel assignment, and a `systemDelayMs` offset lands the system audio at the right frame; the native redaction zeroes exactly the frames inside each span on the named channels and none outside.
- The existing `RecordingPostProcessorTests`, `AudioTranscoderTests`, `MuteRedactorTests`, `OrphanRecordingRecoveryTests` and `AudioRetentionSweepTests` stay green with ffmpeg absent from `PATH`; the `ci-local.sh` ffmpeg warning and the CI install step are gone.
- `grep -rn ffmpeg daemon/Sources scripts .github` finds only historical comments, or nothing.
- `cd daemon && swift build` and `swift test` green, N new tests in the commit body; `bash scripts/ci-local.sh` green; `bash scripts/test-app-relocation.sh` green.
- Owner check: with ffmpeg uninstalled (`brew uninstall ffmpeg`), record a short call with one off-the-record stretch: the final file is stereo with both sides, the stretch is silent per SEC16, and a retention compress produces a FLAC.
