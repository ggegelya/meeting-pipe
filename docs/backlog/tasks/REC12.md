# REC12: the prompt's live-waveform tap raises an uncatchable ObjC exception, aborting the daemon within 100 ms of every prompt it hits

Band origin: filed 2026-08-14 from the owner's crash report the same day, sent with "worth filling I guess, happens several times already". It happens more than several: **all four MeetingPipe crash reports on this machine are this one bug**, and every one lands inside 100 ms of a meeting prompt appearing. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

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

**2. Put a real barrier around the call.** A guard cannot cover every raise reason, and Swift structurally cannot catch what is left. The remedy is a small Objective-C (or C) shim with `@try`/`@catch` that wraps the `installTap` invocation and reports failure as a Swift-visible value. There is no such shim in the tree today (searched 2026-08-14: no `@try`, no `NSException` handling anywhere in `daemon/Sources`), so this adds one file and is the piece that makes the guarantee total rather than probabilistic. Decide explicitly whether the shim is worth it or whether item 1 plus item 4 is enough, and record the reasoning.

**3. Make the next occurrence self-diagnosing.** Install an uncaught-exception handler that logs the exception's name and `reason` before the process dies. This costs almost nothing and is the difference between this reconstruction and reading one line. It is also what would settle the "not proven" paragraph above.

**4. Observe `AVAudioEngineConfigurationChangeNotification`.** When the input device changes, `AVAudioEngine` stops itself and uninstalls taps, but `MicLevelMonitor.isRunning` is never updated, so the monitor's idea of its own state silently diverges from the engine's. Nothing observes that notification today. This is the state-desync half and is worth fixing whether or not it is the trigger.

**Sibling to fix or fence in the same pass:** `MeetingRecorder.installMicTap` ([MeetingRecorder.swift:786-790](../../../daemon/Sources/MeetingPipe/MeetingRecorder.swift#L786)) is the same unguarded `installTap` call, reached from `start()` **and from device-change recovery**, which is precisely the transitional window this crash lives in. It has not been observed crashing, but it is on the recording path, where an abort costs a meeting rather than a prompt. At minimum it routes through the same guarded helper this task builds.

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

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule. Steps are tagged [owner] / [session] by who acts.

1. [session] `./scripts/rebuild.sh` after landing, then tell the owner it is ready.
2. [owner] Use the app normally for a working day with several Teams meetings. Pass: `ls ~/Library/Logs/DiagnosticReports/MeetingPipe*` gains no new entry. The base rate was four crashes in 36 hours, so a clean day is meaningful evidence.
3. [owner] The targeted repro, worth trying because it is the fastest way to exercise the transitional window: put on the AirPods, and while Teams is connecting the call audio, watch for the prompt. Pass: the prompt appears and stays. The waveform being flat or briefly absent is an acceptable outcome and is the documented degradation.
4. [owner] Confirm the waveform still animates on an ordinary prompt with the built-in mic, so the guard did not disable the feature everywhere.
5. [owner] Say "REC12 good to close" (or what is wrong); [session] moves the row and this spec into `q6-final.md` and deletes this file.
