---
id: ARCH7
title: The session spine is one object behind a 26-member seam, so MeetingSessionController reaches back into Coordinator 150 times and owns none of the meeting-scoped subsystems it drives
category: Architecture
status: new
priority: P2
comment: Filed 2026-10-24 (audit band, arch A1, go-live SA-4): Coordinator is 851 lines with 38 stored properties and two IUOs wired after super.init, and the controller reads all 26 SessionHost members 150 times, a service locator not a seam. Freeze the seam with a count fence, move MicGate, lifecycle, backstop, teardown and the state machine into the controller, collapse the live* reads into one snapshot. [Spec](./ARCH7.md) Amended 2026-11-13 by the audit band: the controller is now 1,980 lines with 29 mutable fields whose separate reset sites produced SEC39, END20, MIC23 and a leaking routing hint, so per-meeting and per-prompt state become values that die with them (F049, D072).
---

# ARCH7: the session spine is one object behind a 26-member seam, so MeetingSessionController reaches back into Coordinator 150 times and owns none of the meeting-scoped subsystems it drives

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) A1, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) SA-4 session half). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

TECH-ARCH2 moved the per-meeting logic out of `Coordinator` into `MeetingSessionController`, and ARCH4 put the `SessionHost` protocol between them so the controller could be built in a test. Neither shrank the spine. Measured against `main` on 2026-10-24:

- `Coordinator.swift` is 851 lines with 38 stored properties at class level and 129 commits. Two of those properties are implicitly unwrapped and wired after `super.init()`: `var jobDispatcher: PipelineJobDispatcher!` and `var session: MeetingSessionController!`. `lazy var library` is forced inside `init` while `jobDispatcher` is still nil, which is why its closures resolve `self?.jobDispatcher` lazily (the PIPE11 comment beside `libraryRunLane` says so).
- `MeetingSessionController.swift` is 1,622 lines. It holds `unowned let coordinator: any SessionHost` and reads through it 150 times (`grep -oE "\bcoordinator\.[a-zA-Z]+"`), touching all 26 of `SessionHost`'s direct members. The top readers: `coordinator.stateMachine` 45, `coordinator.notifications` 14, `coordinator.audioRecorder` 12, `coordinator.statusUI` 11, `coordinator.lifecycleCoord` 10.
- `SessionHost` mixes three kinds of member: meeting-scoped subsystems the controller is the main driver of (`stateMachine`, `micGate`, `lifecycleCoord`, `callTeardown`, `liveCallSignal`, `silenceBackstop`, `consent`), protocol-typed UI and IO ports (`statusUI`, `notifications`, `audioRecorder`, `hud`, `prompt`, `jobs`), and eight `live*` config reads plus `configStore`, `dryRun` and `micAuthorizationStatus`. A protocol that hands out every collaborator is a service locator, not a seam: a change to how a meeting runs still lands in two files, and every new collaborator becomes a new protocol member, a new `Coordinator+SessionHost` line and a new `FakeSessionHost` stub.

Usage outside the controller, which bounds what can move: `micGate`, `lifecycleCoord`, `silenceBackstop` and `callTeardown` are referenced only by `Coordinator.swift` (construction and start), `SessionHost.swift` and `MeetingSessionController.swift` (plus `MeetingAXHandleBuilder` naming `MicGate` as a type). `stateMachine` is also read by `Coordinator+Delegates` (prompt-delegate guards such as `guard case .prompting(let pending) = stateMachine.current`), `Coordinator+Automation` (`guard case .idle = stateMachine.current`) and `StatusBarController` (`coordinator?.stateMachine.liveSuppressedCandidate()`). `consent` (`ConsentStore`) is used across the app, Preferences and `MeetingDiscoveryWatcher` included.

The `MeetingSessionController` doc comment also documents its `@unchecked Sendable` main-queue invariant by convention only; that is CONC6's, not this task's.

## Scope

Green to green, in two or three commits, each with `swift test` green and no behaviour change:

