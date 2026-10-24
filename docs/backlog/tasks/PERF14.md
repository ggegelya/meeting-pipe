# PERF14: the daemon declares no `ProcessType` and holds no activity assertion, so launchd's light resource limits and App Nap may be throttling detection between meetings; measure first

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) M13, marked "unverified" there). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

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
