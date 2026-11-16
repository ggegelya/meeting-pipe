---
id: END23
title: Stop a Teams-sourced recording 120 s after the Teams family releases the microphone, whatever the end engine believes
category: Detection
status: partial
priority: P2
comment: Shipped 2026-11-17 for Teams: pure MicReleaseCeiling (Core) on DET23's monitor, a per-recording 1 Hz host tick that stops a native Teams recording 120 s into a monitor-read release whatever the engine reads, releasing any hold unconcluded and cutting at the release (suggested under lossless, truncated under regulated/NDA), coordinator/mic_release_ceiling_stop. Remainder: the two-week field exit (owner walkthrough), and Zoom (DET24 Z1), Webex and Slack (a measured call each).
---

# END23: Stop a Teams-sourced recording 120 s after the Teams family releases the microphone, whatever the end engine believes

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: stage 6 ("Teams-only independent stop") of the staged plan in the [recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md), section "Recommended target design", and graft 2 in the [research and designs](../../audits/2026-11-13-recording-reliability-research-and-designs.md) critics' section ("add one independent stop, holder released 120 s and still recording"). Field numbers are from the [field evidence](../../audits/2026-11-13-field-evidence.md) and the [reliability evidence](../../audits/2026-11-13-recording-reliability-evidence.md).

**The three overruns, each with the release in the log.**

- Stem 20261006-163051 (era A, build ae035d58): a mic-led provisional stayed open 562 s until `coordinator`/`auto_stop_silence` at 2026-10-06T14:43:59.495Z, with 550 s of tail after the last transcribed speech. The last Leave reading was healthy and a `lifecycle_provisional_end_rescued` row had re-armed it, so nothing corroborated the mic release.
- Stem 20261008-163049 (era A): the mic released 63 s before a hand stop, same shape.
- Stem 20261112-174606 (era C, the newest field build): a resumed recording ran on an engine that was already `.ended` (the first-reading race, [END20](./END20.md)); process audio went false at 2026-11-12T15:50:34.737Z and the owner stopped it by hand at 15:56:54.489Z. The idle backstop never accrued, because the MicGate verdict read hot by RMS except for stretches of 56.9, 2.4 and 25.0 s.

**Why nothing bounds these at HEAD** (re-read 2026-11-13).

- END13's 7200 s live-signal ceiling is gone: `CallTeardownOracle`'s header lists "a 7200 s ceiling above END13's veto (`live_signal_ceiling_reached`)" among the confirms [END17](./END17.md) retired, and no other wall-clock bound exists.
- `PromotionEngine`'s dwells (`defaultConfirmDwell = 60`, `defaultLoneDwell = 720`) act only while the engine is in `.endingProvisional`. A terminal engine, an engine that was never engaged (a source-less start, [END11](./END11.md)), or a hold that a stale same-class reading reverted ([END18](./END18.md)) has no dwell running.
- The idle backstop is not a ceiling ([END25](./END25.md)): `SilenceAutoStopPolicy.shouldAutoStop` returns false for `sourceKind == .native, lifecycleIsLive`, after which `handleIdleAutoStop` calls `silenceBackstop.keepAlive()` with no count; and `IdleStopBackstop.ingest` restarts the streak on any hot verdict or live system audio.
- The engine's own process-audio voter cannot serve as the bound: `ProcessAudioSignal` runs only while an adapter is engaged, its `AdaptivePollCadence` backs off from 1 s to 5 s after three steady polls, and its release is a vote inside the engine that a terminal or reverted engine discards. The bound has to read a monitor that does not depend on the engine, which is what [DET23](./DET23.md) builds.

**Why 120 s.** The longest same-call mic gaps on record are 23.1 s on 2026-11-12 (stem 20261112-172307, a mic-led hold that reverted at 22.0 s when process audio returned) and at most 23.5 s on 2026-10-22 ([END15](./END15.md)); each was sampled through a poll that adds up to 5 s, so the true bound is about 28.5 s. 120 s is four times that, and a release held that long has never been a live call in the pack.

