---
id: REC14
title: The merge's no-readable-duration fallback ends with the mic, so an unclean exit discards the longer system leg
category: Recording
status: partial
priority: P2
comment: Filed 2026-08-17, surfaced by REC13's 2026-08-14 incident and approved by the owner for its own row rather than folded into that fix. `RecordingPostProcessor.mergeLengths` ([`:89-101`](../../../daemon/Sources/MeetingPipe/RecordingPostProcessor.swift#L89)) returns `padMic: false` with no `targetDurationSec` when either leg's duration is unreadable, which makes the merge end with the **mic**. That bias is deliberate and REC9 shipped it as specified: the mic is the channel the owner cannot re-obtain. **The gap is that the fallback fires almost exclusively when the process was killed**, and in that case the bias is backwards, because unfinalized RIFF headers are what made the durations unreadable in the first place and the system leg is then no more re-obtainable than the mic. **Measured cost, once:** `20260814-163455` finalized at 2798.5 s (46.6 min) against 113 minutes of wall clock, dropping roughly 67 minutes of the far side of the call, with ffmpeg reporting `Estimating duration from bitrate, this may be inaccurate` and `corrupt input packet in stream 0`. The durations were unreadable only because the termination flush never ran and `kill -9` was required, both of which REC13 fixed on 2026-08-17, so the trigger is now much rarer but not gone: any crash, SIGKILL or power loss still reaches orphan recovery with unfinalized headers. Scope is the fallback only, and the question the pickup answers is which of two routes to take: prefer the longer leg when neither duration is readable, or derive duration from file size and format, which is **exact** for the uncompressed PCM these intermediates hold (`537,310,524` bytes at 48 kHz mono float32 is 2798.5 s, and that arithmetic is what diagnosed the incident). The second route dissolves the fallback rather than re-biasing it and is the likelier answer, but the pickup should confirm the format is always known at that point before committing to it. Out of scope: REC9's normal-path length policy, which behaved correctly and is not reopened, and the mic-tap death at 17:21 that made this incident's loss 67 minutes instead of nothing (REC8/REC10 territory). **P2 by the REC10 precedent** (data loss on a path reached only after another failure); the owner may re-band, since the loss is total for the affected channel when it does fire. **Engineering shipped 2026-08-19, route B, and the spec's diagnosis was wrong in a way that mattered.** Walkthrough step 1's two answers: route B, and **yes, the format is always known**, better than the spec hoped. It needs no external knowledge at all, because `byteRate` lives in the file's own `fmt ` chunk, written at creation, so it survives any kill and is available on the orphan-recovery path exactly as on the normal one. **The correction:** the no-duration fallback the spec targets never ran. `AVAudioFile` writes the `data` chunk's size as a placeholder and patches it on close, so a killed writer leaves **0** there with the samples on disk; `audioDurationSec` returned `0.0`, which is a measurement rather than an absence, `mergeLengths` saw two readable durations, and `max(2798.5, offset + 0)` cut to the mic. The observed final was 2798.5 s, the mic's length to the sample, which is the fingerprint that settles it. Verified before designing anything, with a five-line probe that built an unfinalized WAV and printed `0.0`. **This matters because the spec's own acceptance test would have passed while the bug survived:** it asks for a test that the nil branch "no longer ends with the shorter leg", and re-biasing that branch changes nothing on the path that actually lost the audio. **What shipped:** `audioDurationSec` now measures the payload against the file's real size, capped by a declared size when one exists (so a truncated file is not believed, and trailing chunks cannot inflate a normal read); and `mergeLengths` treats a non-positive duration as no measurement, so a zero can never win a `max()` again, plus covers the system leg when it is the only one that measures. REC9's mic bias is untouched in the case it was actually reasoning about, no measurement at all, and its comment now records which route was taken and why. 13 tests added, including the incident's own byte counts as a fixture and an orphan-shape end-to-end over two real files. `swift build` clean, `swift test` 2815 tests 0 failures, truth fences and dash guard clean, no new event, no pipeline change. Docs: `README.md`, `ARCHITECTURE.md`, and `daemon/docs/gotchas.md`, which gained the reusable lesson (a zero is a measurement, and an unfinalized WAV is full of them) **and had REC13's own chain corrected**, since that gotcha carried the same wrong middle. `daemon/CLAUDE.md`'s length-policy rule is still true unchanged. **Owner-owed: nothing to run.** The spec says this is closable on tests alone, and staging a repro would mean undoing REC12 and REC13; walkthrough step 2 is explicitly optional and opportunistic. The only remainder is the owner's close word.
---

# REC14: the merge's no-readable-duration fallback ends with the mic, so an unclean exit discards the longer system leg

Band origin: filed 2026-08-17, surfaced by REC13's 2026-08-14 incident and approved by the owner the same day for its own row rather than folded into that fix. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## The fallback

