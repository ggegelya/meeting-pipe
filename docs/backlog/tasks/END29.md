---
id: END29
title: A headphone switch whose microphone return the app misses ends a live Teams recording 12 minutes later, cut back to the switch
category: Detection
status: new
priority: P2
comment: Filed 2026-11-16 at the owner's request while settling END21's Stop rule. Code-derived, not seen in the field: if Teams' mic comes back under a process object the resolver does not follow (DET8's re-registration shape), the engine keeps reading the mic as released, the mic-led hold never reverts, and the lone dwell ends the recording about 12 min after the switch, trimmed back to the switch by END21. Scope: a mic-led hold does not lone-confirm while the Leave button and the call window still read live, plus a signal-level pin that a re-registered object's return is emitted. P2 because unobserved; the owner may promote it if it shows up in the field.
---

# END29: A headphone switch whose microphone return the app misses ends a live Teams recording 12 minutes later, cut back to the switch

Band origin: filed 2026-11-16 (group A's end-engine batch, at the owner's request after [END21](./END21.md)'s Stop rule was settled). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

The owner asked on 2026-11-16 how END21's trim rules handle switching headphones mid-call. The answer, from the code as it stands after [END18](./END18.md) and END21, has one unprotected case, which this task files.

**The normal switch is safe.** Teams releases its input for a few seconds while the device changes ([END15](./END15.md) measured a re-acquire inside 22 s on 2026-10-22). `ProcessAudioSignal` reports the release, `PromotionEngine.handleInMeeting` opens a hold led by `process_audio_is_running_input_false` (a weak end, `isDefinitive` false), and when the mic comes back the signal emits live and `handleEndingProvisional` reverts the hold unconditionally (`event.kind.vetoesLoneEnd`, kept by END18). Nothing is stopped or trimmed.

**The missed return.** If the engine never receives that live reading, its `states` keep process audio at `.ended`. Then:

1. `tick(at:)` sees no live vetoer, so neither dwell is blocked.
2. The pair cannot form if nothing else ended (the Leave button and the window stay live through a switch), so the lone dwell decides: `now.timeIntervalSince(loneSince) >= loneDwell` with `loneSince` the release (END18 item 4), 720 s.
3. END18's lone-dwell refusal does not apply: it fires only for a window-gone lead with the Leave button live (`leadClassContradicted` requires `leading.evidenceClass == .callWindowOrControl`), and this hold is led by process audio.
4. The recording ends about 12 minutes after the switch with `confirmed_by: [lone_dwell]`, and END21's `TeardownHoldPolicy.trimPoint` cuts at process audio's release (`evidence.processAudio == .ended`), so the transcript leaves out everything from the switch on. Under a lossless capture that is restorable; under NDA or regulated mode it is deleted at stop.

**How the return could be missed.** DET8 (2026-08-05) caught a Teams audio client tearing down and re-registering under a new process-object ID, which is why `processAudioIsRunningInput` carries `requiresCorroboration`. `ProcessAudioSignal` follows such changes through a list-change listener and a poll: since [DET21](./DET21.md) a list change triggers one coalesced re-resolve (`process_audio_reresolved`) and an unresolved resolve backs off 2 s doubling to 60 s. The return is missed only if the resolver keeps a stale object that reads false and no list change or poll moves it to the new one, or if the new object does not match the bundle the resolver enumerates for. Neither has been observed; this is the shape the code allows, not a measured rate.

## Scope

Two changes, smallest first.

1. **Engine: a mic-led hold does not lone-confirm against a live call UI.** In `PromotionEngine.tick(at:)`, extend END18's `leadClassContradicted` idea to a process-audio lead: refuse the lone dwell while the Leave button reads `.live` in `states` and nothing of another class ended inside the hold (`otherClassesEndedInside`). A real leave always takes the Leave control away (it reads invalid, or the window goes), which ends the refusal and lets the pair or the lone dwell decide as today. The idle backstop stays the ceiling, since `.endingProvisional` is not `isLive` (`SilenceAutoStopPolicy` does not stand down).
2. **Signal: pin that a re-registered object's return is emitted.** A `ProcessAudioSignalTests` case where the matched process object disappears and a new one for the same bundle appears reading running: the next re-resolve or poll emits `onChange(true)`. If it does not, that is the defect to fix in `ProcessAudioSignal`; if it does, the engine change above is the backstop for the cases the test cannot reach.

The pickup decides whether item 1 also covers an app without a Leave reading (an unarmed Leave button): recommended no, since there is then nothing to contradict the release.

## Explicitly not

- Changing END21's trim rules: they are the owner's decisions of 2026-11-16, and the trim is the second-order harm here; the end is the first.
- [DET23](./DET23.md)'s MicHolderMonitor as the fix: it is log-only by design. It may later give the engine a second process-audio opinion, which is its own decision.
- The device-switch gap measurement: END15's owner remainder.

## Acceptance

- `PromotionEngineTests`: a Teams hold led by process audio at T with the Leave button and the window live and nothing else ending does not confirm at T + `loneDwell` (no end at any tick through T + 2 × `loneDwell`); the same hold with the Leave button going invalid later confirms on the pair or the lone dwell as today; END15's switch with the return observed still reverts.
- `ProcessAudioSignalTests`: the re-registration case in Scope item 2 emits the return.
- A lifecycle trace in the detection corpus (`origin: synthetic`): a switch at T whose return never arrives, the call running on with the Leave button and window live, `expected_outcome: no_end`.
- Every existing END14, END15, END17, END18 and END21 test and corpus trace stays green; `cd daemon && swift test` green with the new tests named in the commit body; `bash scripts/ci-local.sh` green.
