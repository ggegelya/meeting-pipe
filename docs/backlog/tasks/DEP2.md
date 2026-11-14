---
id: DEP2
title: Ffmpeg is still a hard runtime dependency at three spawn sites although DEP1 measured the AVFoundation replacement as GO
category: Distribution
status: new
priority: P2
comment: Filed 2026-10-24 (audit band, go-live DI-12): RecordingPostProcessor merge, MuteRedactor and AudioTranscoder still spawn ffmpeg, so install needs Homebrew, the bundle needs a licensed static ffmpeg, and CI installs it. DEP1 measured native FLAC and merge as GO. Port FLAC, then the merge with REC9 and REC14's length policy, then redaction after SEC16, then delete findFFmpeg and every install and CI step. [Spec](./DEP2.md) Amended 2026-11-13 by the audit band: until the native merge lands, the no-ffmpeg fallback must stop promoting a mic-only final as success, since the later merge it promises can never run (F052).
---

# DEP2: ffmpeg is still a hard runtime dependency at three spawn sites although DEP1 measured the AVFoundation replacement as GO

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) DI-12). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

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

## Amendment 2026-11-13 (audit band)

Added from the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md) (F052, confirmed). Re-verified in code at HEAD on 2026-11-13.

**What this spec's Context understates.** Item 1 above says that with no ffmpeg `produceFinal` "moves `mic.wav` to final and keeps `system.wav` for a later merge". The later merge cannot happen, and the meeting is reported as a success:

- `RecordingPostProcessor.produceFinal`, in the `hasMic && hasSystem` branch, logs "ffmpeg not found - moving mic.wav to final, keeping system.wav for a later merge", does `FileManager.default.moveItem(at: mic, to: final)`, and then `if producedPlausibleOutput(at: final) { return true }`. No `writePostProcessFailure` runs on that path, so no `<stem>.recordfail.json` breadcrumb and no `recorder/postprocess_failed` event.
- `RecordingPostProcessor.recoverOrphan` opens with `guard !fm.fileExists(atPath: finalURL.path) else { return nil }`, and `OrphanRecordingRecovery`'s scan lists only "stems with .mic.wav or .system.wav but no finished .wav". With `<stem>.wav` now present, the stem is invisible to both the launch sweep and the after-job sweep, so `system.wav` stays beside it unmerged forever.
- The pipeline then transcribes and publishes the mic-only file as an ordinary success, with the far side of the call missing.

Trigger: no ffmpeg at `MEETINGPIPE_FFMPEG`, on `PATH`, in the DIST1 bundle, or at the three fallback paths, for example a Homebrew ffmpeg removed on a build without the bundled binary. **Not seen in the field:** the [2026-11-13 field evidence](../../audits/2026-11-13-field-evidence.md) lists F052 under "Not seen" (74 of 74 work-laptop recordings have both channels), so this is a latent defect, which is why it stays P2. The single-source path is already correct: `convertToTempViaFFmpeg` fails without ffmpeg and `writePostProcessFailure` runs.

**Scope addition (an interim step, land it first if the native merge is not first).** In the no-ffmpeg branch of `produceFinal`, do not rename `mic.wav` onto the final. Return false through `writePostProcessFailure(final:retained: [mic, system], reason:)` with a reason that names the missing ffmpeg, keeping both intermediates, so the existing orphan sweep retries once ffmpeg exists and REC24's attempt count applies. REC24's cap (`OrphanRecordingRecovery.maxAfterJobAttempts`, 3) stops only the after-job sweep; the launch sweep ignores it, so a stem that hit the cap while ffmpeg was missing is still merged at the next launch after ffmpeg is installed, and the reason string should say that a relaunch is what retries it. Item 2's native merge then deletes the branch entirely. `findFFmpeg` goes through `ExecutableResolver.resolve` with the `MEETINGPIPE_FFMPEG` override, `PATH` and fixed Homebrew fallbacks, so the test needs a seam: inject the locator into `produceFinal` as a defaulted parameter rather than relying on the test machine having no ffmpeg. Correction at filing: the existing stand-in ffmpeg in `RecordingPostProcessorTests` (`fakeFFmpeg`) is wired through `setenv("MEETINGPIPE_FFMPEG", ...)`, which can supply a binary but cannot force "no ffmpeg found" on a machine that has one, which is why a new seam is needed.

**Explicitly not.** Changing what the HUD or Library shows for a post-process failure; that surface already exists for `postprocess_failed`. Relates to REC14 (partial) for the length policy and to the recording-reliability classes on compress-failure tests and an unchecked channel shortfall, which are filed separately.

**Acceptance additions.**

- `RecordingPostProcessorTests`: `produceFinal` with both intermediates present and the locator returning nil returns false, leaves `<stem>.mic.wav` and `<stem>.system.wav` in place, writes no `<stem>.wav`, writes a `<stem>.recordfail.json` whose `retained` lists both, and emits `recorder/postprocess_failed`.
- `OrphanRecordingRecoveryTests`: the same directory is listed by the orphan scan afterwards, and `recoverOrphan` with a working locator then produces the stereo final and removes both intermediates.
- `cd daemon && swift build` and `swift test` green, new test count in the commit body.
