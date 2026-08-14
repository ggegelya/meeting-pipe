# REC13: an AVAudioEngine config-change notification deadlocks the engine queue, so a recording never stops and system capture runs unbounded

Band origin: filed 2026-08-14 from a live incident the owner reported the same day ("my last meeting got hang, can you check why it is still in stopping?"), diagnosed against the running process before it was killed. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## What happened

`20260814-163455`, a manual recording started 16:34:55 local. The owner stopped it at **17:31:43**; the state machine logged `state_change recording -> stopping` and then emitted **nothing for 52 minutes**. No `recording_stopped`. The daemon sat in `.stopping` while the recording kept going.

At 18:24 the process was still alive (pid 57648, `STAT S`, 1.8% CPU) and the intermediates on disk told the story:

| File | Size at 18:27 | Last written |
|---|---|---|
| `20260814-163455.system.wav` | **1.28 GB, growing ~394 KB/s** | 18:27, still live |
| `20260814-163455.mic.wav` | 537 MB, frozen | **17:21** |

So 56 minutes after the user pressed stop, system audio was still being captured and written, at roughly 1.4 GB/hour, on a path to the 4 GiB RIFF ceiling in about two more hours. The mic leg had died separately at 17:21 on a device change and never came back.

## The deadlock, from a live sample

`sample 57648` taken at 18:24 (191 KB, 17 threads). **The main thread is not blocked**: it is idle in `__CFRunLoopRun` / `mach_msg` and still servicing `MeetingDiscoveryWatcher.armPollTimer`. That refutes the obvious diagnosis and is why this is not the [[audio-hal-main-thread-freezes]] class.

The wedged thread is AVAudioEngine's own serial queue, blocked in **2516 of 2516 samples**:

```
Thread_2440307   DispatchQueue_290: engine  (serial)
  _dispatch_block_async_invoke2
    invocation function for block in AVAudioEngineImpl::IOUnitConfigurationChanged()   (AVFAudio)
      -[NSNotificationCenter postNotificationName:object:userInfo:]
        _CFXNotificationPost
          -[NSOperation waitUntilFinished]        <- blocked here
            _pthread_cond_wait
              __psynch_cvwait
```

