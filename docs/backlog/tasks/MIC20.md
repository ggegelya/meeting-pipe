---
id: MIC20
title: The AX mute probe logs an unreadable button every second, keeps polling after an end is held, and logs nothing when its re-resolve fails
category: Recording
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). AXMuteButtonProbe emits ax_mute_button_state_kept on every unknown read after a known one: 1,772 rows, 1,153 after lifecycle_end_held, 677 rows (39 percent) of the newest build's events; a 379 s streak in 20261112-174606 shows 0 ax_mute_button_rearmed because a failed re-resolve is silent. Log the kept state once per streak with a count at stop, log a failed re-resolve, back the probe off while an end is held, and pin that a resumed recording engages a fresh probe.
---

# MIC20: the AX mute probe logs an unreadable button every second, keeps polling after an end is held, and logs nothing when its re-resolve fails

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

**Sources.** [Field evidence](../../audits/2026-11-13-field-evidence.md), "AX probe logs an unreadable mute button once a second, mostly while an end is being held" (mic and mute section) and "New chatter in the newest build: ax_mute_button_state_kept" (daemon health section), plus its metrics row "AX probe unreadable rows". Not in the [independent audit](../../audits/2026-11-12-independent-audit.md) as such; its F046 covers the resume path's routing, not the probe.

**The code, re-verified at HEAD on 2026-11-13.** `AXMuteButtonProbe.evaluate(reason:generation:)` reads the cached element on every health poll. When the read decodes to `.unknown` after a known state, it returns early through the latch branch (`if state == .unknown, let prev = lastEvent, prev.state != .unknown`) and emits `ax_mute_button_state_kept` every time, with no streak memory, because the early return never updates `lastEvent`. `AdaptivePollCadence.intervalAfterPoll` returns the cadence to fast on `.unknown`, and `defaultPollInterval` is 1.0 s, so an unreadable button logs one row a second for as long as it stays unreadable. Every `defaultRearmThreshold` (5) unknown reads, `noteUnknownAndMaybeRearm` calls `resolveElement`; on success it emits `ax_mute_button_rearmed`, but `guard let fresh = resolve(), isCurrent(generation) else { return }` returns silently when the walk finds nothing, so a probe that tried and failed and a probe that never tried look the same in the log.

**The probe keeps running through a held end.** Since END17 a weak end opens `MeetingSessionController.beginTeardownHold` (`lifecycle_end_held`) with the recorder still running, and `coordinator.micGate.stop()` runs only in `stopRecording`. The call UI is usually gone during a hold, so the probe reads unknown for up to the hold's dwell, then the row stops only when the recording does.

**Field numbers (work laptop, 2026-09-29 to 2026-11-13).** 1,772 `ax_mute_button_state_kept` rows; per recorded hour 68, 17 and 486 by build era. 1,153 come after `lifecycle_end_held` (664, 193, 296 by era). In-call streaks are short in eras 1 and 2 (median 4 s and 2 s), but era 3 has one 379 s streak in 20261112-174606 with 0 `ax_mute_button_rearmed` rows. In era C the row is 677 of 1,727 rows (39 percent), `reason` `health_poll` on all but 3, at about 233 bytes a row the largest single action in that era, which feeds the retention problem filed as [OBS9](./OBS9.md).

Correction at filing: the batch premise was that the probe "is not re-armed when a recording resumes". At HEAD a resume goes through `beginRecording` (the `recording_resumed_after_end` branch), which builds fresh handles and reaches `engageMicGate` through `attachWhenBuilt` and `attachRecordStart` like any start, after `stopRecording` stopped the previous `MicGate`. The 379 s streak in 20261112-174606 sits inside that recording's 382 s tail after the call had already ended (the resumed recording whose lifecycle was dead, [END20](./END20.md) and audit F046), so the zero re-arms are failed re-resolves the probe does not log, against a call UI that no longer existed. The resume leg is therefore a pinning test here, not a fix; the lifecycle side of that recording belongs to END20.

## Scope

1. **Kept state on change only.** In `AXMuteButtonProbe.evaluate`, emit `ax_mute_button_state_kept` once at the start of an unknown streak (as today's row, plus nothing new), and count the streak's reads instead of logging each one. When the streak ends (a known read) or the probe tears down (`stop()` / `teardown()`), emit one summary row with the streak count and its length in seconds.
2. **Log a failed re-resolve.** In `noteUnknownAndMaybeRearm`, when `resolve()` returns nil, emit `ax_mute_button_rearm_failed` once per streak (with the attempt count carried on the summary row), so "tried and found nothing" is distinguishable from "never tried".
3. **Back off while an end is held.** `beginTeardownHold` tells MicGate an end is held and `releaseTeardownHold` clears it (both paths: confirmed and `rescued`). While held, the probe polls at the slow cadence and emits no kept rows; a known read during the hold still flows (a rescued call must read its mute at once). The flag reaches the probe through `MicGate` and its adapter (`NativeMuteAdapter`), not through a global.
4. **Pin the resume path.** A test that a recording started from the resume branch engages `MicGate` on freshly built handles (a new probe generation, `micgate_attached` with `via` build or deadline), so a future change to that branch cannot leave the previous recording's probe in place.

## Explicitly not

- The resumed recording's dead lifecycle and its 382 s tail: [END20](./END20.md). Log retention as a whole: [OBS9](./OBS9.md).
- The window watcher's own blind-clear rows: [MIC19](./MIC19.md). They fire once per streak already.
- Stopping the probe outright during a hold: a rescued hold must read the mute state again without a re-engage.

## Acceptance

- `AXMuteButtonProbe` tests: known then N unknown reads emit exactly one `ax_mute_button_state_kept` and, at the next known read or at `stop()`, one summary row carrying N; a resolver that returns nil emits one `ax_mute_button_rearm_failed` per streak; a resolver that succeeds still emits `ax_mute_button_rearmed`.
- A held-end test: with the held flag set, the cadence stays slow and no kept rows are emitted across unknown reads; clearing the flag restores the fast cadence on the next unknown read; a known read during the hold is delivered.
- A `MeetingSessionController` test that `beginTeardownHold` sets and `releaseTeardownHold` (rescued and confirmed) clears the held flag, and the resume pin from item 4.
- Existing `AXMuteButtonProbe` and PERF19 cadence tests stay green; the new actions and attributes documented in `CONVENTIONS.md`'s event-log schema; `swift test` and `bash scripts/ci-local.sh` green, with the number of tests added in the commit body.
- After a week on the landed build, `ax_mute_button_state_kept` rows per recorded hour are reported in this file against the era figures above.
