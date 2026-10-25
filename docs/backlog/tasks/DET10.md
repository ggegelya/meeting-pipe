# DET10: DET1's mic-busy input has never produced a span, so the catch-all tier is inert and DET3's miss auditor reports a structural zero

Filed 2026-08-03 by the audit band. Proposed high, downgraded to medium by an independent skeptic because the root cause is unestablished and the affected path is one the owner has not needed. Filed with that framing intact.

## What is wrong

`AVCaptureDevice.isInUseByAnotherApplication` has never read true on this Mac, so `MicBusySpanTracker` has never opened a span. Verified 2026-08-03 across the full event-log history (2026-05-18T13:23Z to 2026-08-03T08:09Z):

- `mic_busy_started`: **0**
- `mic_busy_ended`: **0**
- `candidate_dropped`: **257**, emitted from the same file on the same 2026-07-12 commit day, which proves the `detector` category is live and the zero is not a routing artifact
- `recording_started`: 175

Code path:

(Line numbers as of the 2026-08-15 pickup, which moved the last of them by emitting the event.)

- `daemon/Sources/MeetingPipe/MeetingDiscoveryWatcher.swift:170` is `busy: mic.isInUseByAnotherApplication,`, the only producer of a mic-busy sample. Everything in DET1 and DET3 hangs off this one boolean.
- `daemon/Sources/MeetingPipe/MicBusySpanTracker.swift:56-59` opens a span only on `busy == true`, so a permanently-false input means `open` is permanently nil.
- `daemon/Sources/MeetingPipe/MeetingDiscoveryWatcher.swift:254-257` guards on `micBusyTracker.open`, so `MicInUseTier.decide` is never even called.
- `daemon/Sources/MeetingPipe/MeetingDiscoveryWatcher.swift:137` was `guard let mic = AVCaptureDevice.default(for: .audio) else { return }`, a second silent failure mode for the same signal: it logged nothing, emitted no event, and is never retried, so a nil at daemon launch disables DET1 and DET3 for the whole process lifetime. It now emits `detector.mic_device_unavailable` (see Shipped below); it is still never retried, because the retry is the GO branch and the verdict is not in.

## The part that makes this worth filing

The second-order effect is worse than the first. DET3 built `mp analyze-detection`'s mic-busy dimension precisely to make silent detection false-negatives visible. It pairs `mic_busy_started` / `mic_busy_ended`, finds none, and reports zero mic-busy misses.

**The instrument built to detect silent failures reports "clean" because its own input is dead.** That is the exact false-zero shape this repo already knows from CAL1's EventKit reads, and DET3's own owner-owed leg ("eyeball a real week's report once mic-busy spans have accrued") will confirm a clean week that means nothing.

**Half-addressed 2026-08-15** (see Shipped below): the auditor no longer reports "clean", it reports "not audited". The underlying zero is unchanged, so DET3's owner-owed eyeball is still owed and would still see nothing.

`README.md:602` (cited as `:575` at filing; the line had already moved) also promises the catch-all to the user: "A catch-all backstop also raises a quiet generic 'Record?' prompt when the mic stays held by a plausible meeting app ... so a call on a domain the whitelist never listed still gets caught". That code path has never been reached.

## Root cause is unestablished, deliberately

Two causes fit the evidence equally and the pickup must distinguish them rather than guess:

- `AVCaptureDevice.default(for: .audio)` returns nil at daemon launch, so the observer is never wired.
- `isInUseByAnotherApplication` is structurally false for shared macOS audio inputs, in which case the whole signal choice is wrong and needs replacing rather than fixing.

Do not write a fix against the second without measuring, since that is how DET2 reached a NO-GO that DET8 later refuted by asking a different question.

## Scope

Probe first. A short owner-run probe that reports whether `AVCaptureDevice.default(for: .audio)` resolves and whether `isInUseByAnotherApplication` ever flips while a known mic holder is live. Note the harness caveat: TCC-gated probes report NOT GRANTED under an agent harness regardless of the real grant, so the probe must state its precondition and refuse to emit a verdict without a grant, the way `cal3-teams-title-probe.swift` already does.

Then, whatever the verdict:

- Emit an event when `wireMicObserver` cannot resolve a device, so a permanently-dead detection input is itself observable rather than silent.
- Make `mp analyze-detection` distinguish "zero misses" from "zero spans observed", so a dead input can never render as a clean week.

On a GO, fix the wiring. On a NO-GO, replace or supplement the signal with a source that actually observes mic contention, and note that DET8's enumeration of `kAudioHardwarePropertyProcessObjectList` is the nearest candidate already under investigation.

## One thing downstream of this verdict, added 2026-08-15

