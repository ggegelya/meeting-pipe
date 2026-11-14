---
id: ASR10
title: audio_seconds in every transcript is the end of the last word, not the audio's length, because the pinned FluidAudio returns duration 0 for chunked audio and the runner falls back to the last segment end
category: Transcription
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). audio_seconds equals the last segment end on 112 of 112 field transcripts (mic file longer by 60 s or more on 9 of 72, up to 550 s; 0 on a 173 s file) because FluidAudio 0.14.8's chunked path reports duration 0; the Library length, the Audio tab trim caption and a merged meeting's length all read it. Write the sample-count length as audio_seconds plus a new last_speech_sec, fix the merge writer, and make readers trust only transcripts that carry the new field.
---

# ASR10: audio_seconds in every transcript is the end of the last word, not the audio's length, because the pinned FluidAudio returns duration 0 for chunked audio and the runner falls back to the last segment end

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: the 2026-11-13 [field evidence report](../../audits/2026-11-13-field-evidence.md), section "Transcripts and summaries", finding "audio_seconds in every transcript is the end of the last word, not the length of the audio" (transcripts-and-summaries#11), plus the low "Transcript audio_seconds is the end of the last transcribed segment, not the length of the audio" in its "Pipeline and publishing" section (pipeline-and-publishing:9), folded in here.

**Field numbers.** `audio_seconds` equals the last segment's end exactly on 112 of 112 transcripts with segments and is 0 on the one empty transcript. Against the recorder's `intermediate_durations.mic_audio_sec`, the mic file is longer by a median 3.3 s, by 10 s or more on 18 and by 60 s or more on 9 of 72 recordings with events (up to 550 s, 2,074 s in all). The low's independent recount agrees: 72 of 72 in-window transcripts match the last segment end within 0.011 s, recording wall-clock exceeds it by more than 30 s in 10 recordings, and stem `20261112-163040` reads 0 on a 174 s recording. On the trimmed stem `20261113-093231` it reads 589.84 against a trim point of 594.01 and a recording of 654.2 s, and the `transcription` / `held_end_excluded` row for `20261112-163040` carries `audio_seconds: 0` for a 173 s file. The one recording short enough for FluidAudio's single-chunk path, the deleted 7.7 s fragment `20261009-121844`, logged `audio_seconds` 7.7 with 0 segments, which fits the mechanism below. All three build eras, still in the newest stem.

**Mechanism, re-verified in code at HEAD on 2026-11-13.** `FluidAudioRunner.transcribe` computes the true length and keeps it only for the memory probe: `audioSec = Double(samples.count) / 16_000`. The sidecar gets `let audioSeconds = asrResult.duration > 0 ? asrResult.duration : (segments.last?.end ?? 0)`. In the pinned FluidAudio (`daemon/Package.swift`, `exact: "0.14.8"`), `AsrManager.transcribe` takes the single-chunk path only when `audioSamples.count <= ASRConstants.maxModelSamples` (240,000 samples, 15 s at 16 kHz); everything longer goes through `ChunkProcessor`, whose two returns both call `manager.processTranscriptionResult(... audioSamples: [], ...)`, and `processTranscriptionResult` computes `let duration = TimeInterval(audioSamples.count) / TimeInterval(config.sampleRate)`. So every recording over 15 s returns duration 0 and takes the last-segment fallback, and an empty chunked transcript writes 0. `HeldEndTrim.apply`'s doc comment claims "`audioSeconds` stays the file's real length, because the file still has it", which is true of the code it guards and false of the value it receives.

**Who reads it (re-checked 2026-11-13).**
- `MeetingStore.measuredDuration` (UX74): the transcript's `audio_seconds` is the first source of every Library row's length and wins whenever it is positive, so the Library, the Meeting time rail and `MeetingStats`' `durationSec` under-report by the post-speech tail. UX74's "exact for the five stems" check passed because those stems were 5.7 s to 9.0 s long, i.e. on the single-chunk path.
- `MeetingDurationCache` (PERF22, done) persists that answer in `~/Library/Caches/MeetingPipe/durations.json` keyed on the transcript's and the audio's identity, so a reader-side fix alone would not reach rows already cached.
- `AudioTab` passes `meeting.durationSec` to `HeldEndTrim.caption(trimSec:durationSec:)`, whose minutes form needs `durationSec > trimSec`. After `HeldEndTrim.apply` no segment ends past the trim point, so on any chunked recording the duration is always below the trim and the caption always falls back to the clock-time form.
- `SinkDispatcher.runDaemonTranscription` logs `audio_seconds` on `engine_succeeded` and `held_end_excluded`, and `scripts/valid1_check.py` divides it by the engine's elapsed time for its real-time factor, which therefore reads slightly low.

**Found at filing, same field, second writer.** `merge_meetings` builds the merged transcript as `merged = dict(primary)` and never sets `audio_seconds` (no Python module under `pipeline/src/mp/` writes the key at all), so a FEAT9 merge keeps the first fragment's value while its segments run across every fragment, and the Library then reports the merged meeting as the first fragment's length.

Correction at filing: the field report says the words-per-minute floor "cannot see trailing silence" through this field. It does not read `audio_seconds`: `transcript_quality._duration_sec` takes the maximum segment end itself, so fixing the field leaves the floor unchanged, and whether its denominator should be the real length is a separate decision (see Explicitly not). The report's "Audio tab caption" is real, but it reads the value indirectly through `Meeting.durationSec`, as above.

Related: [UX74](./UX74.md) (owns the Library duration order), [PERF22](./PERF22.md) (done, the cache), [END17](./END17.md) (the held-end trim and its caption), [ASR6](./ASR6.md) and [ASR8](./ASR8.md) (the FluidAudio pin; a bump may or may not fix the upstream zero, and this task must not depend on it), and the field report's no-content-floor finding.

## Scope

1. **Writer.** In `FluidAudioRunner.transcribe`, write `audioSeconds` from the sample count the runner already holds (`Double(samples.count) / 16_000`), never from `asrResult.duration`, and add `lastSpeechSec` (`segments.last?.end ?? 0`) to `TranscriptSidecar` as an optional `last_speech_sec`, so old sidecars still decode. Factor the two values into one small pure static (for example `FluidAudioRunner.lengths(sampleCount:segments:)`) so they are testable without models. Fix `HeldEndTrim.apply`'s comment to say both values survive the trim unchanged except that `last_speech_sec` is recomputed from the kept segments.
2. **Merge writer.** In `merge_meetings`, set `audio_seconds` to the sum of the fragment `durations` it already has and `last_speech_sec` to the last merged segment's end.
3. **Readers.** `MeetingStore.measuredDuration` trusts the transcript's `audio_seconds` only when the transcript also carries `last_speech_sec` (the mark of a corrected writer); otherwise it goes to the header read first and uses the legacy `audio_seconds` only when there is no readable final audio. Bump `MeetingDurationCache.schemaVersion` so every cached legacy answer is recomputed once. No backfill of transcripts on disk.
4. **Docs.** `CONVENTIONS.md`'s `held_end_excluded` row and wherever the transcript sidecar's keys are described: `audio_seconds` is the audio's length from rows written after this lands, the last word's end before; `last_speech_sec` is new.

## Explicitly not

- Rewriting the 112 existing transcripts: the reader rule in step 3 makes them read correctly, and a re-transcribe rewrites them anyway.
- Changing the words-per-minute floor's denominator in `transcript_quality`: with the real length, a five-minute meeting followed by a 550 s silent tail would trip the floor, which is a behaviour change that belongs with the content-floor decision, not a data fix.
- Bumping or patching FluidAudio, or relying on `asrResult.duration` at all ([ASR8](./ASR8.md) owns the pin).
- The late-end tails themselves, which are why the gap is large: the END band.

## Acceptance

- New Swift tests: the pure length helper over a sample count above 240,000 with empty and non-empty segments returns the sample length as `audioSeconds` and the last segment end (or 0) as `lastSpeechSec`; a `TranscriptSidecar` round trip with and without `last_speech_sec` (an old sidecar decodes with nil); `HeldEndTrim.apply` keeps `audioSeconds` and recomputes `lastSpeechSec` below the trim point.
- New `MeetingStore` tests: a transcript with `last_speech_sec` and a longer `audio_seconds` reports `audio_seconds`; a legacy transcript (no `last_speech_sec`) whose `audio_seconds` is shorter than its final WAV's header reports the header; a legacy transcript with no audio still reports its `audio_seconds`. A `MeetingDurationCache` test that a version-1 file loads as empty.
- An `AudioTab`-level or `HeldEndTrim.caption` test that a chunked trimmed recording (duration from the header, longer than the trim) produces the minutes form.
- New pytest: a merge of two fragments writes `audio_seconds` equal to the sum of their durations and `last_speech_sec` equal to the last segment end.
- `bash scripts/ci-local.sh` green (swift test, pytest, ruff, pyright, truth fences).
- After a fresh build, the next `engine_succeeded` row for a recording over 15 s carries an `audio_seconds` within 0.1 s of the WAV header, and the Library row for `20261113-093231` reads about 654 s.
