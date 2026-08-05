# REC9: the stop-time merge truncates the recording to the shorter capture channel, then deletes the only recoverable copy

Filed 2026-08-03 by the audit band. Severity critical, confirmed by an independent skeptic and reproduced by hand.

## Progress (2026-08-05, shipped; owner-owed walkthrough)

All four scope items ship. Daemon suite green, **2377 tests, 21 new** (15 `RecordingPostProcessorTests`, 6 `RecordingDurationParityTests`); `swift build` clean; `truth_fences.py both` clean. The two new event actions (`recorder`/`merge_too_short`, `recorder`/`duration_parity_low`) sit in the existing `recorder` category, so the fence needed no table edit.

**The length policy is `RecordingPostProcessor.mergeLengths`, and it is pure.** `apad` on each leg so neither can end the merge, `adelay` on the system leg for a late start, and `-t` at `max(mic, offset + system)`. Verified against real ffmpeg 8.1 before writing any Swift: the shipped filter turned a 10 s mic plus a 3 s system into 3.000000 s, the new one into 10.000000 s with the right channel silent outside the window it was captured in. Both shapes are exercised end to end by tests that decode the produced WAV per channel rather than trusting its duration alone.

**The head offset is measured, not inferred.** `MeetingRecorder` marks `systemUptime` at start and at the first frame written into the system WAV *as it currently stands*: the mark is cleared in `startSystemCapture`, not at `start()`, because `AVAudioFile(forWriting:)` truncates, so what the merge needs is where the audio the file actually holds begins. Offsets below 1.0 s are dropped as the routine CAP1 skew (median 0.21 s over 153 recordings), so no normal recording moves. The offset also lands in the `intermediate_durations` event as `head_offset_sec`, since the existing `delta_sec` cannot tell a channel that stopped early from one that started late.

**The promote gate fails closed.** `outputIsPlausible` keeps REC1's 4 KiB floor and adds the duration check against the policy's target, with a 0.5 s tolerance for resampler rounding. An output that cannot be measured is refused rather than promoted. The refusal path is the one that already existed, so it keeps both intermediates and writes `.recordfail.json`, now with a `reason` that names the shortfall in seconds. Pinned end to end with a stand-in ffmpeg that exits 0 having written a short file, which is exactly the shape the byte floor waved through: a clean exit status is not evidence that the audio survived.

**The parity warning is visible.** `RecordingDurationParity` is the pure verdict (same family as `RemoteAudioWarning` and `MicCoverageWarning`), snapshotted at stop into `lastDurationParity`; `MeetingSessionController` raises a "Recording is shorter than the meeting" notice and `checkDurationParity` emits `duration_parity_low`, so `mp logs` and the Diagnostics viewer both see it.

**Three corrections, and what they turned out to be.** `MeetingRecorder.swift`'s "the ffmpeg merge pads to the longer input" and `RemoteAudioWarning.interrupted`'s "absent from the death point on" were both false when written and are **true as of this commit**, because the policy makes them true; each now says so and names what re-breaks it, which is more useful than deleting a claim the code finally honours. `Notifier`'s interrupted-capture body ("the recording is mic-only from that point") is the same case and keeps its wording for the same reason, with the dependency recorded above it.

**Scope held to REC9.** REC10 (the retry path overwriting the system partial) is untouched and still open. Its scenario does improve here without being fixed: because the offset is keyed to the file's own first frame, a retry's audio is now merged where the retry happened instead of at sample 0. The audio the retry overwrote is still lost, which is REC10's defect.

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
