# DET2 spike: CoreAudio process-tap attribution (reviving ProcessAudioSignal)

Spike, 2026-07-12. Probe: [`daemon/scripts/det2-process-tap-probe.swift`](../../daemon/scripts/det2-process-tap-probe.swift) (owner-run on a real Mac during a live call, read-only). This spike ships the mechanism analysis + a measuring instrument; the empirical verdict (which mechanism, if any, revives the read) is owner-owed because it can only be answered on real hardware with a live meeting client holding the mic, not in this harness.

## Measured verdict (2026-07-20): none of A / B / C. Close the leg.

The owner ran the probe on a real Mac against a live Teams call (PID 667), with the probe's own grant line reading `screen-recording grant: granted`. All three mechanisms returned the identical failure:

```
A. Baseline (grant only, no tap):     translate -> FAILED (OSStatus 0, object 0)
B. Bare process tap held live:        translate -> FAILED (OSStatus 0, object 0)
C. Private aggregate around the tap:  translate -> FAILED (OSStatus 0, object 0)
```

B and C were genuinely exercised, not skipped: the probe prints a distinct `AudioHardwareCreateProcessTap FAILED` / `CreateAggregateDevice FAILED` line when construction fails, and neither appeared, so the tap and the private aggregate were both created successfully and the translate still returned `kAudioObjectUnknown`. `OSStatus 0` is `noErr`: the HAL answers the query and reports no process object, rather than refusing it.

**Independent corroboration at production scale.** Mechanism A did not need the probe at all: `ProcessAudioSignal` ran live in the daemon before TECH-END1 disabled it, and `~/Library/Logs/MeetingPipe/events.1.jsonl` (2026-05-18 to 2026-07-13) holds the record.

| Measurement | Value |
|---|---|
| `process_audio_unresolved` | 13,419 (all `com.microsoft.teams2`) |
| `process_audio_object_unresolved` | 64, every one `osstatus: 0` |
| `process_audio_is_running_input` (any resolved read) | 0, across both log generations |
| `permission_granted kind=screenRecording` | 71, first at `2026-05-18T13:23:54Z` |

The Screen Recording grant was held from the first minute of that window, so mechanism A was measured from inside a genuinely authorized app, at production scale, for eight weeks, with the same `osstatus 0` / object 0 signature the probe reproduced. (13,419 supersedes the 13,407 mid-flight count quoted elsewhere; the log kept accruing until the signal was disabled.)

**Gotcha worth keeping: the first probe run was void.** It reported `screen-recording grant: NOT granted` because it was launched as `swift daemon/scripts/det2-process-tap-probe.swift` from a TCC-*disclaimed* parent process (an agent harness spawns its shell through a `disclaimer` helper, which deliberately severs responsible-process inheritance). The executing process is `swift-frontend`, so it holds no grant of its own and inherits none. Re-running from an ordinary granted terminal produced `granted` and the numbers above. Any future re-run must confirm the probe's own grant line before its verdict is worth reading, which is exactly why the probe prints it.

**Disposition: close the process-audio leg.** `ProcessAudioSignal` stays dead by design and `usesProcessAudio` stays `false` on all four native adapters. DET1's frontmost attribution remains the catch-all, the AX re-walk plus the idle-stop backstop remain the end-detection ceiling, and MIC8 (UI-independent native signals) remains the stronger futureproofing bet. The `requiresCorroboration` rail below was never needed, since nothing was flipped. Doc and probe are kept, per the CAL1 precedent, so the decision is revisitable if a future macOS changes process-object authorization; the sections below are the original pre-measurement analysis, retained as the trail.

## Question

`ProcessAudioSignal` is fully built and unit-tested but dead in production: the PID-to-HAL translation (`kAudioHardwarePropertyTranslatePIDToProcessObject`) returns object 0, so `kAudioProcessPropertyIsRunningInput` never reads (0 successful reads in 19.8 days, 13,407 `process_audio_unresolved`; `usesProcessAudio` is hard-`false` on all four native adapters). DET2 asks: **what makes the read resolve?** The revival hinges on one empirical question, unanswerable from documentation (the tap API is, per ADR 0001, "a private-looking API surface that is officially documented but sparsely" whose macOS-15 behaviour "had to be discovered by testing"):

- Does the read resolve with **(A)** the Screen Recording grant the daemon already holds, no tap at all?
- Or only while a **(B)** bare CoreAudio process tap is held live?
- Or only with **(C)** a full private aggregate device built around that tap?
- Or **none** of the above on this macOS?

The answer decides whether DET2 is a trivial zero-setup flip, a small held-tap wrapper, a heavy aggregate subsystem, or a close. It is measured, not guessed, because the wrong guess is either dead code or a large blind build.

## Why measure before building (the SDK reality)

The installed SDK (MacOSX 26.5) confirms the shape. `AudioHardwareCreateProcessTap(CATapDescription*, AudioObjectID*)` / `AudioHardwareDestroyProcessTap` are macOS 14.2+ (the repo floor). The tap it returns is an `AudioObjectID` you read `kAudioTapProperty*` on, but to actually **capture audio** you attach it to an aggregate device (`AudioHardwareCreateAggregateDevice` + `kAudioAggregateDeviceTapListKey` + a sub-tap keyed by `kAudioSubTapUIDKey`). So the documented "full build" is not a thin call: it is a tap + aggregate-device subsystem.