`RecordingPostProcessor.mergeLengths` ([RecordingPostProcessor.swift:89-101](../../../daemon/Sources/MeetingPipe/RecordingPostProcessor.swift#L89)):

```swift
guard let mic = micDurationSec, let system = systemDurationSec else {
    return MergeLengths(systemDelayMs: delayMs, padMic: false,
                        targetDurationSec: nil, expectedDurationSec: micDurationSec)
}
```

With either duration unreadable it pads only the system leg and sets no `-t`, so the merge ends with the **mic**. REC9 shipped that bias deliberately and documented it: the mic is the channel the owner cannot re-obtain. On the normal path it is correct and this task does not touch it.

## Why the bias is backwards in the case that actually fires it

The durations come from the RIFF header, and a header is finalized when the file handle is dropped. So a duration is unreadable almost exclusively because the process died without closing its files. In that case the reasoning behind the bias inverts: the system leg is no more re-obtainable than the mic, because both are partial captures of a call that already ended.

The fallback is therefore most likely to run in exactly the situation where its premise does not hold.

## The measured cost, once

`20260814-163455`, the REC13 incident. The recording was stopped by the owner at 17:31:43, the stop deadlocked, and `kill -9` was required.

| Reading | Value |
|---|---|
| Wall clock | 113 minutes |
| Final duration | 2798.5 s (46.6 min) |
| Transcript ends at | 2695.7 s |
| `.mic.wav` | 537,310,524 bytes |
| `.system.wav` at kill | 1,314,082,816 bytes |

Roughly 67 minutes of the far side of the call was discarded. ffmpeg said why in its own output: `Estimating duration from bitrate, this may be inaccurate`, `Packet corrupt (stream = 0, dts = NOPTS)`, `corrupt input packet in stream 0`.

Orphan recovery itself worked perfectly (`recovered orphaned recording -> 20260814-163455.wav mode=auto`, then queued, summarized and published). Nothing was lost to the recovery machinery; the loss is entirely in the length policy.

## What changed under this task before it was filed

REC13 shipped on 2026-08-17 and removed the chain that produced this instance: the config-change deadlock is fixed at the root, the stop path is bounded, and quit now force-exits at 9 s leaving intermediates for the orphan sweep instead of needing `kill -9`.

So the trigger is much rarer than it was, and that is the honest reason this is filed P2 rather than P1. It is not gone. Any crash, `SIGKILL`, panic or power loss still reaches orphan recovery with unfinalized headers, and the daemon has four recorded aborts in 36 hours as recently as 2026-08-14 (REC12, also fixed 2026-08-17).

## Scope

The fallback only. The pickup answers one question, and the two candidate routes are not equivalent:

**Route A, prefer the longer leg.** Re-bias the guard so an unreadable duration ends with whichever leg is longer rather than always the mic. Small, local, and it fixes the observed loss. It stays a heuristic, and it silently reverses REC9's stated preference in the one case REC9 was reasoning about, so it needs a comment saying which case each branch serves.

**Route B, derive the duration instead of falling back.** For uncompressed PCM the duration is exact arithmetic over file size, sample rate, channel count and bit depth, so there is no need to guess a policy at all. This is not theoretical: `537,310,524` bytes at 48 kHz mono float32 is 2798.5 s exactly, and that arithmetic is what diagnosed the incident in the first place. Route B dissolves the fallback rather than re-biasing it, and is the likelier right answer.

**Confirm before committing to B:** that the format (sample rate, channel count, bit depth) is always known at that point in `produceFinal` and `recoverOrphan`, including on the orphan-recovery path where the writing process is gone. If it is not always known, B degrades to A rather than replacing it, and the task ships both.

## Explicitly not / out of scope

**Not REC9's normal-path length policy.** `apad` both legs, `adelay` a late system channel, `-t max(mic, offset + system)` behaved correctly throughout the incident and is not reopened. REC9 closed 2026-08-05.

**Not the mic-tap death at 17:21.** A device change killed the mic leg an hour before the stop and it never recovered, which is what made this incident's loss 67 minutes instead of a few seconds. That is REC8/REC10 territory and a distinct failure.

**Not the deadlock, the termination flush, or the stop path.** All REC13, shipped 2026-08-17.

**Not a change to what orphan recovery keeps.** It already keeps both intermediates and merges them; the defect is purely which length the merge targets.

## Acceptance

- A test drives `mergeLengths` with both durations unreadable and asserts the result no longer ends with the shorter leg. It must fail against `main`, which returns `padMic: false` with a nil `targetDurationSec`.
- A test drives the chosen route with a system leg longer than the mic leg and asserts the merged target covers the system leg, and a second with the mic longer asserts the mic still survives in full. Both directions, so the fix is not a mirror of the bug.
- If route B is taken, a test asserts the derived duration matches the RIFF-reported duration for a normal finalized file, and a test asserts it is still derived when the header is truncated or absent. The 2026-08-14 numbers above are a usable fixture.
- A test covers the orphan-recovery path specifically, since that is where an unreadable duration actually arrives.
- The chosen route and the reason the other was rejected are recorded in `mergeLengths`'s own comment, so the next reader does not re-litigate REC9's bias.
- `cd daemon && swift build` clean, `swift test` green, with the number of tests this task adds recorded in the ship note. Do not pin an absolute suite total.
- `python3 scripts/truth_fences.py both` green, with any new event action documented in the `CONVENTIONS.md` event table in the same commit.
- No em-dashes in changed lines; repo dash guard green.

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule. Steps are tagged [owner] / [session] by who acts.

This task is closable on tests alone, and the spec says so rather than pre-registering an observation the owner cannot make. Reproducing it needs an unclean kill mid-recording, which is the thing REC12 and REC13 were just fixed to prevent, so asking the owner to stage one would be asking them to undo those fixes.

1. [session] Land, then state in the ship note which route was taken and whether the format is always known at the merge point.
2. [owner] Optional and only if it happens naturally: if the app ever dies mid-recording again, confirm the recovered final covers the whole call rather than ending with the mic. A `duration_parity_low` event or a "Recording is shorter than the meeting" notice is the signal to look for.
3. [owner] Say "REC14 good to close" (or what is wrong); [session] moves the row and this spec into `q6-final.md` and deletes this file.