**On a GO, reopen DET11's `MicInUseTier` question.** DET11 shipped the same day and its acceptance required answering, explicitly and in writing, whether `MicInUseTier`'s native exclusion should become conditional so that an Accessibility-denied user gets a working catch-all tier. It answered **no**, and one of its three reasons was this task: conditioning a tier whose input has never once read true buys nothing while the verdict is out. That reason expires the moment the verdict is GO, and the other two do not, so this is a reopen rather than a reversal.

The reasoning lives in DET11's archived spec in [q6-final.md](../q6-final.md), with a pointer beside the exclusion in `daemon/Sources/MeetingPipe/MicInUseTier.swift`. Read it before changing anything: it records that the obvious condition is the wrong one. The condition has to be AX trust, not "the scan found no winner", because a live call goes tens of seconds with no winner (DET9). `detector.candidate_unreadable`, which DET11 shipped, is the signal to reuse.

Nothing is owed here on a NO-GO or a NO VERDICT.

## Shipped 2026-08-15 (the two legs that land whatever the verdict)

Both are observability, not a fix. Neither branch of the fork is written, deliberately.

- **The dead input says so.** `MeetingDiscoveryWatcher.wireMicObserver`'s nil-device branch emits `detector.mic_device_unavailable` instead of returning silently, carrying the microphone TCC status it saw (`authorization`), since "this Mac exposes no audio input" and "the mic grant is denied" surface as the same nil and take different fixes. The vocabulary is `MicInputAvailability.swift`, pure and unit-tested; the watcher itself needs AVFoundation and NSWorkspace and has no harness. The resolve is still not retried: that is the GO branch.
- **`mp analyze-detection` cannot render a dead input as a clean week.** The mic-busy section used to be gated on `if spans:`, so a window with a dead input produced no section at all, next to an end-detection report that read fine. It now always renders, and a window with zero spans is headed **"Mic-busy misses (not audited)"** rather than "(0)": 0 of 0 is not the claim 0 of N is. When a `mic_device_unavailable` event is in the window it names that as the cause; when there is none it says plainly that "nothing held the mic" and "the signal does not observe mic contention on this Mac" are different findings it cannot separate, and points at the probe. `--json` carries the same distinction as `mic_busy.input_status` (`observed` / `device_unavailable` / `no_spans`) plus `device_unavailable_events`, because `spans_observed: 0, misses: []` is the same false-clean one level down.

## Pre-registered verdict

Written before the probe ran, and not to be refitted afterwards. The probe prints this table before it measures anything.

| Outcome | Reading | Verdict |
|---|---|---|
| A | `AVCaptureDevice.default(for: .audio)` is nil in a process that HAS the mic grant | **GO (wiring).** Cause 1 confirmed. Fix the resolve (re-resolve rather than resolve-once), keep the event. Says nothing about the property. |
| B | The flag reads true at any point during the watch | **GO (wiring).** The signal works in a plain process, so the daemon's own wiring is what is broken. Do not replace the signal. |
| C | Flag never true, and the default input was never running anywhere | **NO VERDICT.** Nothing held the mic during the watch; that measures the watch, not macOS. Re-run during a real call. |
| D | Flag never true, but the default input WAS running somewhere | **NO-GO.** The mic was demonstrably held and the property stayed false, so the signal choice is wrong. Replace or supplement it, starting with DET8's `kAudioHardwarePropertyProcessObjectList`. Not a failure to engineer around. |

Outcome D is what the CoreAudio corroborator (`kAudioDevicePropertyDeviceIsRunningSomewhere`, no TCC grant needed, a different mechanism from the property under test) exists to make reachable: without it, "the flag never flipped" cannot be told from "no call happened", and a NO-GO recorded off that ambiguity would be exactly the DET2 mistake DET8 later refuted.

## Measured

