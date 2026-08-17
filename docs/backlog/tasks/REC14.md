# REC14: the merge's no-readable-duration fallback ends with the mic, so an unclean exit discards the longer system leg

Band origin: filed 2026-08-17, surfaced by REC13's 2026-08-14 incident and approved by the owner the same day for its own row rather than folded into that fix. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

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
