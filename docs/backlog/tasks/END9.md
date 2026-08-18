# END9: one empty AX walk 120 ms after another stops a live recording, and the new Teams calling UI made it frequent

Band origin: filed 2026-08-04 after three false meeting ends on 2026-08-03, investigated the same day. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## What is wrong

An `ax_leave_button_invalid` edge promotes to `.ended` on the strength of two AX walks taken 120 ms apart, both of which can land inside the same accessibility blackout.

The chain, all re-derived from source on 2026-08-04:

1. The 1 Hz health poll reads the cached Leave element as invalid. `AXLeaveButtonSignal.defaultProbe` maps only `kAXErrorInvalidUIElement` to `.invalid`, so this is Teams answering promptly that the element is gone, not a timeout and not a TCC hiccup.
2. `AXLeaveButtonSignal._evaluate(reason:)` re-walks for a live Leave button before believing it: `if state == .invalid, let fresh = throttledResolve(bypassThrottle: lastState == .healthy), probe(fresh) == .healthy` ([`AXLeaveButtonSignal.swift`](../../../daemon/Sources/MeetingPipeCore/Lifecycle/Signals/AXLeaveButtonSignal.swift)). The throttle is bypassed on a healthy-to-invalid edge, so the walk really runs. It finds nothing.
3. `MeetingSessionController.rescueProvisionalEnd(context:)` walks again ~120 ms later, through `MeetingAXHandleBuilder.findAllLeaveButtons(in: axApp, bundleID: context.bundleID)` on its own `axWalkQueue` ([`MeetingSessionController.swift`](../../../daemon/Sources/MeetingPipe/MeetingSessionController.swift)). Same function, same pid, same bundle. It also finds nothing, and calls `confirmProvisionalEnd()`.
4. `PromotionEngine.confirmProvisionalEnd(rewalkSignal:)` ([`PromotionEngine.swift`](../../../daemon/Sources/MeetingPipeCore/Lifecycle/PromotionEngine.swift)) checks only the phase (`guard case .endingProvisional(let context, let leading, _, let observed) = phase`). It skips the debounce, and it skips the `requiresCorroboration` guard that exists for exactly this signal, which lives in `PromotionEngine.tick(at:)` as `if leading.requiresCorroboration && !crossClassCorroborated { return nil }`. Then it appends its own re-walk signal to the end's provenance (`confirmedBy.append(rewalkSignal)`, defaulted to `"ax_leave_rewalk"`), so a confirmed end can never carry an empty `confirmedBy` and the `.ended` reads as corroborated by the very walk that found nothing.
5. `MeetingSessionController.stopRecording(file:source:summaryMode:)` tears the lifecycle down 12 ms later via its `coordinator.lifecycleCoord.disengage()` call ([`MeetingSessionController.swift`](../../../daemon/Sources/MeetingPipe/MeetingSessionController.swift)), so when the Leave button returns there is nothing left to talk to.

Every guard that should have caught this was bypassed rather than absent. `tick()` would have refused to promote forever, because `axLeaveButton.requiresCorroboration` is true and native Teams has no cross-class corroborator. END8's revert, the `case .live where event.kind.evidenceClass == leading.evidenceClass:` arm of `PromotionEngine.handleEndingProvisional`, would have fired on the returning signal, but the teardown at step 5 beat it. The contrast with the mute side is the whole defect in one line: `AXMuteButtonProbe` requires five consecutive unknown reads before it even re-resolves (`defaultRearmThreshold: Int = 5`, spent by `noteUnknownAndMaybeRearm(reason:)`) and latches the prior state throughout (`AXMuteButtonProbe.evaluate(reason:)`'s `if state == .unknown, let prev = lastEvent, prev.state != .unknown`, which emits `ax_mute_button_state_kept` and returns) ([`AXMuteButtonProbe.swift`](../../../daemon/Sources/MeetingPipeCore/MicGate/Probes/AXMuteButtonProbe.swift)), while the Leave signal needs one invalid read plus one empty walk.

