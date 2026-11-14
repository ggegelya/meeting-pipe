---
id: PERF14
title: The daemon declares no ProcessType and holds no activity assertion, so launchd's light resource limits and App Nap may be throttling detection between meetings; measure first
category: Performance
status: new
priority: P2
comment: Filed 2026-10-24 (audit band, architecture review M13): launchd.plist.template has no ProcessType (unspecified means light CPU and I/O limits per man launchd.plist; the live job shows spawn type = daemon) and nothing calls beginActivity, so idle detection may be throttled. Unmeasured. Owner reads the App Nap column and a backgrounded detection gap first; only then an activity token and ProcessType Interactive. [Spec](./PERF14.md) Amended 2026-11-13 by the audit band: main thread at priority 20 against 46 to 47 for apps, and the cold prompt bracket (345 ms against 49 ms warm) is the instrument.
---

# PERF14: the daemon declares no `ProcessType` and holds no activity assertion, so launchd's light resource limits and App Nap may be throttling detection between meetings; measure first

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) M13, marked "unverified" there). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

MeetingPipe runs as an `LSUIElement` app started by a per-user LaunchAgent, and between meetings its only work is timer-driven detection (the discovery watcher's mic sample, the lifecycle signals' polls, the calendar and window watchers). Two OS mechanisms can stretch those timers, and the repo opts out of neither. Verified on 2026-10-24:

- `scripts/launchd.plist.template` sets `Label`, `ProgramArguments`, `RunAtLoad`, `KeepAlive` (`SuccessfulExit` false), `ThrottleInterval`, the two log paths and `PATH`. It has no `ProcessType` key. `man launchd.plist` says of that key: "If left unspecified, the system will apply light resource limits to the job, throttling its CPU usage and I/O bandwidth." On the owner's Mac, `launchctl print gui/$(id -u)/com.meetingpipe.daemon` reports `spawn type = daemon (3)` for the live job.
- `grep -rn "beginActivity\|NSAppSleepDisabled\|ProcessType\|disableAutomaticTermination"` over `daemon/Sources` and `scripts/` returns nothing, and the app `Info.plist` that `scripts/install.sh` writes carries no `NSAppSleepDisabled`.
- While a recording is live, the running `AVAudioEngine` and the ScreenCaptureKit stream already exempt the process from App Nap, so the exposure is the idle stretch between meetings, which is exactly when detection has to notice a call starting.

Nobody has measured whether either mechanism fires. No incident has been tied to it: the detection misses in the backlog have causes of their own (DET, END bands). This task exists so that measurement happens once and the answer is written down, not so the opt-outs are added on taste.

## Scope

1. **Measure (owner-run, read-only, about 15 minutes).** With the daemon idle and no meeting app in a call: Activity Monitor's CPU tab, "App Nap" column, for MeetingPipe (add the column via View ▸ Columns); and `log show --last 15m --predicate 'process == "MeetingPipe"' | grep -i -E "app ?nap|throttl"`. Then start a Teams test call with the daemon backgrounded for 10 minutes and read `events.jsonl` for the gap between the call's first `process_audio_is_running_input` transition and the discovery prompt, against the same gap with Library open in front. Record the numbers in this file.
2. **If the App Nap column says Yes, or the backgrounded gap is materially longer than the foregrounded one:** hold one `ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "meeting detection")` token for the daemon's lifetime, owned by `AppDelegate` and released in `applicationWillTerminate`, so idle system sleep still works; and add `<key>ProcessType</key><string>Interactive</string>` to `scripts/launchd.plist.template`. Both are a few lines; the measurement is the work.
3. **If both say No:** add one sentence to `ARCHITECTURE.md` beside the LaunchAgent description stating that App Nap and launchd's default limits were checked on 2026-10-24 (or the pickup date) with the numbers, and close the task with no code change.

## Explicitly not

