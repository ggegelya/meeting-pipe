---
id: END29
title: A headphone switch whose microphone return the app misses ends a live Teams recording 12 minutes later, cut back to the switch
category: Detection
status: partial
priority: P2
comment: Shipped 2026-11-16. `PromotionEngine.tick` refuses the lone dwell for a process-audio lead while the Leave button reads live and no other class has a fresh, uncontradicted edge (a Leave reading END18 declined inside the hold does not refuse); `ProcessAudioSignalTests` pin that a re-registered object's return is emitted by both the list-change re-resolve and the poll's streak re-resolve (green at HEAD, so no signal change); two synthetic `no_end` corpus traces; `bash scripts/ci-local.sh` green. Remainder: field confirmation only, since the shape is code-derived and unobserved; no owner walkthrough is proposed.
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

**Amended 2026-11-16 (owner): the minimised-window variant ends in about 60 s, not 12 minutes.** Minimising a native call window, or moving it to another Space, makes `ShareableContentSignal` (on-screen windows only, `onScreenWindowsOnly: true`) read the window as gone. Under a live mic that end is vetoed (`end_vetoed`) and opens no hold, but the engine keeps it in `states` as `.ended` with the minimise's stamp. If a headphone switch's mic return is then missed, the release pairs with that old window-gone: `tick`'s pair counts each evidence class from its earliest ended stamp (`endedSince[kind.evidenceClass] = min(...)`), so the call-window class has "dwelled" since the minimise and the pair confirms 60 s after the release, cut back to the switch. The seam is [END14](./END14.md)'s 2026-11-13 amendment (F031, G024: a class counted as ended while a sibling reads live, and stale stamps counting toward the pair); this task's fix should land with it or on it, and its acceptance gains the case below.

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
- The minimised variant, as an engine test and a trace: the window reads gone at T0 under a live mic (vetoed), a switch at T0 + 300 s whose return never arrives, the Leave button live throughout; no end at T0 + 360 s or later, while the Leave button reads live.
- Every existing END14, END15, END17, END18 and END21 test and corpus trace stays green; `cd daemon && swift test` green with the new tests named in the commit body; `bash scripts/ci-local.sh` green.

**Progress (2026-11-16): shipped.** Engine: `micLeadContradicted` in `PromotionEngine.tick` sits beside END18's `leadClassContradicted` and blocks only the lone dwell; the pair is unchanged. "No other class ended inside the hold" is read through END14's `pairEdges` (fresh and uncontradicted) rather than `otherClassesEndedInside`, so a window minimised inside the hold while the Leave button reads live does not lift the refusal. Signal: both re-registration paths (a list change re-resolving onto the new object, and the poll re-resolving once when the stale object reads nothing) emit the return at HEAD, so `ProcessAudioSignal` is unchanged and the engine refusal is the backstop for a stale object that keeps reading false. Tests: 5 new `PromotionEngineTests` (2 red against HEAD, 3 pinning that a Leave going invalid, a real leave, and an app with no Leave reading still end), 2 new `ProcessAudioSignalTests`, and the corpus traces `teams_native_end29_switch_return_missed` and `teams_native_end29_minimised_switch_return_missed` (both red against HEAD). Decision not in the spec: a Leave reading END18 declined inside this hold does not refuse, because the strict rule turned `test_a_declined_revert_restarts_the_lone_dwell_END18` red and END18 already runs the lone dwell from that reading. Residual: a Leave flicker inside a switch whose mic return is also missed ends 12 minutes after the flicker, as before. Docs: `daemon/docs/gotchas.md` (new section), ADR 0017's lone-dwell bullet, the ARCHITECTURE held-end glossary; README, `docs/GUIDE.md` (its "after 12 minutes" stays true for a real leave), CONVENTIONS and `daemon/CLAUDE.md` checked, no change needed.
