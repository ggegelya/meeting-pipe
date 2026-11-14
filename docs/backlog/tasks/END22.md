---
id: END22
title: The session layer ignores sleep, wake, lock and display changes and measures every dwell on the wall clock, so a sleep inside an open hold confirms the end on the first tick after wake
category: Detection
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). Only MeetingRecorder observes wake and every lifecycle dwell, the hold stamp, the cooldown, the 120 s resume window and the prompt timeout run on Date(), so a sleep longer than a dwell inside a hold confirms before any signal re-reads; consistent with the code, unproven in the field (3 display topology changes in recorder.log, none during a recording). On wake mark every oracle unknown and require one fresh reading before a dwell may confirm, on a sleep-excluding clock.
---

# END22: The session layer ignores sleep, wake, lock and display changes and measures every dwell on the wall clock, so a sleep inside an open hold confirms the end on the first tick after wake

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source finding: D076 (low, "consistent but unproven") in the [recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md). Re-verified against HEAD `3a2da4fc` on 2026-11-13 by code reading.

**Nothing above the recorder hears a sleep.** The only `NSWorkspace.didWakeNotification` observer in `daemon/Sources` is `MeetingRecorder`'s (REC8: it re-arms capture after a wake). The only display observer is `SystemAudioCapture`'s `NSApplication.didChangeScreenParametersNotification`, which clears a cache. No code observes `willSleepNotification`, screen sleep or wake, or a session lock.

**Every session-layer window is wall-clock.** `MeetingLifecycleCoordinator` ticks the engine with `engine.tick(at: self.clock())`, whose default clock is `{ Date() }`; `PromotionEngine.tick` compares `now` with the hold's `startedAt` (`loneHeld = now.timeIntervalSince(startedAt) >= loneDwell`) and with each signal's ended stamp for the pair dwell. `MeetingSessionController.beginTeardownHold` stamps the hold with `holdPolicy.open(context: context, at: Date())`. The reprompt cooldown, the skip latch grace, `ResumeAfterEnd.applies(to:at:)` (`sinceEnd <= Self.windowSec`, 120 s, checked with `Date()` in `handleMeetingStarted` and `handleDiscovery`), the prompt timeout and the silence backstop's streak are all measured the same way. `Date()` advances across a sleep; the signals, which poll or listen, do not report anything while asleep.

**What that does.** (1) A sleep longer than `PromotionEngine.defaultLoneDwell` (720 s) inside an open hold, or longer than `defaultConfirmDwell` (60 s) with two weak classes ended, confirms the end on the first tick after wake, before process audio, the window or the Leave control has re-read; the hold's trim point is then the pre-sleep stamp. (2) A sleep longer than 120 s after an end closes the resume window, so a call the Mac slept through prompts instead of resuming. (3) `ShareableContentSignal` reads on-screen windows, so docking, undocking or moving the call to another Space can read as window-gone; on the native path END14's live-mic veto usually absorbs it, on the browser path it opens a hold.

**Field.** Consistent but unproven. recorder.log shows three display topology changes, none during a recording; the pack has no recording that spans a sleep. Lid-close during a call is a plausible owner habit on a laptop, and REC16 already tracks the capture gap a sleep leaves in the audio.

## Scope

1. **Wake resets what the engine believes.** Observe `NSWorkspace.didWakeNotification` (and `screensDidWakeNotification` plus `NSWorkspace.sessionDidBecomeActiveNotification` for unlock) in `MeetingSessionController` or `MeetingLifecycleCoordinator`; on wake, have `PromotionEngine` mark every signal's reading unknown (a new public method, pure, on the engine) and require at least one fresh reading from a signal before either dwell may confirm. Log `lifecycle_wake_reset` (`lifecycle` category, `bundle_id`, `phase`, `reset_signals`, `asleep_sec`).
2. **Dwells on a clock that excludes sleep.** Inject `ProcessInfo.processInfo.systemUptime` (which stops during sleep) into the dwell and hold arithmetic, as `LowSpaceWatch` and `MuteControlCache` already do, keeping `Date()` only for event-log timestamps. The resume window and the reprompt cooldown move to the same clock, so a sleep neither closes nor spends them.
3. **Display changes.** On `didChangeScreenParametersNotification`, treat a window-gone reading that lands within a short settle window as unknown rather than ended; the settle value goes beside its constant with the reasoning.

## Explicitly not

- The capture gap across sleep and the recorder's re-arm: [REC16](./REC16.md) and [REC8](./REC8.md).
- Where the trim lands once a hold confirms: END21. The browser end signal's liveness generally: DET20.
- Pausing a recording on lock or sleep; this task changes only what the session decides from its signals.

## Acceptance

- `PromotionEngine` tests with a fake clock: an `.endingProvisional` hold, a simulated sleep longer than `loneDwell`, then `tick` before any post-wake reading does not confirm; after one fresh `.ended` reading and the dwell measured on the sleep-excluding clock, it does. The same for the pair dwell.
- A wake reset with process audio returning `.live` reverts the hold.
- `MeetingSessionController` test: an end, a 200 s sleep, then the same bundle's `.starting`; the resume still applies.
- A display-change test: a window-gone inside the settle window after a screen-parameters change opens no hold.
- `lifecycle_wake_reset` documented in `CONVENTIONS.md`; `python3 scripts/truth_fences.py events` green.
- `cd daemon && swift test` green with N new tests named in the commit body; `bash scripts/ci-local.sh` green.

## Owner walkthrough

1. [session] Confirm the installed build is newer than the landing commit.
2. [owner] Once, during a test call with the recording running, close the lid for about 2 minutes, open it, stay in the call for a minute, then end it. Pass: one recording that ends after the call ends, not on wake.
3. [session] Grep `events.jsonl` for `lifecycle_wake_reset` and the `lifecycle ended` row that followed it, and report the gap.