But DET2 does not need to capture audio: `SystemAudioCapture` (SCStream) already captures the other side. DET2 needs a single **boolean** per process ("is this app on the mic right now?"). Building a whole capture aggregate to read that boolean is a heavy hammer for a small nail, and it may be unnecessary: creating a tap object, or merely holding the Screen Recording grant, may already populate the HAL process-object list enough for the translate + `isRunningInput` read. That is exactly the A/B/C the probe measures.

## The private-vs-shared aggregate clarification (write it down)

A common and correct worry: an aggregate device is the BlackHole/Loopback pattern where the user must *select* the aggregate as input/output inside Teams/Zoom, and it breaks when they switch between the laptop mic and AirPods. That pattern is real, and **ADR 0001 already rejected it** for exactly that reason ("the user has to route the meeting app's output to the driver; the routing breaks when the user changes output devices. Not viable for a daily-use app"). No DET2 build would ship that.

The modern (macOS 14.2+) tap + **private** aggregate is a different animal: marked private, it never appears in any app's device picker, requires no user selection, and leaves every app's mic/speaker choice untouched. The tap passively mirrors the target process's audio for the daemon to read. So whichever mechanism the probe blesses, no correctly-built DET2 asks the owner to select a device. The distinction matters because it changes "aggregate device" from a dealbreaker into merely "heavier to build" (mechanism C).

## What is already in place (so a GO is small)

The signal and the fusion vocabulary already exist and are unit-tested; only the read is dead:

- **End detection.** `PromotionEngine` already classes `processAudioIsRunningInput` as its own `EndEvidenceClass.processAudio`, distinct from the ax-leave/window-gone class, so a working signal is an independent end corroborator with no fusion change. Flipping `usesProcessAudio` on the four `NativeLifecycleConfig`s is the only wiring.
- **Start detection.** `MeetingSourceScanner.collectSignals` already calls `ProcessAudioSignal.defaultProbe` every scan and feeds `MeetingSourceScorer` (weight 3, a `shouldWalkControlAX` gate precondition, and a required corroborator for a bare-brand-token browser title). It is live but starved; a working read fixes it for free.
- **The prompt.** `MicInUseTier` / `MeetingPromptWindow` already name the app (the eyebrow is `AppSource.displayName`). So DET2's two non-runtime acceptance clauses ("the scorer treats it as an independent signal", "prompts name the attributed app") are already satisfied the moment the read is real; a GO's build surface is just "make it emit real events."

The "high-confidence" phrasing in the task is about the attribution *method* (a tap-verified per-process read vs today's frontmost-app guess), not a UI badge; there is no `confidence` field anywhere and none is needed.

## Safety rail for the end leg (when built)

The signal has been dead 19.8 days, so its live semantics are unvalidated, most importantly: does a client-side mute drop `isRunningInput`? If it does, a mute would look like an end. Because `processAudioIsRunningInput.requiresCorroboration` is `false` today, a lone process-audio `.ended` would promote after the debounce. So a GO that flips `usesProcessAudio` must **also set `requiresCorroboration = true` for `processAudioIsRunningInput`**: the signal then corroborates an end (and feeds the scorer) but cannot solo-confirm one, so a mute-induced input drop can never chop a recording. This keeps "an independent leg" while removing the blind false-end risk. Revisit lowering the bar only after live data shows the signal is quiet on mute.

## Verdict: measure first; the GO shape is whatever the probe blesses

Matching the CAL1 / MIC7 pattern (the headline question needs live hardware, so ship the instrument + the decision tree, not a blind build):

- **A resolves (grant only):** GO, the cleanest possible. `ProcessAudioSignal` works with no tap; flip `usesProcessAudio` (with the corroboration rail) and the scanner resolves for free. Zero setup, zero new TCC, no new capture code. This is the outcome the owner's "clean simple sidecar" goal wants.
- **B resolves (bare tap):** GO with a small `ProcessAudioTap` wrapper that holds a private muted tap during a native recording (affordable: one tap per recording, invisible to the user). Still no device selection.
- **C only (full aggregate):** likely DEFER. Building a capture aggregate to read a boolean is a large, blind, real-time-adjacent subsystem for a non-load-bearing corroborator (the AX re-walk already backstops native end detection; the scorer benefit is start-side). Reconsider only if start-side coverage proves worth the weight.
- **None resolves:** close the process-audio leg. `ProcessAudioSignal` stays dead by design (DET1's frontmost attribution stands); revisit only if a future macOS changes process-object authorization.

Net: **do not write production detection code yet.** The probe is typecheck-clean here (it resolves the `NS_REFINED_FOR_SWIFT` initializer spelling against the SDK), so the mechanism code is known to compile; only the runtime answer is pending.

## Follow-on (resolved 2026-07-20)

The decision tree above ran to its "none" branch, so the close is taken:

- DET2 moved to [`q6-final.md`](../backlog/q6-final.md) as done, closed NO-GO by measurement. No production detection code was written, so there was nothing to revert.
- `usesProcessAudio` stays `false` on all four native adapters, and `LifecycleAdapterTests.test_process_audio_signal_is_disabled_for_every_provider` stays as-is; it now pins a measured permanent state rather than a provisional one, and carries the DET2 measurement in its comment so a future reader does not re-open it.
- The stale "revive it if we adopt a process tap" note is corrected in place at both sites that carried it (`ProcessAudioSignal`, `NativeLifecycleConfig.usesProcessAudio`), because adopting a tap is precisely what was measured and it did not revive the read.
- A revisit needs a macOS release that changes process-object authorization. Re-run the probe from a granted terminal, confirm its grant line says `granted` first, and read `SUMMARY`.