1. **Freeze the seam now.** Add no new member to `SessionHost`. A fence test in `MeetingPipeTests` counts the protocol's direct requirements and fails above the current 26, with a message pointing here; each later commit lowers the ceiling to the new count.
2. **Move the controller-only subsystems into the controller.** `MicGate`, `MeetingLifecycleCoordinator`, `IdleStopBackstop`, `CallTeardownWatcher` and the `liveCallSignal` derived from it are constructed by (or injected into) `MeetingSessionController.init`, which becomes their owner. `Coordinator` keeps only what it needs to start them and reaches them through `session`. Remove the matching `SessionHost` members and `FakeSessionHost` stubs; tests inject the subsystems the way `FakeSessionHost` builds them today.
3. **Move `DetectionStateMachine` behind the controller.** The three outside readers (`Coordinator+Delegates`, `Coordinator+Automation`, `StatusBarController`) read state through a narrow read-only accessor on `session` (current state, suppressed candidate, skip latch), not the machine itself. `consent` stays on `Coordinator` because Preferences and discovery read it; pass it into the controller's init instead of through the host.
4. **Collapse the config reads.** Replace the eight `live*` getters plus `configStore` and `dryRun` with one `LiveConfig` value the controller reads at the points it reads them today (one getter returning a struct snapshot). `SessionHost` ends as the six UI and IO ports, `menuPreferencesPermissions`, `micAuthorizationStatus` and that snapshot.
5. **Construct `session` and `jobDispatcher` before `super.init()`** if step 2 removes the reason they were IUO; if something still needs `self`, record what in the commit body and leave the IUO.

## Explicitly not / out of scope

- Not a rewrite of `Coordinator`, and no new target. The `MeetingPipeCore` island rules (pure `decide()`) are unaffected; nothing here moves into Core.
- Not making the controller `@MainActor` or changing its `@unchecked Sendable`. CONC4 measured that cascade (2 warnings to 22) and CONC6 owns the main-thread assertion.
- Not touching the Library back-reference (`LibraryWindowModel.coordinator`), which is ARCH12, nor the recorder internals, which are ARCH8.
- Not changing what any end-of-call rule decides. T8 owns the end-of-call replay harness and moving `TeardownHold`'s timer policy into Core; if T8 lands first, step 2 moves the host half it leaves behind.
- Config reading itself (`ConfigStore` failing open) is ARCH9; the `LiveConfig` snapshot here reads whatever `ConfigStore` publishes and must not add a second parser.

## Acceptance

- The `SessionHost` member-count fence exists and its ceiling is at most 12 after the last commit (six ports, `menuPreferencesPermissions`, `micAuthorizationStatus`, the config snapshot, and at most three survivors each justified in the commit body).
- `grep -oE "\bcoordinator\.[a-zA-Z]+" MeetingSessionController.swift | wc -l` falls from 150; the commit bodies record the before and after counts.
- `MeetingSessionControllerTests` and `MeetingSessionControllerBranchTests` stay green with `FakeSessionHost` shrunk to the remaining members. At least 3 new tests construct the controller with injected subsystems and drive one prompt-to-record and one record-to-stop path without a `Coordinator`.
- `cd daemon && swift build` warning-clean under the existing `-strict-concurrency=targeted`, `swift test` green, `bash scripts/ci-local.sh` green, N new tests stated in each commit body.
- ARCHITECTURE.md's "State machine + dispatch" row and the `SessionHost` doc comment describe the new ownership in the same commit as the move.

## Amendment 2026-11-13 (audit band)

From the [independent audit](../../audits/2026-11-12-independent-audit.md) F049 (confirmed, known as this task) with the [recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md) D072 folded in, re-measured at HEAD on 2026-11-13.