- `NSAppSleepDisabled` in the `Info.plist`. It is a blunt per-app switch the owner cannot see; an activity token scoped to the daemon's purpose is the documented path.
- Holding the token only during meetings. The exposure is between meetings; a meeting already keeps the process awake through its audio work.
- Energy work on the polls themselves (the per-call AX and CoreAudio polls are [PERF10](./PERF10.md); the discovery watcher's main-thread mic sample is item 6 of [PERF13](./PERF13.md)).
- UX82's quit and relaunch semantics, which touch the same LaunchAgent plist (`KeepAlive`); coordinate the edit if both land close together.

## Acceptance

- This file gains a dated "Measured" section with the App Nap column reading, the log grep result, and the two detection gaps in seconds.
- If the opt-out ships: a test (MeetingPipeTests) that `AppDelegate` holds a non-nil activity token after `applicationDidFinishLaunching` and releases it on terminate, through an injected `ProcessInfo`-shaped seam; `scripts/launchd.plist.template` carries `ProcessType` `Interactive`, and after `scripts/install.sh` `launchctl print` shows `spawn type = interactive`. The owner re-reads Activity Monitor and the column says No.
- `cd daemon && swift build` and `swift test` green; `bash scripts/ci-local.sh` green. `scripts/install.sh` and `docs/SETUP.md` need no change unless the install steps do.

## Amendment 2026-11-13 (audit band)

Source: [responsiveness audit](../../audits/2026-11-13-responsiveness-audit.md) P053 (medium) and P048 (low, folded in), its ranked fix 4. Re-verified at HEAD (`3a2da4fc`) on 2026-11-14: `scripts/launchd.plist.template` still has no `ProcessType` key, and a grep of `daemon/Sources` and `scripts/` for `beginActivity` or `ProcessType` still returns nothing.

**The standing, now measured (P053).** On the audit's Mac (macOS 27.2, an install from about 2026-08-18, process idle) `launchctl print` reports `spawn type = daemon (3)` for `com.meetingpipe.daemon`, the same reading as this spec's 2026-10-24 Context, and `ps -M` showed the daemon's main thread at priority 20 against 46 to 47 for ordinary apps. The audit read interactive launchd jobs at 31, so `ProcessType Interactive` alone is a partial lift and not app parity; the activity token in item 2 is the other half. What the standing costs is still unmeasured: the audit measured the standing, not its cost.

**The prompt bracket is the measure-first instrument (P048).** `DetectionStateMachine.current`'s `didSet` logs `state_change` synchronously from `setPrompting(source:)`, and `MeetingSessionController.handleMeetingStarted(source:)` logs `prompt_shown` at the end of the same synchronous main-queue call, after `coordinator.statusUI.setPrompting(source)`, `workflowForPrompt` and `routingHint` (both in-memory filters) and `coordinator.prompt.present(...)`. So the gap between the two rows is one main-thread span: either work on main or main waiting to be scheduled. From the field pack, that span is a median 49 ms when another state change happened in the previous 30 s (n=313, era A) but a median 345 ms after more than 5 minutes of quiet in era A (n=35), 426 ms in era B (n=47, max 8.1 s at 2026-10-21T11:16:47.708Z) and 288, 317 and 357 ms in era C. The warm and cold split is the same in every era, so it is not a regression of the 2026-10-12 build. The candidates on the installed builds are the status menu rebuild with a cold recordings-folder listing inside the state setter (removed by [PERF24](./PERF24.md), done, not in any build the pack covers), the logger's per-row cost before [PERF13](./PERF13.md)'s single writer, the panel build, and scheduling or App Nap. Installing HEAD removes the first two, so a split that survives on HEAD is the panel build or scheduling.

**The panel is rebuilt on every prompt.** `MeetingPromptWindow.present(source:workflow:availableWorkflows:suggestion:autoDismissAfter:)` calls `dismiss(animated: false)`, which drops `self.panel`, then `makePanel(source:timeoutSec:)`, which constructs a fresh `NSPanel(contentRect:styleMask:backing:defer: false)` and its whole content view. Nothing reuses it. `MicLevelMonitor.start` already runs its engine work on a private queue, so the waveform is not a candidate.

Correction at filing: P048 says showing the prompt "holds the main thread for about 0.3 seconds". The bracket cannot tell main-thread work from the main thread being descheduled, which is the question this task asks, so 0.3 s is the span of the synchronous call, not proven blocking work.

**Surfaced, not adopted.** The audit's fix holds the activity assertion only while a prompt, the HUD or a window is up. This spec's Explicitly not keeps the lifetime token, because the exposure is the idle stretch in which detection has to notice a call, and a prompt-scoped assertion starts after the cold span it is meant to shorten. The owner may choose otherwise at item 2.

**Added to scope** (the measure-first order is unchanged; nothing below skips item 1):

- 1a. `prompt_shown` gains `elapsed_ms` (from the `setPrompting` call to the log line) and `present_ms` (time inside `prompt.present`), both from `ProcessInfo.processInfo.systemUptime`, not wall timestamps. The `coordinator` category already has its CONVENTIONS row, so no new category is added.
- 1b. After HEAD is installed on the work laptop, read a week of `prompt_shown` rows and record warm (previous `state_change` within 30 s) and cold (more than 5 minutes of quiet) medians of `elapsed_ms` and `present_ms` in the Measured section, beside the App Nap reading.
- 2a. If `present_ms` carries the cold cost, build the prompt panel once and reuse it: keep the `NSPanel` across `dismiss`, order it out, and rebind its content per prompt, instead of `makePanel` per `present`. If cold `elapsed_ms` stays high while `present_ms` is small, that points to scheduling, which is item 2's opt-outs.
- The plist change reaches the live job only through an agent reinstall: `scripts/install.sh` regenerates the LaunchAgent plist from `scripts/launchd.plist.template` on every run, and `LaunchAtLoginService` only reads the plist and its override. Say so in the ship note and run `scripts/install.sh` before the post-change `launchctl print`.

**Added to acceptance.**

- A controller test (the existing `FakeSessionHost` seam) that `prompt_shown` carries non-negative integer `elapsed_ms` and `present_ms`, read back from `events.jsonl` in a redirected logs directory, the DET11 shape `MeetingSourceScannerTests` already uses.
- The Measured section records the warm and cold medians with n, on HEAD, for both fields.
- If the panel is reused: a test that two consecutive `present` calls show one panel instance with the second source's content, and `ModalSafeTimerTests`' panel-flag pins still pass.
- `cd daemon && swift build` and `swift test` green, with the number of tests added in the ship note.

Related: [OBS7](./OBS7.md) (click and first-paint rows), [OBS10](./OBS10.md) (post-stop slowness rows, the per-job half of the same question), [PERF11](./PERF11.md) (main-thread stall probe), [CONC10](./CONC10.md).
