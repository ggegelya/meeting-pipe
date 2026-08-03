# DET10: DET1's mic-busy input has never produced a span, so the catch-all tier is inert and DET3's miss auditor reports a structural zero

Filed 2026-08-03 by the audit band. Proposed high, downgraded to medium by an independent skeptic because the root cause is unestablished and the affected path is one the owner has not needed. Filed with that framing intact.

## What is wrong

`AVCaptureDevice.isInUseByAnotherApplication` has never read true on this Mac, so `MicBusySpanTracker` has never opened a span. Verified 2026-08-03 across the full event-log history (2026-05-18T13:23Z to 2026-08-03T08:09Z):

- `mic_busy_started`: **0**
- `mic_busy_ended`: **0**
- `candidate_dropped`: **257**, emitted from the same file on the same 2026-07-12 commit day, which proves the `detector` category is live and the zero is not a routing artifact
- `recording_started`: 175

Code path:

- `daemon/Sources/MeetingPipe/MeetingDiscoveryWatcher.swift:155` is `busy: mic.isInUseByAnotherApplication,`, the only producer of a mic-busy sample. Everything in DET1 and DET3 hangs off this one boolean.
- `daemon/Sources/MeetingPipe/MicBusySpanTracker.swift:56-59` opens a span only on `busy == true`, so a permanently-false input means `open` is permanently nil.
- `daemon/Sources/MeetingPipe/MeetingDiscoveryWatcher.swift:239-242` guards on `micBusyTracker.open`, so `MicInUseTier.decide` is never even called.
- `daemon/Sources/MeetingPipe/MeetingDiscoveryWatcher.swift:135` is `guard let mic = AVCaptureDevice.default(for: .audio) else { return }`, a second silent failure mode for the same signal: it logs nothing, emits no event, and is never retried, so a nil at daemon launch disables DET1 and DET3 for the whole process lifetime.

## The part that makes this worth filing

The second-order effect is worse than the first. DET3 built `mp analyze-detection`'s mic-busy dimension precisely to make silent detection false-negatives visible. It pairs `mic_busy_started` / `mic_busy_ended`, finds none, and reports zero mic-busy misses.

**The instrument built to detect silent failures reports "clean" because its own input is dead.** That is the exact false-zero shape this repo already knows from CAL1's EventKit reads, and DET3's own owner-owed leg ("eyeball a real week's report once mic-busy spans have accrued") will confirm a clean week that means nothing.

`README.md:575` also promises the catch-all to the user: "A catch-all backstop also raises a quiet generic 'Record?' prompt when the mic stays held by a plausible meeting app ... so a call on a domain the whitelist never listed still gets caught". That code path has never been reached.

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

## Owner walkthrough

Steps tagged [owner] / [session] by who acts.

1. [session] Build the probe and hand the owner one command to paste.
2. [owner] Open Terminal **yourself** (not from the app) so it carries its own permissions, paste the command, and leave it running. Pass: it prints its precondition line and says the audio device resolved. If it says NOT GRANTED, stop and say so, because that is the harness caveat rather than a result.
3. [owner] While it runs, join any call that holds the microphone, wait about a minute, then leave. Any call works, including FaceTime or a browser call.
4. [owner] Paste the probe's final report back. It says whether the mic-busy flag ever flipped.
5. [session] Files the verdict into this spec and takes the branch it names.
