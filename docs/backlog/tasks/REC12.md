# REC12: the prompt's live-waveform tap raises an uncatchable ObjC exception, aborting the daemon within 100 ms of every prompt it hits

Band origin: filed 2026-08-14 from the owner's crash report the same day, sent with "worth filling I guess, happens several times already". It happens more than several: **all four MeetingPipe crash reports on this machine are this one bug**, and every one lands inside 100 ms of a meeting prompt appearing. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

> **Shipped 2026-08-17: every scope item plus the sibling.** Items 1, 3 and 4 landed first; item 2, the Objective-C `@try` barrier, went back to the owner because the spec priced it as "one file" when it is a new SwiftPM target, and landed once the owner approved that. Each item below carries what landed. **The row stays open on the owner walkthrough at the bottom and nothing else.** The engineering evidence, including which raise conditions were ruled out by the check and which needed the barrier, is in `daemon/docs/gotchas.md` under "installTap raises where start() throws".

## The crash

```
Exception Type:  EXC_CRASH (SIGABRT)      Termination: Abort trap: 6
Application Specific Information: abort() called
Triggered by Thread: 9, Dispatch Queue: MeetingPipe.MicLevelMonitor

9   objc_exception_throw
10  +[NSException raise:format:]
11  AVAudioEngineImpl::InstallTapOnNode(...)
12  -[AVAudioNode installTapOnBus:bufferSize:format:block:]
13  MeetingPipe  closure #1 in MicLevelMonitor.start(onLevel:)  (MicLevelMonitor.swift:23)
```

`installTapOnBus` raised an Objective-C `NSException`. Nothing caught it, so `objc_terminate` called `abort()`. `MicLevelMonitor.swift:23` is the `installTap` call itself.

## All four reports are identical, and they chain

`~/Library/Logs/DiagnosticReports/MeetingPipe*.ips`, read 2026-08-14. Same `EXC_CRASH`/`SIGABRT`, same `MeetingPipe.MicLevelMonitor` queue, same `MicLevelMonitor.swift:23`, in every one:

| Launched | Crashed | Ran for |
|---|---|---|
| 2026-08-13 00:36:39 | 2026-08-13 15:00:25 | 14 h 24 m |
| 2026-08-13 15:00:25 | 2026-08-13 16:24:43 | 1 h 24 m |
| 2026-08-13 18:06:32 | 2026-08-14 10:30:38 | 16 h 24 m |
| 2026-08-14 10:30:38 | 2026-08-14 12:15:38 | 1 h 45 m |

Note rows 2 and 4 launch in the same second the previous row crashed: launchd relaunches, and the replacement dies the same way at the next prompt it loses the race on.

## Every crash is a prompt, within 100 ms

Correlated against `events.jsonl`. Offsets are from the crash instant:

| Crash | `prompt_shown` at | Relaunch (`engine_resolved` + 4x `permission_granted`) | Re-prompt |
|---|---|---|---|
| 08-13 15:00:25 | **-0.059 s** | +1.32 s | +2.63 s |
| 08-13 16:24:43 | **-0.097 s** | +1.38 s | +2.57 s |
| 08-14 10:30:38 | **-0.057 s** | +1.38 s | +3.06 s |
| 08-14 12:15:38 | **-0.049 s** | +1.16 s | +4.94 s |

The shape is identical every time: `discovery_shadow_pick` for `com.microsoft.teams2`, `ax_handles_built`, `lifecycle starting`, `state_change idle -> prompting`, `prompt_shown`, then **abort roughly 50 to 100 ms later**. `MicLevelMonitor.start` is called when the prompt is presented (its own doc comment says so: "`start`/`stop` are called from the main thread (prompt present/dismiss)"), for `LiveWaveformView`.

So the sequence the owner sees is: a meeting starts, the Record prompt appears, the app disappears, the app comes back, and a second prompt appears two to five seconds later.

**What it has cost so far.** On 2026-08-13 15:00 the owner accepted the *second* prompt at 15:00:29, so `20260813-150029` starts about 4 seconds into the call. On 2026-08-13 16:24 the re-prompt at 16:24:46 produced no recording at all. A prompt that vanishes and returns is a prompt that can be missed, and a 30 s prompt timeout defaults to skip.

**The blast radius is bounded, and that is worth stating.** `handleDiscovery` guards on `isAcceptingPrompts`, so no prompt is raised while a recording is running, which is why no crash has yet killed a live recording. This is a property of the state machine, not of this code, so it should not be relied on when fixing it.

## Why it raises, and the one thing not proven

