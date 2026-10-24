# ARCH7: the session spine is one object behind a 26-member seam, so MeetingSessionController reaches back into Coordinator 150 times and owns none of the meeting-scoped subsystems it drives

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) A1, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) SA-4 session half). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

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