The mechanism is the observer registration at [MeetingRecorder.swift:899-908](../../../daemon/Sources/MeetingPipe/MeetingRecorder.swift#L899):

```swift
configChangeObserver = NotificationCenter.default.addObserver(
    forName: .AVAudioEngineConfigurationChange,
    object: engine,
    queue: .main
) { [weak self] _ in self?.handleConfigurationChange() }
```

`addObserver(forName:object:queue:using:)` with a **non-nil queue** makes `NotificationCenter` wrap the handler in an `NSOperation`, enqueue it, and have the *poster* wait on it. The poster here is AVFAudio's internal engine queue. No thread anywhere in the sample is executing `handleConfigurationChange`, so that operation was enqueued and never ran.

Every AVAudioEngine call serializes on that queue, so once it is blocked, anything the stop path needs from the engine is queued behind a wait that never ends. That is why `.stopping` never completes.

**What the sample does not establish, and must not be asserted:** why `OperationQueue.main` never drained the operation, given the main thread was idle and pumping timers. The tidy explanation (main blocked in `removeObserver` holding the notification-center lock) is contradicted by the evidence above. A pickup should capture a second sample plus `OperationQueue.main.operationCount` before theorising.

## The trigger

`recorder.log`, the two minutes before the stop (timestamps UTC, owner is UTC+3):

```
14:21:34Z  SCStream error: Failed to find any displays or windows to capture
14:21:37Z  mic tap re-arm (engine_running=true stalled=true)
14:21:37Z  input device changed mid-recording - capture re-armed (7604 silent frames padded the gap)
14:21:39Z  mic tap re-arm (engine_running=false stalled=false)
14:21:41Z  input device changed mid-recording - capture re-armed (603 silent frames padded the gap)
14:21:57Z  WARN: SCStream start failed: Stream failed to start audio, recording mic-only
14:31:21Z  woke while recording - re-checking capture liveness
14:31:22Z  WARN: SCStream start failed: No display available for system-audio capture
14:31:33Z  woke while recording - re-checking capture liveness
14:31:34Z  display topology changed; cleared SCShareableContent cache (REC5)
14:31:35Z  SCStream system-audio capture started
14:31:43Z  <user stops>   state_change recording -> stopping
```

Two `did_wake_while_recording` events with `engine_running: false`, a display topology change, repeated device changes, and an SCStream restart 8 seconds before the stop. This is a sleep/wake plus display-change storm, which is precisely the situation that produces repeated `AVAudioEngineConfigurationChange` posts.

## Graceful termination does not work either, which is the second defect

Recovering the machine was attempted in the documented order and the graceful path failed:

- `kill -TERM 57648` **stopped the capture** (the file stopped growing at 1,314,082,816 bytes, CPU fell to 0.0%) but the process **did not exit after 10 seconds**.
- `flushIntermediatesForTermination` **never ran**: its log line ("flushing intermediates for termination") does not appear for 2026-08-14 at all; the most recent one in `recorder.log` is 2026-07-27. So `applicationWillTerminate` either never fired or blocked before its first log statement.
- `kill -9` was required.

That matters because the doc comment on `flushIntermediatesForTermination` ([MeetingRecorder.swift:1487](../../../daemon/Sources/MeetingPipe/MeetingRecorder.swift#L1487)) promises exactly the property that would have saved this recording: it "drains the serial writers ... and drops the file handles so their WAV headers flush", and claims to be "Deadlock-free: the only blocking calls are the writers' own serial queues, never the main queue." The writer queues were healthy in the sample (`com.meetingpipe.sysaudio` and `com.meetingpipe.recorder.system-writer` were both running), so the flush should have succeeded and did not.

This is adjacent to REC11 item (a), which already records that the termination drain is unbounded where `stop()`'s is bounded. REC11 predicted a hang on that path; this is one, with a different proximate cause.

## The measured cost, and why it is larger than it looks

After `kill -9`, launchd relaunched and orphan recovery worked as designed: `recovered orphaned recording -> 20260814-163455.wav mode=auto`, pipeline queued, summarized and published. Nothing was lost to the recovery machinery itself.

But the final is **2798.5 s (46.6 min) against 113 minutes of wall clock**, and the transcript stops at 2695.7 s. The `.mic.wav` was 537,310,524 bytes, which at 48 kHz mono float32 is 2798.5 s exactly. **The merge ended with the mic and discarded roughly 67 minutes of system audio**, i.e. the other side of the call.

The reason is a documented REC9 fallback firing in the one situation it is most likely to fire. `mergeLengths` ([RecordingPostProcessor.swift:89-101](../../../daemon/Sources/MeetingPipe/RecordingPostProcessor.swift#L89)):

```swift
guard let mic = micDurationSec, let system = systemDurationSec else {
    return MergeLengths(systemDelayMs: delayMs, padMic: false,
                        targetDurationSec: nil, expectedDurationSec: micDurationSec)
}
```

With no readable duration it pads only the system leg and sets no `-t`, so the merge "ends with the **mic**: a deliberate bias, since the mic is the channel the owner cannot re-obtain." The durations come from the RIFF header, and the headers were never finalized because the flush never ran. ffmpeg said so in its own output: `Estimating duration from bitrate, this may be inaccurate`, `Packet corrupt (stream = 0, dts = NOPTS)`, `corrupt input packet in stream 0`.

So the chain is: deadlock -> stop never completes -> graceful termination fails -> `kill -9` -> unfinalized headers -> unreadable durations -> mic-biased fallback -> the longer channel is dropped. **Fixing the deadlock removes the whole chain**, which is why this is one task rather than four.

## Scope

**1. Do not let a notification post block the engine queue.** Register the config-change observer without an `OperationQueue`, i.e. `addObserver(forName:object:queue:nil)` plus an explicit `DispatchQueue.main.async` inside the handler, so `_CFXNotificationPost` returns immediately and never waits on an `NSOperation`. This is the direct fix and it is small. The comment at `:895-898` explains the `queue: .main` choice as being about where the handler runs and about a `@Sendable` capture warning; both survive an explicit hop.

**2. Make stop independent of the engine queue.** A stop the user asked for must complete even when AVAudioEngine is unresponsive. Bound every engine call on the stop path (the repo already has `runWithTimeout` and `boundedEngineStart`, used at `MeetingRecorder.swift:470` and `:1042`), and on timeout proceed to finalize the intermediates anyway rather than staying in `.stopping`. **`MicLevelMonitor.swift:39` is the last unbounded `engine.start()` in the tree** and should be bounded in the same pass.

**3. Make the termination flush actually run.** Establish why `flushIntermediatesForTermination` did not execute under SIGTERM, then fix it, and give it a hard ceiling so a wedged subsystem cannot hold the process open. Its "Deadlock-free" comment is currently a claim the incident contradicts; correct it to say what is true.

**4. A stuck `.stopping` must be visible and escapable.** 52 minutes in `.stopping` with a growing file produced no event, no notification and no UI affordance. At minimum emit an event when a stop exceeds a ceiling, and surface it where the owner can act on it.

## Explicitly not / out of scope

**Not the orphan recovery path.** It did its job: recovered, merged, transcribed, summarized and published without intervention.

**Not reopening REC9.** Its fallback behaved as specified and its bias is defensible in the case it was written for. But the incident shows the fallback is most likely to fire exactly when the process was killed, and in that case the system leg is no more re-obtainable than the mic. **Named here, not fixed here**: whether the no-readable-duration fallback should prefer the longer leg (or estimate duration from file size and format, which is exact for uncompressed PCM) deserves its own row if the owner wants it. Do not fold it in.

**Not REC11.** Its two findings stand as filed; item (a) is adjacent and this incident is evidence for it, but REC11's scope (bounding the drain, `stop()`'s actor isolation) is separable.

**Not the mic-tap death at 17:21.** A device change killed the mic leg an hour before the stop and it never recovered. That is REC8/REC10 territory and is a distinct failure; it is recorded here because it is what made the truncation cost 67 minutes instead of nothing.

**Not REC12.** Different crash, different queue, different lifecycle stage. But REC12's scope item 4 says "Nothing observes that notification today", which is **false and must be corrected**: `MeetingRecorder.swift:902` observes it, and that observer is the one that deadlocked here.

## Acceptance

- A test drives the config-change observer registration and asserts the notification post does not block the poster: post `.AVAudioEngineConfigurationChange` from a background queue and assert the post returns before the handler completes. It must fail against `main`.
- A test asserts `stop()` completes and reaches `.idle` when every AVAudioEngine call it makes times out, so a wedged engine cannot strand the state machine.
- A test asserts the stop path emits an auditable event when it exceeds its ceiling, carrying the elapsed time, so the next occurrence is readable from `events.jsonl` rather than needing a live `sample`.
- A test asserts the termination flush runs to completion under a simulated wedged engine, and that it is bounded.
- `MicLevelMonitor`'s `engine.start()` is bounded, pinned by a test.
- `cd daemon && swift build` clean, `swift test` green, with the number of tests this task adds recorded in the ship note. Do not pin an absolute suite total.
- `python3 scripts/truth_fences.py both` green, with any new event action documented in the `CONVENTIONS.md` event table in the same commit.
- No em-dashes in changed lines; repo dash guard green.

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule. Steps are tagged [owner] / [session] by who acts.

1. [session] `./scripts/rebuild.sh` after landing, then tell the owner it is ready.
2. [owner] Reproduce the trigger, which is the cheap part: start a recording, then change the audio route and the display topology while it runs (plug and unplug headphones, connect and disconnect an external display, close and open the lid). Pass: no wedge, and `recorder.log` shows the re-arms completing.
3. [owner] The load-bearing step: **press stop during that churn** and confirm the recording reaches a finished state. Before this change it sat in `stopping` for 52 minutes with the file still growing.
4. [owner] Then the escape hatch: if it ever does stick again, confirm a notification or visible state tells you, rather than the only symptom being a Library row that never settles.
5. [owner] Quit the app from the menu bar while a recording is live and confirm it exits within a few seconds and the recording is recovered on the next launch. That is the path that failed on 2026-08-14 and required `kill -9`.
6. [owner] Say "REC13 good to close" (or what is wrong); [session] moves the row and this spec into `q6-final.md` and deletes this file.