**The controller has grown, and its per-meeting state is now producing defects.** `MeetingSessionController.swift` is 1,980 lines (1,622 at filing on 2026-10-24) with 56 `func` declarations; the audit counted 31 stored properties, 29 of them mutable, across about 14 responsibilities (verdict consumers, start, stop and its warnings, sidecars, prompt timeout, DET1, resume, idle backstop, MicGate, lifecycle builds, teardown hold, markers, off-record). `Coordinator.swift` is 930 lines (851 at filing). The recording reliability audit's session-orchestration note sorts the 29 fields into 15 lifecycle-phase fields that together form an unwritten state machine (`recordingStartInFlight`, `endObservedDuringStart`, `holdPolicy`, `cancelHoldTimer`, `pendingEndTrimAt`, `resumeCandidate`, `pendingResumedFrom`, `lifecycleBuild`, `lifecycleBuildGeneration`, `recordStartBuildID`, `recordStartBuilt`, `recordStartAttach`, `micTierPromptSource`, `micTierPromptBundle`, `micTierRecordingBundle`), 8 per-recording payload fields, 2 per-prompt payload fields (`pendingWorkflowOverride`, `preselectedRoutingHint`) and 4 of plumbing.

Each of these values lives on a process-lifetime object with its own reset site, and the band filed three defects that are that one pattern: [SEC39](./SEC39.md) (a workflow picked in a skipped prompt stays armed in `pendingWorkflowOverride`, whose only clear is in `beginRecording`), [END20](./END20.md) (`endObservedDuringStart` is latched only from one origin and the start in flight is a private `Bool`, not a state) and [MIC23](./MIC23.md) (a source-less start never reaches `engageMicGate` and MicGate keeps its last verdict across stop). Those tasks fix their instances; this amendment owns the shape that keeps producing them.

**D072, partially confirmed at filing.** `preselectedRoutingHint` is set when a prompt is shown (`preselectedRoutingHint = (suggestion?.preselects ?? false) ? (source: source, workflowID: suggestion!.workflowID) : nil`) and cleared only in `beginRecording`; neither `notifier(_:didChooseSkip:)` nor the prompt-timeout skip branch in `startPromptTimeout(for:)` clears it. `AppSource.==` compares `bundleID`, `displayName` and `kind` and ignores `meetingTitle`, so a later start for the same app that shows no prompt of its own (a hotkey start, an attach, an auto-consent start) passes `hint.source == source` and records under a workflow suggested for the earlier meeting. `micTierPromptBundle` leaks the same way: it is armed once a prompt is committed and cleared in `beginRecording` and the resume path, not on skip or timeout, so a later promptless start of that bundle reads `isMicTierRecording` as true and takes the DET1 end policy. Correction at filing: the audit's regulated "silent start" symptom does not follow from either value; both change which workflow or end policy a recording gets, not whether it starts.

**Added to scope:**

- Step 6: group the per-meeting payload into one `Session` value created when a recording commits and dropped when the controller returns to idle, and the per-prompt payload (`pendingWorkflowOverride`, `preselectedRoutingHint`, `micTierPromptBundle`, `micTierPromptSource`) into one `PromptContext` value created when a prompt is committed and dropped on record, skip, timeout or abandon. A reset then cannot be forgotten, because there is no field to reset. The phase fields move behind one explicit phase enum on the controller where step 3's state machine does not already own them; if that is too large for one commit, the per-prompt value lands first, since it closes D072 and SEC39's leg on its own.
- Step 7: split the teardown hold (`holdPolicy`, `cancelHoldTimer`, `pendingEndTrimAt`) and the PERF15 build orchestration (`lifecycleBuild`, `lifecycleBuildGeneration`, `recordStartBuildID`, `recordStartBuilt`, `recordStartAttach`, `recordStartBuildDeadlineSec`) into their own types owned by the controller. T8 still owns the hold's timer policy; this moves only the state.
- Coordination: [ARCH22](./ARCH22.md) splits the executable into targets; the types introduced here land in whichever target ARCH22 assigns the session to, and whichever task lands second moves them. [ARCH12](./ARCH12.md) is unaffected.

**Added to acceptance:** a `MeetingSessionControllerTests` case per leak: a prompt that shows a preselecting routing hint, then a Skip, then a hotkey start for the same app records under the rule-matched workflow, not the hinted one (fails on `main`); the same with a timeout skip; a mic-in-use prompt skipped, then a hotkey start of that bundle, is not tagged as a DET1 recording (fails on `main`). A structural test that the controller's stored-property count does not exceed the post-split ceiling the commit body states, beside the `SessionHost` count fence. `MeetingSessionControllerBranchTests` stays green; new test counts in each commit body.