`installTap` is passed `input.outputFormat(forBus: 0)` read one statement earlier ([MicLevelMonitor.swift:19](../../../daemon/Sources/MeetingPipe/Design/MicLevelMonitor.swift#L19)) with **no validation in between**. `AVAudioEngineImpl::InstallTapOnNode` raises on an invalid format (a zero sample rate or zero channel count), on a format that disagrees with the node's hardware format, and on a bus that already has a tap.

The prompt fires at the exact moment the meeting client is acquiring the input device, which is when a transitional format is most likely. One data point makes that concrete: after the 2026-08-13 15:00:25 relaunch, `input_device_resolved` reports the device as **AirPods Pro at a 24000 Hz sample rate**, while the 2026-08-14 crashes resolve to **MacBook Pro Microphone at 48000**. A Bluetooth input renegotiating its rate as a call starts is the textbook version of this window, and the crash reproduces on the built-in mic too.

**Not proven, and say so rather than asserting it:** the crash report does not carry the `NSException` reason string (`asi` holds only "abort() called"), so which of the raise conditions fired is inferred from the call site and the timing, not read. The fix below does not depend on the answer, and scope item 3 makes the next occurrence self-diagnosing.

## Why the existing error handling does not help

```swift
input.installTap(onBus: 0, bufferSize: 1024, format: format) { ... }   // :23  raises

do {
    try self.engine.start()                                            // :39  throws
    self.isRunning = true
} catch { ... }
```

The `do/catch` guards `engine.start()`, which signals failure by **throwing a Swift error**. `installTap` signals failure by **raising an Objective-C exception**, which Swift cannot catch at all: there is no `try` that helps and no `catch` that runs. The author guarded the recoverable call and left the fatal one bare, one statement above it.

The file's own contract already says what the degraded behaviour should be: "If it fails (e.g. no mic permission, wedged device), the callback never fires and the waveform stays flat." That is the correct outcome here too. A flat waveform on a decorative prompt animation is not worth a process abort.

## Scope

**1. Validate the format before installing.** Skip the tap when `format.sampleRate` or `format.channelCount` is zero, log it, and leave the waveform flat per the contract above. This removes the most likely raise condition without any new machinery.

> **Shipped.** `GuardedTapInstall` (`daemon/Sources/MeetingPipe/GuardedTapInstall.swift`) is the one seam, taking the format, a `site` string and the install closure, and returning whether the tap went on. A refusal writes a `recorder` / `mic_tap_install_skipped` row carrying the site, the sample rate and the channel count, so the next occurrence is readable rather than reconstructed. Worth recording because it is what made the acceptance testable at all: `AVAudioFormat(standardFormatWithSampleRate: 0, channels: 1)` returns a **live object** reporting 0 Hz rather than nil, so a test can build exactly what the input node hands over when the HAL has no usable input, and a non-nil format was never evidence of a usable one.

**2. Put a real barrier around the call.** A guard cannot cover every raise reason, and Swift structurally cannot catch what is left. The remedy is a small Objective-C (or C) shim with `@try`/`@catch` that wraps the `installTap` invocation and reports failure as a Swift-visible value. There is no such shim in the tree today (searched 2026-08-14: no `@try`, no `NSException` handling anywhere in `daemon/Sources`), so this adds one file and is the piece that makes the guarantee total rather than probabilistic. Decide explicitly whether the shim is worth it or whether item 1 plus item 4 is enough, and record the reasoning.

> **Shipped 2026-08-17, on the owner's approval of the target.** `MPRunCatchingObjCException` is the whole of `MeetingPipeObjC` (`daemon/Sources/MeetingPipeObjC/`, one `.m` plus its public header, a target entry and a dependency line in `Package.swift`): it runs a closure inside `@try` / `@catch` and returns the exception's name and `reason`, or nil. No third-party dependency, and it is deliberately not a dependency of `MeetingPipeCore`, whose island rules keep its floor at Foundation plus TOMLKit. `GuardedTapInstall` is still the only path from a format to `installTap`, and now the only caller of the barrier, both pinned by source fences.
>
> **Why item 1 plus item 4 was not enough.** Item 1 answers the conditions readable from the format. Item 4, plus the unconditional `stop()`, closes the double-tap route deterministically, since a bus that already has a tap is one of the raise conditions and the desync was what could produce a second install. What was left is the format disagreeing with the node's hardware format at the instant `installTap` re-reads it, and no check made beforehand can close that: it is a race, not a state. It is also the live hypothesis for the observed crashes, given the 08-13 relaunch resolved AirPods Pro at 24000 Hz while the 08-14 crashes resolved the built-in mic at 48000.
>
> **The caught-raise contract, which is the load-bearing part.** Catching an `NSException` raised from inside AVFAudio's C++ frames leaves the engine in an unspecified state: the unwind passes through Swift frames the compiler emitted as non-unwinding, so their cleanups do not run, and `InstallTapOnNode` is abandoned part-way through. So a caught raise is **terminal for that engine**, and that is built into the API rather than asked of callers, because both callers have a live retry path into the seam (`MicLevelMonitor.start` on every prompt, `MeetingRecorder.recoverCapture` on every device change) and a rule left in a comment would have been retried within a day. Mechanically: a raise condemns the engine, held weakly by identity so the record dies with the engine, and `GuardedTapInstall` refuses a condemned engine every later tap. `Outcome` (`installed` / `refusedFormat` / `refusedCondemnedEngine` / `raised`) keeps the two failures apart on the type, since a refused **format** is transitional and must stay retryable on the same engine.
>
> **The way back is a replacement, never a retry.** `MeetingRecorder.start` swaps its own engine when it finds it condemned, which is what stops one raise during a device-change recovery from costing every later recording rather than just that one, and its unwind takes the fresh-engine path after a raise rather than reusing a half-configured node. `MicLevelMonitor` cannot replace anything (its engine is a `let` for the monitor's lifetime) and does not try: metering stops and the waveform stays flat, which is this file's documented degradation.
>
> **What it looks like in the log if it ever fires:** a `recorder` / `mic_tap_install_raised` row carrying the site, the format, and the exception `reason`, and **no crash report**. That row is the thing to grep for after the walkthrough day; item 3's `UncaughtExceptionLogger` line means the same string is now readable on both the caught and the uncaught path.
>
> **Not proposed:** removing the live waveform. This spec names it as the fallback if the barrier turned out to be disproportionate, and it did not.

**3. Make the next occurrence self-diagnosing.** Install an uncaught-exception handler that logs the exception's name and `reason` before the process dies. This costs almost nothing and is the difference between this reconstruction and reading one line. It is also what would settle the "not proven" paragraph above.

> **Shipped.** `UncaughtExceptionLogger.install()` is the first statement of `applicationDidFinishLaunching`, and writes name, `reason` and a 12-frame backtrace to `daemon.log` plus a `daemon` / `uncaught_exception` event. `Log.writeLine` first and deliberately: it is unbuffered, and a process one instruction from `abort()` gets one chance at each. It does not prevent the abort and cannot, since it runs while the exception is already unwinding; preventing it is items 1 and 2.

**4. Observe `AVAudioEngineConfigurationChangeNotification`.** When the input device changes, `AVAudioEngine` stops itself and uninstalls taps, but `MicLevelMonitor.isRunning` is never updated, so the monitor's idea of its own state silently diverges from the engine's. This is the state-desync half and is worth fixing whether or not it is the trigger.

> **Corrected 2026-08-17 by REC13.** This item used to end "Nothing observes that notification today", which was false when it was filed: `MeetingRecorder.armConfigurationChangeObserver` has always observed it, scoped to the recorder's own engine, and **that observer is the one that deadlocked** in the REC13 incident. What is true is narrower: *`MicLevelMonitor`* does not observe it, which is the desync this item is actually about, and which stands.
>
> Read the pattern REC13 established before adding an observer here, because the obvious spelling is the bug: registering with a non-nil `queue:` makes NotificationCenter wrap the handler in an `NSOperation` and have the **poster** wait on it, and the poster is AVFAudio's own engine queue. Use `addMainQueueObserver` (nil queue plus an explicit main hop). Note also that `MicLevelMonitor`'s engine work runs on its own private serial queue, not main, so an observer here has to get back to that queue rather than assuming main. REC13 also bounded this file's `engine.start()` / `stop()` behind `MicLevelMonitor.startBounded` and `runBoundedSync`, so build on those rather than reintroducing a bare call.

> **Shipped, as two changes that compose.** The observer registers in `init` through `addMainQueueObserver`, scoped to this monitor's own engine, and hops main -> `audioQueue` before touching the flag; `deinit` unregisters. The waveform is **not** re-armed on a change, because `onLevel` is deliberately never stored (the tap block captures it directly so the render thread cannot race `audioQueue`), and a flat waveform is this file's documented degradation. Second, `stop()` no longer reads `isRunning` before tearing down, which is what closes the residual REC13 recorded on `startBounded`: an abandoned start that later succeeds leaves a running engine the monitor believes is stopped, and the old guard skipped the teardown for the process lifetime. `removeTap` on an untapped bus is a no-op and the stop is behind `engine.isRunning`, so asking anyway costs a bounded call on a private queue.
>
> `engine` and the `NotificationCenter` are now injectable, defaulted, and the app takes the defaults. That is only so the test can post a real configuration change scoped to the same object the observer registers for; an observer registered with a non-nil object does not receive a post made with `object: nil`, so there was no other way in. `isMeteringLive` and `markMeteringLiveForTest` are the read/write pair the same test uses, documented as test-only in the source: the state is reachable only through a live `AVAudioEngine`, and neither CI nor this machine's test runner has an input device with a Microphone grant, so a test routed through `start()` would have asserted nothing.

**Sibling to fix or fence in the same pass:** `MeetingRecorder.installMicTap` ([MeetingRecorder.swift:786-790](../../../daemon/Sources/MeetingPipe/MeetingRecorder.swift#L786)) is the same unguarded `installTap` call, reached from `start()` **and from device-change recovery**, which is precisely the transitional window this crash lives in. It has not been observed crashing, but it is on the recording path, where an abort costs a meeting rather than a prompt. At minimum it routes through the same guarded helper this task builds.

> **Shipped.** It returns `Bool` now and both call sites act on it: `start()` unwinds the partial mic setup and throws `engineStartFailed`, and the device-change recovery emits `configuration_change_unrecoverable` with `reason: tap_format_unusable` and reports the recovery failure, which is the same shape the failed-converter branch above it already had. The `sampleRate > 0` check `start()` already carried stays as a pre-flight, since it names the likely Microphone-permission cause; it is a check on a format read about fifty lines earlier, and the guard is the check at the instant of use. Pinned by a source fence over every `.installTap(onBus:` in `daemon/Sources`, which is red against `main` by arithmetic (one bare call, zero guarded) and goes red again on a third bare call; a behavioural test would need a live engine bound to a real input device.

## Explicitly not / out of scope

**Not the off-main threading.** The private `audioQueue` is correct and was added deliberately after the 2026-06-24 stuck-prompt, where an on-main `engine.start()` stalled prompt presentation. It is also why this aborts on thread 9 rather than the main thread. Do not undo it.

**Not `boundedEngineStart` / `runWithTimeout`.** Those bound a *hang*, which is the audio-HAL freeze class `MeetingRecorder` uses them for. This is a raise, not a hang, and a timeout does not catch an exception. Reaching for them here would be treating the wrong failure mode.

**Not the detection or prompt logic.** `discovery_shadow_pick` through `prompt_shown` behaved correctly in all four traces. The prompt is the trigger only because it is what starts the monitor.

**Not removing the live waveform** as the first move. It would fix the crash by deleting the feature, and the feature is cheap once the call is safe. Worth naming as the fallback if the barrier turns out to be disproportionate; the owner decides that, not the pickup.

**Not the `.ips` triage note in project memory.** It records that MeetingPipe `bug_type: 309` reports are launch-time code-signing SIGKILLs with empty backtraces. These four are also `bug_type: 309` and are **not** that: they are `SIGABRT` with full backtraces, 1 to 16 hours into a run. `bug_type` is not the discriminator; the exception type and whether the backtrace is empty are. That memory was corrected on 2026-08-14 so this class is not dismissed on sight.

## Acceptance

- A test drives the tap-installation seam with a zero-sample-rate format and a zero-channel format and asserts no tap is installed, no crash, and a logged skip. It must fail against `main`, which passes the format straight through.
- A test asserts a valid format still installs the tap and the level callback fires, so the guard is not a blanket disable.
- A test asserts `start()` after a skipped install leaves `isRunning` false, so a later `start()` can retry rather than being latched out by a failure.
- If the ObjC barrier ships, a test drives it with a call that raises and asserts the failure surfaces as a value rather than terminating the test process.
- A test asserts the configuration-change observer resets `isRunning`, so the monitor and the engine cannot disagree about whether a tap exists.
- `MeetingRecorder.installMicTap` goes through the same guarded helper, pinned by a test, or the task records why it deliberately does not.
- `cd daemon && swift build` clean, `swift test` green, with the number of tests this task adds recorded in the ship note. Do not pin an absolute suite total.
- `python3 scripts/truth_fences.py both` green, with any new event action documented in the `CONVENTIONS.md` event table in the same commit.
- No em-dashes in changed lines; repo dash guard green.

> **Verified 2026-08-17.** Every line above is met, the barrier one included as of the item-2 ship. **+18 tests** in the first pass: 7 in `GuardedTapInstallTests` (the predicate, the two refusals with their logged rows, the healthy pass-through, the source fence), 7 added to `MicLevelMonitorTests` (`arm` refusing before touching the engine, the retry-after-refusal property, `arm` on a healthy format, the level shaping, the configuration-change reset, its object scoping, the `stop()` fence), 4 in `UncaughtExceptionLoggerTests`.
>
> **+12 more with the barrier (2585 total, 0 failures):** 6 in `ObjCExceptionBarrierTests` (nil on a normal body, name plus `reason` on a raise, a raise with no reason, a Swift error left alone, a raise from a nested call, no state held between calls), 5 added to `GuardedTapInstallTests` (the raise surfacing as `.raised` with its `reason` in the event row, the condemnation blocking the next install, condemnation scoped to one engine, the `Outcome` shape, a fence that the barrier has exactly one caller), 1 added to `MicLevelMonitorTests` (`arm` survives a raise and never re-arms that engine).
>
> **Both barrier claims were measured red, not asserted.** Neutering `MPRunCatchingObjCException` to a bare `body()` turned 8 tests red across the three files. Neutering `isCondemned` to `false` while leaving the barrier in place turned 6 red on their own assertions, including "the next prompt re-armed an engine a raise had already condemned". Both were restored and the suite re-run. **One claim was refuted in the process and the comments corrected:** these tests do **not** demonstrate the process abort, because XCTest installs its own ObjC exception handler per test case, so a neutered barrier produces an ordinary red test ("required condition is false: format.sampleRate == hwFormat.sampleRate (NSInvalidArgumentException)") rather than a dead binary. The daemon has no such handler, which is the whole bug; the abort stays evidenced by the four crash reports.
>
> **The build-system questions were checked rather than assumed.** `swift build`, `swift build -c release` and `swift test` all clean with no new warnings; `truth_fences.py both` green (no new event **category**, and actions are ungoverned by design). The new target adds no `.bundle` and links statically (`_MPRunCatchingObjCException` is a defined symbol in the release executable, `otool -L` shows no new dylib), so `rebuild.sh`'s staging set is unchanged, verified by rehearsing its copy-plus-sign on a scratch copy of the installed app: `codesign --verify --deep --strict` reports valid and satisfying its designated requirement. `install.sh`'s standalone `swift-frontend` pass over `MeetingPipeAppIntents.swift` is untouched (it never reads `Package.swift`) and still gathers 8 const values, checked by re-running that exact invocation.
>
> **The red-against-`main` claim was measured, not asserted**, the way REC13 did it. Neutering the guard to a pass-through turned the zero-sample-rate and zero-channel tests red on the exact assertions ("installTap was reached; on a real node this aborts the process", and the missing skip row), along with four `arm` assertions. Commenting out the observer registration turned the configuration-change test red on "the monitor still believes it is metering an engine that stopped itself". Both were then restored and the suite re-run. The source fence is red against `main` by arithmetic: `git show main:...MeetingRecorder.swift` has one `.installTap(onBus:` and zero `GuardedTapInstall.install(`.
>
> `swift build` clean with no new warnings, `swift test` green at 2573 tests, `python3 scripts/truth_fences.py both` green. No new event **category** (`recorder` and `daemon` both already exist), so nothing was owed to the CONVENTIONS.md table, which fences categories rather than actions.
>
> One correction made in passing, worth naming because it is a behaviour claim rather than a typo: the level-shaping comment said "quiet-room (~0.001) -> ~0.04, speaking voice (~0.1) -> ~0.7", and the curve gives 0.004 and 0.28. The shaping is untouched; the comment now names measured values and a test holds them.

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule. Steps are tagged [owner] / [session] by who acts.

1. [session] `./scripts/rebuild.sh` after landing, then tell the owner it is ready. Still owed as of the item-2 ship: that session ran in a worktree and did not land, so nothing has been staged into the installed app yet.
2. [owner] Use the app normally for a working day with several Teams meetings. Pass: `ls ~/Library/Logs/DiagnosticReports/MeetingPipe*` gains no new entry. The base rate was four crashes in 36 hours, so a clean day is meaningful evidence. Worth grepping the same day: `mic_tap_install_skipped` means the format check refused one, and `mic_tap_install_raised` means the barrier caught a raise that would previously have been an abort. Either row is the fix working; **neither is expected**, and one would carry the `reason` string all four crash reports lacked.
3. [owner] The targeted repro, worth trying because it is the fastest way to exercise the transitional window: put on the AirPods, and while Teams is connecting the call audio, watch for the prompt. Pass: the prompt appears and stays. The waveform being flat or briefly absent is an acceptable outcome and is the documented degradation.
4. [owner] Confirm the waveform still animates on an ordinary prompt with the built-in mic, so the guard did not disable the feature everywhere.
5. [owner] Say "REC12 good to close" (or what is wrong); [session] moves the row and this spec into `q6-final.md` and deletes this file.
