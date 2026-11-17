---
id: END22
title: The session layer ignores sleep, wake, lock and display changes and measures every dwell on the wall clock, so a sleep inside an open hold confirms the end on the first tick after wake
category: Detection
status: partial
priority: P2
comment: Shipped 2026-11-17: dwells (pair, lone, END27 grace) on awake time via the engine's sleep intervals; a wake gate needing a fresh post-wake live or ended reading (the vetoer's own where engaged) or a 10 s awake bound; the coordinator detects sleep from its wall-vs-uptime gap (beats the didWake race) and asks the adapter to re-publish; SleepWakeObserver (wake, screen wake, unlock, display change) as a SessionWatchers member; a window-gone deferred 5 s after a display change; cooldown and resume window on systemUptime, resume capped at 10 min wall; idle backstop restarts its streak across a sample gap over 30 s. Owner approved the 10 min resume wall cap and the uncapped awake-time cooldown (2026-11-17). Remainder: the owner walkthrough (a lid-close during a test call).
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

**Progress (2026-11-17): shipped; the owner walkthrough remains.**

Designed with an Opus review, which changed four things from the first draft:

- **The stamps were not moved to `systemUptime`; the sleep is subtracted from the dwells instead.** `PromotionEngine` keeps the engagement's sleep intervals and every dwell (the pair, the lone dwell, END27's vetoer grace) uses `awake(from:to:)`. The stamps are trim positions (END21's `releasedAt`, the hold start) and are compared with Teams' wall-clock log, so they stay wall-clock. This meets the spec's "dwells on a sleep-excluding clock" without moving a cut.
- **"Mark every oracle unknown" is a gate, not an overwrite.** Overwriting the readings would lose END21's release stamp and the pair stamps, and `record` takes `.unknown` only over `.live`. Instead no dwell confirms until a `.live` or `.ended` stamped after the wake arrives (not a pre-sleep event drained late, not an `.unknown` from objects re-registering, and the vetoer's own reading where the engagement has one), or 10 s of awake time passes. Signals emit only on change, so the coordinator asks the adapter to re-publish (`LifecycleAdapter.refreshReadings()`, new; `ProcessAudioSignal.refresh` and `ShareableContentSignal.refresh` forget the last value and evaluate once). A pre-sleep live mic keeps vetoing until it is re-read.
- **The coordinator detects the sleep itself** from the wall clock outrunning `systemUptime` on any tick or ingest, because its first tick after a wake can beat the `didWake` notification to the engine queue, and that tick would confirm exactly as before. The host notification adds the reason, and the screen-wake and unlock cases (fresh-reading gate only; an unlock does not touch the dwells).
- **The idle backstop** was named in the spec's Context but not its Scope; its wall-clock silence streak would auto-stop a recording on the first silent sample after a wake that followed a quiet stretch. `IdleStopBackstop.ingest` restarts the streak when two samples are more than 30 s apart (the level callback runs about once a second), measured from the gap so it cannot race the wake notification.

Other decisions not in the spec: unlock is the distributed `com.apple.screenIsUnlocked` (the spec's `sessionDidBecomeActiveNotification` is fast user switching); a display-change window-gone is deferred 5 s and ingested stamped at the settle's end unless a newer window reading supersedes it (mapping it to `.unknown` would have starved a browser meeting's only end class); the 5 s settle is unmeasured, since none of the four topology changes in the owner's recorder.log fell in a call. The host hold stamp stays wall-clock (a trim position, compared with Teams' log); DET18's offer needed nothing (`SkippedMeetingLatch` caps each feed gap at one idle poll, pinned by `SkippedMeetingLatchTests`); the prompt timeout is left as it is.

**Owner decision (2026-11-17): approved as shipped.** The resume window is 120 s of awake time and at most 10 min of wall time since the end (`ResumeAfterEnd.wallCapSec`), so a short lid-close mid-call still resumes and an overnight one prompts instead of silently resuming yesterday's recording. The reprompt cooldown is on awake time with no wall cap. The known cost: a sleep longer than 10 min that falls inside the 120 s window (the lid closed within two minutes of a call ending) prompts on wake even if the same call is still running, where the spec's pure awake-time rule would have resumed it.

Opus review of the diff, fixed before landing: `ProcessAudioSignal.refresh` forces a re-delivery instead of clearing `lastValue` (clearing it skipped END17's unknown delivery for a live mic whose objects vanished while asleep, leaving its veto in place for ever); the backstop restart moved from a wake handler into the backstop's own sample gap (the handler raced the first post-wake sample); a deferred window-gone is dropped on disengage; the clock sample restarts with each engagement and a small clock step just after a wake is not a second sleep.

Tests: 10 `PromotionEngineWakeTests`, 6 new `MeetingLifecycleCoordinatorTests` (the tick-before-notification race, a wake applied once, an unlock, the display deferral superseded, ingested and dying with its engagement), 3 `SleepWakeSessionTests` (a 200 s sleep still resumes, the window's awake count and wall cap, the cooldown), 1 `IdleStopBackstopTests` (a sample gap restarts the streak), 1 `ProcessAudioSignalTests` (a refresh re-delivers and keeps the unknown path), and one `SessionWatchersTests` case for the observer.
