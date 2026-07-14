# END6 spike: the device-idle end corroborator (closed, refuted)

Spike, 2026-07-14. Probe: [`daemon/scripts/end6-device-idle-probe.swift`](../../daemon/scripts/end6-device-idle-probe.swift), run on the owner's Mac (macOS 26.x, Apple Silicon). Unlike the CAL1 / MIC7 / DET2 / MIC8 probes, this one is **already run**: its blocking question turned out not to need a live meeting, so the verdict below is measured, not owed.

## Question

END6 shipped its load-bearing half (the correlated-pair gate: ax-leave and window-gone fused into one `EndEvidenceClass` that cannot self-corroborate). The remainder was to land `kAudioDevicePropertyDeviceIsRunningSomewhere` as "the genuinely independent corroborator" for native meeting ends, and the backlog carried it as owner-owed pending live-Mac validation.

The premise came from the design-time research doc ([`docs/architecture/signal-fusion-and-mic-gating.md`](../architecture/signal-fusion-and-mic-gating.md), PART A): the device-scope read "fires only when the last client on the input device releases it", coarser than the per-process read but usable as corroboration. **The claim never accounted for the daemon itself being one of those clients.** So the question to measure is not what Teams does to the flag, it is what *our own recorder* does to it. That needs no meeting, only our own capture.

## Method

Three snapshots of every audio device on the machine: baseline, then while an `AVAudioEngine` input tap runs (the exact shape `MeetingRecorder` uses), then after stop.

## Result: refuted, and wider than expected

```
--- BASELINE (nothing of ours capturing) ---
  LG HDR 4K                          in:0 out:2  idle
  BlackHole 2ch                      in:2 out:2  idle
  MacBook Pro Microphone             in:1 out:0  idle        DEFAULT-IN
  MacBook Pro Speakers               in:0 out:2  idle        DEFAULT-OUT

--- WHILE OUR OWN AVAudioEngine INPUT TAP RUNS ---
  LG HDR 4K                          in:0 out:2  idle
  BlackHole 2ch                      in:2 out:2  idle
  MacBook Pro Microphone             in:1 out:0  RUNNING     DEFAULT-IN
  MacBook Pro Speakers               in:0 out:2  RUNNING     DEFAULT-OUT
  CADefaultDeviceAggregate-99467-0   in:1 out:2  RUNNING

--- AFTER STOP ---
  (every device back to idle)
```

The input confound the backlog predicted is real: while we record, the default input always reads RUNNING, so it can never read idle, so it can never signal an end.

The new part is the **output** device. `AVAudioEngine.inputNode` instantiates a `CADefaultDeviceAggregate` (`in:1 out:2`) that spans **both directions**, so tapping the mic also pins the default output RUNNING for the whole recording. That kills the obvious rescue: "read the speaker side instead, since a call client renders remote audio and stops when the call ends." It cannot be read either. While the daemon records, **no device on this machine carries any information about the meeting client, in either direction.** The signal is not noisy, it is structurally blind.

Mic TCC is irrelevant to the reading: the flag tracks whether an IOProc is running on the device, not whether real samples flow, so an unauthorized engine (silent buffers) pins it identically. The probe prints the TCC status so a future run stays interpretable.

## It would also not have helped

Measured over the real event log since the correlated-pair gate landed (2026-06-28), across 25 native endings:

| What ended the meeting | n | Latency |
|---|---|---|
| AX re-walk (`confirmProvisionalEnd`) | 22 of 23 provisionals | **median 0.17 s**, max 0.38 s |
| Debounce, window-gone lead | 1 | 6.0 s |
| Idle-stop backstop auto-stop | **0** | n/a |
| Force stop | **0** | n/a |

Native end detection already confirms in about a fifth of a second. A 1 Hz polled HAL boolean could not improve on that even if it worked. The backlog's own note ("the AX re-walk already backstops native corroboration, so this leg is not load-bearing") is confirmed by the numbers: the re-walk is not the backstop, it is the primary path, and it is fast.

## And it would have been net-negative

A signal in a new `EndEvidenceClass` instant-promotes a provisional end through `PromotionEngine.handleEndingProvisional`'s cross-class fast path, with no debounce. A device-scope idle read is by definition **device-global**: it is shared with every other app's audio. Wiring it as a cross-class corroborator would create the one signal in the system capable of instantly confirming a *false* ax-leave, which is precisely the fragmentation hole the correlated-pair gate was built to close. The safest possible version of this signal is still strictly worse than not having it.

## The gate itself is validated (the owner-owed dogfood trace, settled)

END6 also carried an owner-owed "screen-share dogfood trace" to measure residual fragmentation frequency. The event log answers it. Fragmentation signature: an `.ended` followed by a `.starting` for the same pid within 3 minutes.

| Era | Native ends | Same-pid restart within 3 min |
|---|---|---|
| Pre-gate (before 2026-06-28) | 82 | 12 (15%), including the documented 4-fragment screen-share incident |
| Post-gate | 22 | 1 (5%), and it chopped nothing (below) |

The single post-gate restart (2026-07-02, pid 630) is **not** an end-side chop. The end was correctly confirmed by the re-walk at 14:17:41, the recording stopped, the pipeline ran and the summary succeeded. Seventy-eight seconds later Teams re-rendered a call-shaped window (`found_leave: true`, `window_count: 2`) and the daemon prompted; the prompt timed out to skip and **recorded nothing**. That is a start-side false prompt (DET-band territory), not a fragmented recording. **Post-gate, zero recordings were chopped.**

## Decision: close the leg

END6 is done. The correlated-pair gate shipped and is validated in production; the device-idle leg is refuted by measurement, not deferred for want of effort. Nothing was built, deliberately.

Closing leaves no hole, because every genuinely independent end corroborator is already owned elsewhere:

- **Per-process audio (`kAudioProcessPropertyIsRunningInput`)** is the unconfounded read: it asks about the meeting client's process, so our own IOProc cannot blind it. That is **DET2**, which is already probe-gated and owner-owed. It is the right home for this need.
- **Calendar end horizon** is **CAL1**, likewise probe-gated.
- **An AX-free end path already exists and works.** Window-gone comes from ScreenCaptureKit, not AX, and led 12 historical ends on the debounce, so an AX regression does not leave native end detection with nothing. The idle-stop backstop remains the ceiling.

## Follow-on

- If a future macOS changes the aggregate behaviour, re-running the probe is the check: its verdict line explicitly distinguishes "input pinned, output free" (a narrow re-open, with the two standing objections restated) from "not reproduced".
- The design-time claim that seeded this leg is corrected in [`signal-fusion-and-mic-gating.md`](../architecture/signal-fusion-and-mic-gating.md) PART A, so the next reader does not re-propose the dead signal from the same source.