Correction at filing: the third overrun is 379.8 s between the release and the hand stop (the reports round it to 380 s or 381 s). The two era A overruns ran on a build before END17, so at HEAD the same Leave-healthy shape would sit in a hold that END17's dwells end at 60 s or 720 s while the engine stays in `.endingProvisional`; the era C case shows the engine need not stay there, which is the gap this task closes.

## Scope

Lands after [DET23](./DET23.md) (the always-on 1 Hz `MicHolderMonitor`, log-only) is in and publishing per-family samples.

1. **A pure policy in Core.** A small type beside the monitor (for example `MicReleaseCeiling`) fed the monitor's samples for the recording's family. A `held == false` sample starts the release clock at that sample's time; `held == true` clears it; `unknown` (including a sample older than the monitor's freshness bound) pauses it without advancing or clearing. When the family has read released continuously for 120 s it returns a stop decision carrying the cut, which is the time of the first false sample of that release. No clock of its own, no AX, no I/O, matching `CallTeardownOracle.decide`.
2. **Scoped to Teams.** It applies only when the running recording's source bundle belongs to the Teams family (`com.microsoft.teams2`, `com.microsoft.teams`) as the monitor's registry defines it. Zoom joins only after [DET24](./DET24.md) records bar Z1 as pass; Webex and Slack each only after one measured call. A source-less (manual) recording is not touched here; its end is END11's.
3. **The host stop, independent of the engine.** `MeetingSessionController` consumes the decision on main and stops through `stopRecording`, whatever `lifecycleCoord.current` reads (`inMeeting`, `endingProvisional`, `ended`, or not engaged) and whether or not a teardown hold is open. An open hold is released first. The cut is written the way a held end's is: the trim key suggested and the tail kept under lossless capture, the tail truncated at stop under the regulated and NDA postures, per ADR [0017](../../decisions/0017-hold-long-trim-later-end-detection.md). If [END21](./END21.md) has landed, use its per-route trim computation; otherwise set `pendingEndTrimAt` to the cut immediately before the stop.
4. **The event.** `coordinator`/`mic_release_ceiling_stop` with `bundle_id`, `file`, `released_at`, `released_sec`, `engine_phase` and `hold_open`, documented in `CONVENTIONS.md#event-log-schema`. If [OBS5](./OBS5.md)'s stop-cause attribute has landed, the `recording_stopped` row carries cause `mic_release_ceiling`.

## Explicitly not

- Replacing or tuning `PromotionEngine`, its dwells, or `CallTeardownOracle`: the engine stays the normal end path and this bound sits behind it. A reducer as the Teams end authority is [END26](./END26.md), behind its gate.
- Reading `ProcessAudioSignal` as the input: it is engagement-bound and backed off (above).
- Browser families: the pack has 0 browser mic rows, and DET24's bars B1 to B3 decide whether a browser release means anything.
- Changing the idle backstop ([END25](./END25.md)) or the held-end trim point on other routes ([END21](./END21.md)).
- The first-reading race that produced the terminal engine in stem 20261112-174606: [END20](./END20.md). This task bounds its cost; it does not fix it.

## Acceptance

- `MeetingPipeCoreTests`, new tests on the policy: a Teams release held 120 s returns a stop with the cut at the first false sample; a 23 s false gap followed by true (the 2026-11-12 device-switch shape) returns nothing and clears the clock; `unknown` samples inside a release pause the clock (a 100 s release, 30 s unknown, 20 s false stops at 120 s of false, not earlier); a Zoom-sourced recording with a 300 s release returns nothing.
- `MeetingPipeTests`, host tests: with the engine in `.ended` and the recorder running (the stem 20261112-174606 shape), a 120 s release stops the recording, logs `mic_release_ceiling_stop` and records the cut at the release; with a teardown hold open, the same stop releases the hold and leaves no hold timer running; a lossless capture writes the suggested trim and a regulated capture truncates.
- `cd daemon && swift test` green, with the number of tests this task adds in the commit body; `swift build -c release` clean; `bash scripts/ci-local.sh` green; `python3 scripts/truth_fences.py` clean with the new event documented.
- Field exit, two weeks from the install of the landing build: no Teams recording ends more than 130 s after its final release, and no `mic_release_ceiling_stop` fires on a call the owner says was still up.

