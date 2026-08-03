# DET11: every surface says Accessibility only affects end-detection, but denying it kills start-detection too, silently

Filed 2026-08-03 by the audit band. The finder's original framing was refuted; this is the narrower claim the skeptic established in its place, and it is the more useful one.

## What is wrong

Four surfaces tell the user that Accessibility buys end-detection only:

- `docs/SETUP.md:94`'s permission table gives the cost of skipping it as "Recordings do not auto-stop, so you get up to 15 extra minutes of audio".
- `README.md:158`: "Without this, native apps will record fine but the call won't auto-stop".
- `daemon/Sources/MeetingPipe/StatusBarController.swift:475` renders "Accessibility off - meeting end-detection degraded".
- `daemon/Sources/MeetingPipe/Coordinator.swift:582` logs "Accessibility: NOT trusted - native meeting end-detection disabled".

The code disagrees. `daemon/Sources/MeetingPipe/MeetingSourceScanner.swift:253` is `if axTrusted {`, gating **every** native signal collection, so with Accessibility denied `titleMatch`, `callingControlsToolbar`, `leaveButton` and `muteButton` all stay false. `daemon/Sources/MeetingPipe/MeetingSourceScorer.swift:85` is `let contenders = candidates.filter { distinctSignalCount($0.signals) > 0 }`, which drops the zero-signal native entirely. So "records fine" is false: a native meeting is not detected at all, and the recording never starts to need stopping.

The drop is also invisible. `daemon/Sources/MeetingPipe/MeetingSourceScanner.swift:58-60` computes `droppedCandidates` from candidates that already have at least one signal, so a zero-signal native is filtered out **before** the dropped list is built and emits no `candidate_dropped` event. Nothing in `events.jsonl` records that a known meeting app was running and was discarded.

## What the skeptic refuted, recorded

The finder also claimed `MicInUseTier` should name a native holder and does not, citing `ARCHITECTURE.md:255` ("names the plausible holder (a browser / native meeting app / `mic_plausible` app)"). That half does not survive: the native exclusion is a deliberately shipped fix for a measured problem, documented 28 lines below the line the finder quoted. `MicInUseTier.swift:36-40` reads "plausibleBundles: browser + mic-plausible bundles (native whitelist apps are excluded - discovery owns them; see the watcher)", and `MeetingDiscoveryWatcher.swift:31-36` gives the causal story (a native pre-join holds the mic).

So `ARCHITECTURE.md:255` is wrong and should be corrected, but the exclusion itself is correct and must not be "fixed".

## Scope

Correct the four permission surfaces to say what Accessibility actually buys: with it denied, native meetings are not detected at all, not merely not auto-stopped. `docs/SETUP.md:94` matters most, since it is the clean-Mac walkthrough and a user who skips the grant on its stated cost gets a product that never notices a Teams call.

Correct `ARCHITECTURE.md:255` so it stops claiming the tier names a native.

Emit an observable event when a whitelisted native bundle is running but produced zero signals because Accessibility was untrusted, so the drop stops being silent and `mp analyze-detection` can see it.

Consider, and decide explicitly rather than by default, whether the native exclusion in `MicInUseTier` should become conditional on discovery actually being able to see natives, which would give the Accessibility-denied case a working catch-all tier. Note this is gated on DET10: the tier's input is dead today regardless, so this leg buys nothing until DET10 resolves.

## Acceptance

Suite green with new tests. A test drives the scanner with `axTrusted == false` over a running native candidate and asserts an observable event is emitted rather than silence. The four permission surfaces and `ARCHITECTURE.md:255` are corrected in the same commit. The `MicInUseTier` question is answered in writing in this spec, whichever way it goes.