The blackout it races is real and it is long. Measured two-sided on 2026-08-03: the mute element went unreadable at 12:51:19.064Z, both walks ran by 12:51:19.918Z, an independent discovery scan at 12:51:40.133Z still reported `leave_button:false, mute_button:false, calling_controls_toolbar:false, title_match:true`, and the full live-call signature returned at 12:51:52.277Z with score 11. So the blackout was at least 21.1 s and at most 33.2 s, and the two walks sit 120 ms apart inside it, with roughly 200x margin.

## Observed, not theorized

Three false ends on 2026-08-03, all `com.microsoft.teams2` pid 91771, all `confirmed_by: ["ax_leave_rewalk"]`.

`20260803-154305`: invalid 12:51:19.798Z, confirmed 12:51:19.918Z, stopped 12:51:20.675Z after 494 s. The transcript cuts mid-sentence on "И я зараз". The call really ended at 13:01:13Z, proven by Teams' own teardown line, so **9 m 53 s of meeting was lost**. The daemon re-detected the live call at 12:52:31Z, showed a prompt, and the prompt timed out at 12:53:01Z defaulting to skip, so the recovery path lost it a second time.

`20260803-163357`: invalid 13:53:04.885Z, confirmed 13:53:05.018Z, stopped 13:53:06.719Z after 1147 s. The owner hit Record on the re-prompt at 13:54:12.670Z, so this one cost 66 s and split one meeting across two stems.

`20260803-165412`: ended 14:27:06.878Z after 1972 s. This one looks like a genuine end (natural farewell in the transcript, no re-detect in the following 18 minutes) and is listed because it is the case the proposed fix handles worst, not best. See Scope.

The sharpest prior instance is 2026-07-29. `ax_leave_button_state` invalid at 13:00:34.212Z, confirmed 166 ms later at 13:00:34.378Z, recording stopped **91 seconds into the call**. The owner started a manual recording 6 seconds later: `20260729-155902.wav` is the 91 s fragment, `20260729-160040.wav` is the 25-minute re-record. The call really ended 25 minutes after the false end.

Population correction, because the obvious classifier is wrong. "Same pid restarts within 180 s" cannot separate a chopped call from a genuine back-to-back meeting, since Teams' pid persists across calls. That rule yields 14 candidates; content verification cuts it to **6 verified false ends**: 2026-06-09 08:50:41Z, 2026-06-09 09:06:25Z, 2026-07-29 13:00:34Z, 2026-07-30 13:33:19Z, 2026-08-03 12:51:19Z, 2026-08-03 13:53:04Z. Rejected: 2026-05-28 14:14:46Z and 2026-06-12 09:56:32Z are different meetings (full farewell, then a new topic and a different cast), 2026-07-02 14:17:41Z ends "take care guys bye bye", and six candidates had no recording in flight at all, five of those inside rebuild sessions with `swift test` writing fixtures into the live event log. Discriminators that worked: a mid-sentence cut versus a farewell, and speech-onset latency (a mid-call resumption starts at t=0.5-1.2 s, a genuine join has a 40-85 s silent lead-in).

## Three more instances, 2026-08-04 and 2026-08-06

Added 2026-08-10 from the owner's testing notes. These are the first occurrences **after** this spec was filed, both reported as unexplained ("got interrupted and recording stopped. no idea why, can you check?" and "in this meeting 20260806-163013 it suddenly stops in the middle of the meeting, looks like the case we had before related to new UI of teams"). All three carry this defect's exact signature: `ending_provisional` led by `ax_leave_button_invalid`, then `lifecycle_provisional_end_confirmed`, then `ended` with `confirmed_by: ["ax_leave_rewalk"]`, `com.microsoft.teams2` pid 91771. Times below are local (UTC+3); `events.jsonl` stores UTC.

`20260804-133028`: recording started 13:30:29, confirmed end 13:30:49, stopped after **21 s** with 1008 system-audio frames.

`20260804-133158`: started 13:31:58 off the reprompt 65 s after the previous end, took a **rescue** at 13:32:13 (`leave_buttons_found: 1`), then a confirmed end at 13:32:28, stopped after **30 s**. So one meeting was chopped twice inside two minutes and split across two stems, and after the second chop the owner stopped trying: no further recording that afternoon.