## Owner walkthrough

1. [session] Confirm the installed build is newer than the landing commit (`./scripts/rebuild.sh` if not).
2. [owner] Two weeks of normal Teams use. Once, mid-call, switch the input device and switch it back; the recording must keep running. Cost: no extra calls.
3. [session] For every Teams recording in those two weeks, report stop time minus the final monitor release, and list every `mic_release_ceiling_stop` with its stem and release time.
4. [owner] Label each listed stop as right or wrong. One wrong stop fails the exit and holds Zoom's enablement.

**Progress (2026-11-17): shipped for Teams; field exit, one owner question and the other apps remain.**

What landed: `MicReleaseCeiling` (Core, pure) and `MeetingSessionController+MicReleaseCeiling.swift` (the host), reading DET23's `MicHolderMonitor` through `SessionHost.micHolderFeed.currentSnapshot()`. Armed at a recording's commit (prompt, explicit, resumed and split starts all commit there) when the source is native Teams (`com.microsoft.teams2` or `com.microsoft.teams`); disarmed in `stopRecording`. Decisions that were not in the spec, all from the Opus design review:

- **The cut is the monitor's `leftHeldAt`** (the first non-held sample after a hold, newly published on `MicHolderMonitor.Reading`), the later of the two Teams families', not the host's first released read and not the reading's `since` (which moves on a vanish's 5 s unknown, and classic Teams usually reads released from launch). A `leftHeldAt` that moved means a hold too short for the 1 Hz host to see, and restarts the clock.
- **The cut is fixed on the wall clock when the release is first seen**, because the monitor's clock (`systemUptime`) stops across sleep and the wall clock does not; converting at the stop put the cut late by the whole sleep.
- **Each sample credits at most 2 s**, so a stalled main run loop never credits an unobserved gap.
- **The open hold is released, not concluded.** END21's per-route `trimPoint` needs an open hold and, under its Stop rule, refuses a cut whenever the engine still reads the mic live; the 20261112-174606 shape has no hold at all. So `pendingEndTrimAt` is set to the monitor's cut directly, which is the spec's fallback path, and `held_end_trimmed` says `stop_route: mic_release_ceiling`.
- **END29 reconciled:** the ceiling stops whether or not the Leave button reads live. END29 guards a return the engagement-bound `ProcessAudioSignal` can miss on a stale object; the monitor re-enumerates the list every second, the audit measured in-app mute never releasing the flag, and both era A overruns had the Leave button live. The row carries `live_signal` so a ceiling stop over a live call UI is findable at walkthrough step 4.
- **Owner decision (2026-11-17, approved the narrower rule):** the clock runs only for a release that began inside the recording, after Teams held the mic during it (`leftHeldAt >= the arm time`), so a Teams recording started before the call opens the mic is not stopped at 120 s and the cut can never fall before the file's start (where `stopRecording` drops it silently). The cost is a resumed recording onto a call that is already dead and never re-held stays unbounded, as at HEAD. All three audit stems held the mic during the recording. The owner accepted that known cost: a recording resumed onto an already-dead call that Teams never re-holds stays unbounded, as at HEAD.

Not built: OBS5's stop cause (OBS5 has not landed, so `recording_stopped` carries no cause). Tests: 9 `MicReleaseCeilingTests`, 8 `MicReleaseCeilingHostTests` (an ended engine, an open hold released with no timer left, an open hold whose own END21 evidence would have moved the cut (red with the release line removed), regulated truncation, a sleep between release and stop, a tick after the stop, a 23 s gap, arming only for native Teams).