_(Owner-owed. Paste the probe's whole output here, with the date, then take the branch its verdict names.)_

## Owner walkthrough

Steps tagged [owner] / [session] by who acts.

1. [session] Build the probe and hand the owner one command to paste. **Done 2026-08-15:** `daemon/scripts/det10-mic-busy-probe.swift`.
2. [owner] Open Terminal **yourself** (not from the app, not from an editor or an agent) so it carries its own permissions, then from the repo root paste:

       swift daemon/scripts/det10-mic-busy-probe.swift --watch 240

   Pass: it prints `PRECONDITION  Microphone access for this process: GRANTED` and then a `LEG 1` line naming the audio device. If it says NOT GRANTED, stop and say so, because that is the harness caveat rather than a result; the probe refuses to emit a verdict there by design. If Terminal is not listed in System Settings ▸ Privacy & Security ▸ Microphone at all, it has never asked: run it once as `swift daemon/scripts/det10-mic-busy-probe.swift --request-access`, approve the prompt, then re-run the command above.
3. [owner] While it runs, join any call that holds the microphone, wait about a minute, then leave. Any call works, including FaceTime or a browser call. Make sure MeetingPipe is **not recording** during the watch: its own capture would flip the flag from a source that is not the call, and the probe warns if it sees the app running.
4. [owner] Paste the probe's final report back. It says whether the mic-busy flag ever flipped, whether the device was ever actually held, and which of A-D it read.
5. [session] Files the verdict into **Measured** above and takes the branch it names.

## Amended 2026-10-25 (observability audit band)

Added from the [2026-10-25 observability audit](../../audits/2026-10-25-observability-audit.md) (finder LG-13; an independent skeptic downgraded it to low and placed it here). Re-verified against `main` at `01e904a` and the unified log on 2026-10-25.

**What the log shows.** The installed daemon (pid 77137, running since 2026-10-18 14:59:56 local, a 2026-09-11 build) writes `(CoreAudio) AudioHardware-mac-imp.cpp:773 AudioObjectGetPropertyData: no object with given ID 0` at error level, always from the same thread, about every 12.1 s: 9,041 rows between 2026-10-24 and 2026-10-25 by the finder's count, starting 2026-10-24 01:33:54 local by the skeptic's, and still 266 in the hour to 2026-10-25 23:00 local in a session check. Nothing in the app's own logs mentions it: `events.jsonl` holds no rows at all for 2026-10-25 and, for 2026-10-24, only the 285 test doctor rows described in T9's amendment.

**Attribution, inferred rather than proven.** The cadence is `DiscoveryScanCadence.discoveryDefault`'s 12 s idle backstop poll, and the storm began six days into a process that had been quiet, which is the shape of a device that went away after launch rather than one missing at launch. The poll's only per-tick HAL read while idle is `MeetingDiscoveryWatcher.sampleMicBusy`'s `mic.isInUseByAnotherApplication` on `micDevice`, the `AVCaptureDevice` that `wireMicObserver` resolved once at daemon start and never re-resolves. Ruled out by reading the code: `InputDeviceIdentity` reads run at recording start (`MeetingRecorder`'s captured input device), not per poll; `ProcessAudioSignal` and the MicGate HAL probes run inside a lifecycle or a recording, and nothing was recording. If the default input that was resolved at launch (a headset, an external interface) disconnected at 01:33:54, the retained `AVCaptureDevice` is stale, its property read hits CoreAudio with a dead object id, and it returns false every time.

**Why it belongs here.** It is the stale-device symptom of the same resolve-once design this task fixes, and it is not covered by what shipped: the 2026-08-15 `detector.mic_device_unavailable` event fires only when `AVCaptureDevice.default(for: .audio)` is nil at launch, and the pre-registered outcome A ("re-resolve rather than resolve-once") was written for a nil at launch. A device that resolved and then went stale is a third way for the mic-busy input to read false forever, silently, and it matters to the probe too: `det10-mic-busy-probe.swift` runs in a fresh process, so it resolves the current device and cannot reproduce this. A probe GO (outcome B, "the daemon's own wiring is what is broken") now has a concrete candidate.

**Added scope, whatever the probe's verdict.** This is observability plus a resolve fix that holds under every branch, because a stale device is wrong whether or not the property can ever read true.

1. **Confirm the attribution first.** In a session, before writing the fix: reproduce by starting a debug daemon with an external input as default, disconnecting it, and counting the CoreAudio error lines at the poll cadence (`/usr/bin/log stream --predicate 'process == "MeetingPipe"'`); then confirm they stop when `sampleMicBusy` is short-circuited. If they do not stop, record what does and narrow this amendment before going further.
2. **Re-resolve on device change.** `MeetingDiscoveryWatcher` observes `AVCaptureDevice.wasDisconnectedNotification` and the system default-input change, and re-runs the resolve: replace `micDevice`, rebuild the `isInUseByAnotherApplication` KVO, and close any open `MicBusySpanTracker` span. A resolve that comes back nil emits the existing `mic_device_unavailable`.
3. **Say it.** Emit `detector.mic_device_changed` with the old and new device's name and transport, so `mp analyze-detection` can tell a window with a stale or swapped device from a clean one.

**Added acceptance.**

- The reproduction in item 1, with its line counts before and after, pasted into Measured with the date.
- A pure test of the re-resolve decision (old device id, notification, new default: rebuild or keep), in the style of `MicInputAvailability`; the watcher itself still has no harness.
- After the fix, on the owner's Mac: no `no object with given ID 0` rows at the poll cadence across a headset disconnect, and one `mic_device_changed` row for it.