`20260806-163013`: started 16:30:13, confirmed end 16:31:59, stopped after **1 m 46 s**. The recovery path then cost two more prompts: a reprompt at 16:33:04 that the owner let time out at 16:33:34, and another at 16:34:41 that they accepted, producing `20260806-163446` which ran the remaining 22.7 min. So the call was recorded, but as a 1 m 46 s fragment plus a 22.7 min body with a 2.8 min hole between them.

The `20260804-133158` rescue is worth noting against the fix: the rescue path did its job once and then failed 15 s later on the same call, which is the blackout outlasting a single retry and is consistent with the 21.1 to 33.2 s measurement above.

**A correction this supplies to UX45's row.** UX45 records `20260804-133028` as investigated and not a defect: "correctly never reached publish and carries a `.empty.json` terminal marker with 0 segments and 0 characters, which is the no-speech skip path working as designed rather than a publish failure." Every clause of that is true and the conclusion is incomplete. The recording had no speech because it was **21 seconds long**, cut by this defect 20 seconds after it started. The skip path was working; what it was handed was a chopped recording. UX45's own scope (publish targets) is unaffected, so this is a note here rather than a reopen there.

These three do not change the fix. They land squarely inside the new-calling-UI window the A/B in the Owner walkthrough tests, so they are three more observations for the on arm and the pre-registered threshold is unchanged.

## Already refuted, do not re-derive

The intuitive cause is that the owner collapsed or backgrounded the call window, Teams tore down its call controls, and the compact mini panel had not yet been created. It is wrong, it is very convincing, and the codebase asserts it, so it will be re-proposed unless this section is read.

It was settled by direct measurement. MeetingPipe's own `SCShareableContent` polls are logged at INFO to the macOS unified log, which yields a 2 Hz census of Teams' on-screen windows across any recording, alongside `frontmostProcess:` and SkyLight window operations. For both 2026-08-03 ends: Teams was frontmost across the end (22.5 s before and 34.9 s after the first, 70.4 s before and 46.2 s after the second); Teams' two on-screen windows appear in all 1053 and all 2454 polls respectively with unchanged frames; and no window create or terminate occurred in the surrounding minute. The compact panel existed for 83 s **during** the call that later false-ended and was destroyed 20.8 s **before** the end when the owner fronted Teams, so the hypothesised configuration is a within-case control that produced no false end.

Two traps that manufactured false confirmation, both worth naming:

`found_call_panel: true` sampled after a false end is a selection artifact. Post-false-end engagements are sampled ~65 s later because of the reprompt cooldown, by which time the owner has moved on and Teams has created a panel. On 2026-08-03 the panel was added 47.3 s after the end and 1.05 s after Chrome took focus. It is caused by the later focus change, not by the end.

