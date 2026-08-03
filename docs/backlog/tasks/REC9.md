# REC9: the stop-time merge truncates the recording to the shorter capture channel, then deletes the only recoverable copy

Filed 2026-08-03 by the audit band. Severity critical, confirmed by an independent skeptic and reproduced by hand.

## What is wrong

`RecordingPostProcessor.mergeToTempViaFFmpeg` builds a bare `amerge` with no length policy, so the merged `<stem>.wav` ends where the **shorter** of `mic.wav` / `system.wav` ends. `produceFinal` then verifies only that the output exceeds 4096 bytes, promotes it onto the canonical path, and deletes both intermediates, so whatever the merge dropped is unrecoverable.

Reproduced on this Mac on 2026-08-03 with the exact filter and arg vector from `RecordingPostProcessor.swift:194-208`: a 10.000000 s mono mic plus a 3.000000 s stereo system produced a **3.000000 s** output at 192,078 bytes. `ffmpeg -h filter=amerge` on ffmpeg 8.1 lists only `inputs` and `layout_mode`, so no length policy is even expressible in that filter.

Evidence:

- `daemon/Sources/MeetingPipe/RecordingPostProcessor.swift:197` is `[micL][sysR]amerge=inputs=2[stereo]`, carrying no `apad`, no `duration=longest`, no `-shortest` and no `-t`.
- `daemon/Sources/MeetingPipe/RecordingPostProcessor.swift:66` is `FileManager.default.fileExists(atPath: url.path) && fileSize(url) > 4096`, the only verification before promotion. A truncated merge passes it trivially at 192 KB.
- `daemon/Sources/MeetingPipe/RecordingPostProcessor.swift:173` shows `promoteMerged` gating on that same byte predicate, so the promote step adds no independent check.
- `daemon/Sources/MeetingPipe/RecordingPostProcessor.swift:131-132` deletes `mic.wav` and `system.wav` the moment `promoteMerged` returns true.
- `daemon/Sources/MeetingPipe/MeetingRecorder.swift:1260` reads `// system.wav is fine - the ffmpeg merge pads to the longer input.` That comment asserts the exact opposite of the measured behaviour, and it is what licenses every short-`system.wav` path.

## What it has actually cost

Measured across the owner's whole event-log history on 2026-08-03, 153 `intermediate_durations` rows:

- 140 of 153 recordings have `system.wav` shorter than `mic.wav`, so the tail of the owner's own mic channel is discarded on nearly every recording.
- Total mic audio discarded: 77.3 s. Median per affected recording: 0.21 s. That routine case is the CAP1 skew and is harmless.
- The tail is not harmless. On 2026-07-15 the SCStream start failed on TCC and system capture only came up at 14:28:42. At stop, `mic_audio_sec` was 41.2 and `system_audio_sec` was 5.28, `delta_sec` -35.92. The merge kept 5.28 s, which is **87 percent of the meeting destroyed**.
- That run was recorded as a clean success: `recording_stopped {produced_final: true}`, then `engine_succeeded {audio_seconds: 5.28, segments: 1}`. The published transcript is one line. The intermediates are gone from disk.
- The only detector fired into a text log and nowhere else: `MeetingRecorder.swift:1607` writes `WARN: WAV is <n>% of recording wallclock` via `Log.writeLine`, with no `Log.event`, so it is invisible to `mp logs`, to the Diagnostics viewer and to the user.

The `docs/spikes/dep1-avfoundation-vs-ffmpeg.md:42` spike found this divergence on 2026-07-11 and dismissed it, reasoning that in production both channels span the same wall-clock window so the delta is the small CAP1 skew. The event log refutes that premise: 140 of 153 recordings disagree, and one by 35.9 s. CAP1's own promotion trigger is skew magnitude rather than audio loss, so it never fired on this.

## Scope

Give the merge an explicit length policy so the final is never shorter than the longer capture channel. Padding the tail alone is not sufficient: a channel that starts late (the 2026-07-15 shape) needs its head offset handled explicitly, or the recovered audio lands against the wrong mic timestamps.

Strengthen `producedPlausibleOutput` from a byte count to a duration check against `max(audioDurationSec(mic), audioDurationSec(system))` with a tolerance, so an under-length merge fails, keeps both intermediates, and writes a `.recordfail.json` breadcrumb instead of promoting.

Promote `checkDurationParity`'s ratio warning from a bare `Log.writeLine` to a `Log.event` plus a user-visible notice, so a future occurrence is diagnosable and the user knows.

Fix `MeetingRecorder.swift:1260`'s comment in the same commit, and correct `Notifier.swift:272`'s interrupted-capture copy, which tells the user the recording continues mic-only past the loss when in fact it ends at the loss. `MeetingSessionController.swift:557`'s `RemoteAudioWarning.interrupted` rationale rests on the same false premise.

Related: REC10 covers the sibling defect on the retry path, and its fix shares this one's offset handling. Pick them up together.

## Acceptance

Suite green with new tests. A merge fed a 10 s mic and a 3 s system produces a 10 s final with the system channel silent where it had no audio, and a merge fed a system channel that starts late places its audio at the correct offset rather than at sample 0. An under-length merge result is refused by the plausibility check, keeps both intermediates, and leaves a `.recordfail.json`. A ratio-parity failure emits an event. The three doc and comment corrections above land in the same commit.

## Owner walkthrough

Steps tagged [owner] / [session] by who acts.

1. [session] `./scripts/rebuild.sh`, then tell the owner it is ready.
2. [owner] Record a short meeting normally and stop it. Pass: the recording plays back at its full length, both sides audible, nothing different from today.
3. [owner] The case that matters, and it needs Screen Recording denied at the start. Open System Settings, Privacy and Security, Screen and System Audio Recording, and turn MeetingPipe **off**. Start a recording, talk for about 20 seconds, then turn the permission back **on** while still recording, talk for another 20 seconds, and stop.
4. [owner] Open the meeting in the Library. Pass: the recording is about 40 seconds long and your voice is present for the whole of it, including the first 20 seconds when system capture was unavailable. Before this fix that recording would have been about 20 seconds and the first half of your own audio would be gone.
5. [owner] Say "REC9 good to close" or what is wrong.