The codebase asserts the premise as fact, which is why it keeps being re-proposed. It said so most bluntly in `PromptEndPolicy.swift:7` (quoted as of 2026-08-04): "The Teams compact/mini window destroys the in-call Leave button, and the rescue re-walk can't re-find it on the redesigned mini window". Do not go looking for that file: ARCH6 deleted it on 2026-08-18 (`bd32468`) because its filter had been unreachable since START1, and the trail is in [`daemon/docs/gotchas.md`](../../../daemon/docs/gotchas.md#an-injection-seam-nothing-injects-and-a-guard-nothing-can-reach) under "An injection seam nothing injects, and a guard nothing can reach", plus the two call-site comments that replaced it, in `MeetingSessionController` ("Both branches below used to be gated on `PromptEndPolicy.clearsPromptState`") and `DetectionStateMachine.abandonPrompt` ("`PromptEndPolicy` used to be named here as the filter"), which name the guard that really holds, `PromotionEngine.handleStarting`'s `requiresCorroboration` check. The premise itself outlived the file and is still asserted in live code, at the top of `MeetingSessionController.rescueProvisionalEnd(context:)`: "Rescue a provisional end caused by the Teams 2 compact-view swap, which destroys the Leave button while the call continues" ([`MeetingSessionController.swift`](../../../daemon/Sources/MeetingPipe/MeetingSessionController.swift)). It is folklore either way, contradicted by the dated live AX dump recorded in `MeetingAXHandleBuilder.findMeetingWindowMuteButtons(in:bundleID:catalogue:)`'s doc comment, "What the dump showed, and why the old Leave anchor could never work" ([`MeetingAXHandleBuilder.swift`](../../../daemon/Sources/MeetingPipe/MeetingAXHandleBuilder.swift)), which says the backgrounded state exposes Leave in **two** windows including the panel.

What the mechanism actually is: an in-process Chromium/Electron accessibility-tree teardown and rebuild inside Teams. Every window stays on screen, unmoved, titled and readable, while Leave, Mute and the calling-controls toolbar vanish together and return together. Window titles come from AppKit and controls from the renderer, so "titled windows, zero controls" is precisely that signature, and it is what the independent discovery scan reported at 12:51:40.133Z. Corroborating but not proof: Teams WebView Helper renderer pids did fresh initialization 24.5 s after the end. A process-wide AX stall is not excluded and does not need to be, because the fix does not depend on which of the two it is.

## The new Teams calling UI, the amplifier

The owner switched on the new Microsoft Teams calling UI around 2026-07-28 to 07-30. The verified false ends cluster accordingly: two on 2026-06-09, then nothing for seven weeks, then 2026-07-29, 2026-07-30, and two on 2026-08-03. Four of the six fall in the six days from 2026-07-29.

Read it as an amplifier, not the root cause. The 2026-06-09 pair predates the switch, and the defect at the top of this file is independent of which UI renders the call. A new rendering path plausibly re-renders its accessibility tree more often or for longer, which raises the hit rate on a race that was always there. Note that the rate of `ending_provisional` events per recording is flat across the whole quarter (0.65 to 1.14 weekly since 2026-W22), so any correlation lives in the false-end subset, not in the provisional rate. Do not report a ramp measured on provisionals.

The owner has agreed to an A/B, which is the only clean causal test available. It is pre-registered in the Owner walkthrough below so the threshold is fixed before the data is seen.

## Execution contract

The owner asked for this order explicitly on 2026-08-03. Do not reorder it, and do not start the fix because the cause "seems obvious".

**Step 1, double-verify the root cause before touching any production code.** Two independent confirmations are required, and both are read-only.

(a) The unified-log window census, which is what refuted the collapse hypothesis. Retention on this machine is only a few days, so run it within 72 h of any incident:

```
log show --start "<end-time minus 5min>" --end "<end-time plus 3min>" \
  --predicate 'process == "MeetingPipe" OR process == "WindowServer"' --info --debug \
  | egrep 'SCRunningApplication initWithPID|SCWindow initWithDict|frontmostProcess:|TerminateWindow|CreateWindow|adding window|removing window|occluded'
```

Pre-registered reading: the hypothesis of a window-level cause is confirmed only if Teams' large windows drop out of the per-poll census inside the 60 s before the end, or something other than Teams is frontmost at the end. Both 2026-08-03 cases show neither.

(b) The teardown-oracle correlation, which is also the fix's evidence base. Parse `UnregisterCall` lines out of the SlimCore generations and correlate them against every `ax_leave_button_invalid`-led `ending_provisional` in `events*.jsonl`. Reproduced on 2026-08-04: 45 of 53 confirm within [-15 s, +5 s], 8 hold, and the holds contain every verified false end inside coverage. Re-run it at pickup; if the confirm rate has moved materially, the format or the owner's Teams build has changed and Scope needs re-examination before anything is built.

**Step 2, write the failing test first and show it red.** The regression fixture is the 2026-08-03 12:51:19Z trace, which is fully characterised above: a healthy-to-invalid edge, an empty re-walk, a second empty re-walk 120 ms later, then the live-call signature returning 32.5 s later. Drive `PromotionEngine` plus the new pure gate through that sequence with an injected clock and assert the recording is never stopped. It must fail against `main` for the right reason, and the failure output must be recorded in the task's progress notes before any fix lands. A test that passes before the fix is not pinning this defect.

**Step 3, fix last**, per Scope.

## Scope

Gate `confirmProvisionalEnd` on Teams' own call-teardown signal rather than on a second empty AX walk.

Teams writes one line per call teardown into its own media-stack log at `~/Library/Group Containers/UBF8T346G9.com.microsoft.teams/Library/Application Support/Logs/MSTeamsNM_SlimCore_<date>.<gen>.log`:

```
SlimCoreModule::WindowContentProtectionProvider: UnregisterCall <id>
```

It carries no localized text and no window reference; it is the lifetime of the call's DRM registration object. Measured over 2026-07-01 to 2026-08-03: 107 teardown lines against 53 in-coverage ax-leave provisionals, of which 45 confirm within [-15 s, +5 s] and 8 hold. It **leads** the daemon's AX edge (p50 about 1.3 s), so on a genuine end the answer is already on disk at the instant the provisional opens, and median added latency is zero. Zero false confirms were observed: the 7 teardown lines that land mid-recording (a side call ending while the recorded meeting runs) sit 2589.9 s from the nearest provisional.

The seam is one branch: the `guard let leaveButton = leaveButtons.first else { ... }` else-path inside `MeetingSessionController.rescueProvisionalEnd(context:)` ([`MeetingSessionController.swift`](../../../daemon/Sources/MeetingPipe/MeetingSessionController.swift)), the block that logs `lifecycle_provisional_end_confirmed` and then calls `coordinator.lifecycleCoord.confirmProvisionalEnd()`. That call consults the oracle instead of confirming unconditionally. On hold, do nothing: `tick()` already refuses to promote an uncorroborated ax-leave lead, so the hold is the behaviour the engine was written to have before the rescue path started overriding it, and the returning Leave button then reverts through END8 on its own.

Pure decision seam: `CallTeardownOracle.decide(_ input:) -> Verdict` in `MeetingPipeCore/Lifecycle/`, matching `MicGate.decide` and `MeetingSourceScorer.score`. No AX, no I/O, no clock of its own; the host forwards `now`, `provisionalStartedAt`, `lastTeardownAt`, `oracleAvailable` and the two constants in. The file tail runs on its own serial queue, never on main, and does no AX IPC at all.

Constants, each from the measurements above: `teardownLookbackSec = 15` (largest observed lead 6.82 s, so 2.2x margin) and `holdCapSec = 150` (above the largest in-coverage blackout, and it is the entire cost when the oracle is wrong, so deliberately not larger).

Gotchas that must be pinned by tests, all of them inherited from MIC8's spike on the same file family (`docs/spikes/mic8-native-mute-signals.md`). **Since 2026-08-04 they are also inherited as code**: MIC8's build shipped `MeetingPipeCore/MicGate/SlimCoreMuteLog.swift`, whose `generations` / `newest` / `tail` / `parseTimestamp` are exactly this read path (family resolution, the UTC parse, the byte-range tail with a partial-line carry, rotation re-resolve), and `LogMuteAdapter` beside it is the working example of the host half (own queue, 1 Hz tick, edge-triggered sink). Reuse them rather than writing a second SlimCore reader; only the line predicate differs, so the natural shape is a teardown-line parse beside `SlimCoreMuteLog.parse`.

- The `+03:00` suffix on every SlimCore timestamp is a lie. The naive clock value is UTC. Verified: the teardown at naive 07:41:22 on 2026-08-03 matches the 10:41 local end of `20260803-103042`.
- Resolve the log by file family, never by mtime. The directory holds several families and `MSTeams_<date>` is always fresher than the SlimCore generation.
- `.unavailable` must degrade to today's behaviour (confirm immediately), so the change can only ever be neutral or better.

Grafts carried in from the two rejected designs, each because a judge verified it necessary:

- **Trim on confirm.** `stopRecording(trimAt:)` into `RecordingPostProcessor.produceFinal(..., limitSeconds:)`, so a held tail is discarded and a real end publishes byte-for-byte what it does today. This is what stops the `holdCapSec` path from appending 150 s of post-call room audio. Lands after REC9, which is the open P1 on that same merge path.
- **A small `endDebounceFloor` for `.axLeaveButton`, about 5 s.** The oracle is consulted ~120 ms in, so it cannot help the sub-2 s flicker class. Verified returns at +0.64 s, +1.07 s and +1.69 s exist in the corpus; on 2026-06-09 09:06 the discovery scanner logged the full control set at score 11 **0.24 s before** the `ended` event. Cost is about 5 s on roughly 47 true ends per 34 days.
- **A title veto on any auto-resume.** Not optional. 2026-05-28 (+67.6 s) and 2026-06-12 (+64.6 s) are proven genuine back-to-back meetings inside any plausible resume grace; without the veto they would be recorded unconsented under the previous meeting's workflow and privacy posture. A nil or unreadable title is not a veto, so a mid-call re-title degrades to a prompt instead of blocking a legitimate resume.
- **A HUD "confirming end" state.** The cap path leaves a recording visibly running for up to 150 s after the user left the call. Without a surface that is a bug report, not an observation. Freeze the elapsed label and caption in `MPColors.fgSubtle`, which clears the DSN3 4.5:1 contrast floor where `fgFaint` does not. The force-stop hotkey confirms instantly with `trimAt = now`, because explicit user intent outranks the hold.
- **Make an empty walk distinguishable from a failed one.** `MeetingAXHandleBuilder.listWindows(axApp:)` ([`MeetingAXHandleBuilder.swift`](../../../daemon/Sources/MeetingPipe/MeetingAXHandleBuilder.swift)) collapses every non-`.success` AXError into `[]` (`guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success, let windows = windowsRef as? [AXUIElement] else { return [] }`), and `MeetingAXHandleBuilder.findButton` returns the same nil on 4000-node budget exhaustion as on genuine absence, so "Teams was busy" and "the call ended" are the same value at the call site. Return a result type. This is orthogonal to the oracle and is worth having on its own.
- **Correct the `PromptEndPolicy` comment: discharged, not carried.** ARCH6 deleted `PromptEndPolicy.swift` on 2026-08-18 (`bd32468`) and the comment went with it, so this graft has nothing left to correct. Recorded rather than dropped so the trail survives; it adds nothing back to this task's scope.

**ARCH6's deletion reopens nothing in this fix, checked when it landed and recorded here so a pickup does not re-derive it:** END9 makes confirmation strictly *stricter* (it gates `confirmProvisionalEnd` on Teams' teardown oracle instead of confirming on a second empty walk), so it cannot make a bare `ax_leave_button_invalid` `.ended` with an empty `confirmedBy` reachable again, and nothing above is invalidated.

The drift detector must be time-and-volume based, not "zero teardown lines in the newest two generations": a generation is created per Teams restart, so a freshly-restarted Teams that has not yet hosted a call would trip that naive check and silently disable the guard forever. Emit the drift event where the owner can see it.

## Explicitly not in scope

**A blanket end-debounce floor of 45 s or 90 s for `.axLeaveButton`.** Rejected: it pays its full cost on every Teams end forever, and it cannot be shortened because native Teams has no cross-class corroborator (`usesProcessAudio` is false for every native config after DET2, and `shareableContentWindow` shares an evidence class with `axLeaveButton` by construction). The ~5 s floor above is kept only for the sub-2 s flicker class the oracle structurally cannot reach.

**Unbounded keep-recording through an unconfirmed end.** Rejected on privacy: it captures post-hang-up room conversation on every meeting, and under the regulated and NDA postures that is audio at rest that ADR 0016 says must not exist. The bounded hold plus trim gets the same protection without the exposure.

**Per-process HAL audio as an end oracle.** Refuted by DET2 on real hardware, and must not be re-proposed: our own capture pins the default input and output RUNNING for the whole recording, so no device can read idle while we record.

**The six false ends that took the `.starting` / `.prompting` path** (2026-06-03, 2026-06-04 x2, 2026-06-05 x3). They emit no `ending_provisional` at all, none of them chopped a recording, and START1 already closed that path. Nothing here reaches them, correctly.

**Adjacency, named so it is not silently absorbed:** DET9 rewrites `MeetingSessionController.handleDiscovery(_:)`, and END9's resume exemption is inserted into the very same `isCoolingDown` branch inside it, the one opened by `if coordinator.stateMachine.isCoolingDown(bundleID: source.bundleID, cooldownSec: coordinator.liveRepromptCooldownSec)`. Land DET9 first, then END9 on top. They must not fight: the resume policy returns `.prompt`, never `.resumeRecording`, whenever the skip latch is armed, so a user who explicitly skipped is never auto-recorded by a DET9-hardened latch. Derive any new latch grace from the live `DiscoveryScanCadence` rather than hardcoding it, adopting DET9's fix preemptively instead of repeating its bug in a second latch.

**Observed but not filed here:** the `ConfigDefaults.repromptCooldownSec` gate (`static let repromptCooldownSec: Double = 60`, [`ConfigDefaults.swift`](../../../daemon/Sources/MeetingPipe/ConfigDefaults.swift)) is why 8 of the 14 candidate re-detect gaps cluster just above 60 s. It also means any blackout duration measured from a re-detect gap is floored by it and is not a blackout measurement. Do not quote those numbers as blackout durations.

## Acceptance

- A `PromotionEngine` plus `CallTeardownOracle` test drives the 2026-08-03 12:51:19Z sequence (healthy-to-invalid, empty walk, empty walk at +120 ms, live signature returning at +32.5 s) with an injected clock and asserts no `.ended` and no `stopRecording`. It fails against `main` before the fix, and the red output is recorded in this file's progress notes.
- A companion test asserts a genuine end still confirms promptly: a teardown line within the lookback promotes on the same tick, with no added latency.
- A test asserts `.unavailable` confirms immediately, so a missing or unparseable log degrades to today's behaviour rather than holding.
- A test asserts a held provisional **always** terminates, so the `holdCapSec` ceiling is a property of the pure type rather than of the timer plumbing. Two multi-thousand-second provisional stalls already exist in the log; this is the guard against a third.
- Table tests pin the two parsing gotchas: the naive-clock-is-UTC rule, and family-based generation resolution.
- A title-veto test using the real 2026-05-28 pair (`Dev Sync: Auth Rework, Multi-Tenancy & Team Repurposing` then `P5 Mobile Sprint Demo & Team Reassignment Planning`) asserts the second is not auto-resumed under the first's workflow.
- `cd daemon && swift build` and `swift test` green. CI runs the suite; full Xcode is needed to run it locally.
- `python3 scripts/truth_fences.py both` green, with any new event action documented in the `CONVENTIONS.md` event table in the same commit.
- The change emits an auditable event whenever it holds, carrying the reason and the elapsed hold, so the next occurrence is self-diagnosing from `events.jsonl` alone rather than needing this reconstruction.
- No U+2014 anywhere in the diff.

## Owner walkthrough

Two steps here are owner-gated. Follow them with the owner rather than re-deriving the procedure.

1. **[owner] The new-UI A/B, pre-registered before the data is seen.** Turn the new Teams calling UI **off** and run normally for 10 recorded meetings, then turn it back **on** for 10. The session records the false-end count per arm, classified by the transcript rule in Observed above (a mid-sentence cut is false, a farewell is true), not by the same-pid rule. Pre-registered reading: the new UI is confirmed as the amplifier if the off arm has at most 1 false end and the on arm has at least 4. Anything in between is inconclusive and the fix ships regardless, since the root cause is UI-independent.
2. **[owner] After any future false end, run the unified-log census within 72 h**, using the command in Execution contract step 1(a). Retention is short and the evidence is unrecoverable afterwards. Paste the output to the session; it is the only source that can distinguish a window-level cause from an in-process accessibility rebuild.
3. **[session] Re-run the teardown-oracle correlation at pickup** before building anything, and report the confirm rate against the 45-of-53 baseline recorded above.
4. **[owner] Eyeball the HUD "confirming end" state** once it is built. The daemon is a menu-bar app and is not screenshotable from a session, so this is owner-owed by construction.
