# ARCH12: the Library UI holds the concrete Coordinator and reaches through it for 12 members, and MeetingLibraryService takes ten closures whose defaults silently do nothing

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) A8, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) SA-8 adjacency). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

`LibraryWindowModel` (in `LibraryWindow.swift`) declares `weak var coordinator: Coordinator?`. Its doc comment says it is "Kept for the three things that are genuinely the Coordinator's" and then lists four. Read on 2026-10-24, the Library surfaces use 12 distinct `Coordinator` members through it:

- `LibraryWindow.swift`: `menuStart`, `menuPreferences`, `cancelActiveJob`, `dequeuePendingJob(id:)`, `summarizationUserLabel`, `regulatedMode`, `summarizationBackend`, `localModelPreflight` (twice), `publishTargets` (twice), and `coordinator?.preferencesWindow?.show(...)`.
- `MeetingDetailView.swift`, `AskView.swift` and `DigestsView.swift` each repeat the same pair of closures: `libraryModel.coordinator?.preferencesWindow?.show(initial: .pipeline)` (or `menuPreferencesIntegrations()`) and `{ libraryModel.coordinator?.downloadLocalModelNow() }`. That is three copies of a two-hop chain into a window object the view has no business knowing exists.

(`Design/RecordKey.swift`'s `context.coordinator` is SwiftUI's `NSViewRepresentable` coordinator and is unrelated.)

Because the type is concrete, no test can supply these behaviours: both places a test builds the model (`FailureLayoutTests`) call `LibraryWindowModel(recordingsDir:savedSearchesURL:)` and take the `coordinator: nil` default, and production itself constructs it without one in `Coordinator.init`, so every path that starts a recording, opens Preferences, cancels a job or reads the backend through the model is untested and returns its `?? default`. The defaults do not agree with each other: `LibraryWindowModel.summarizationBackend` falls back to `"anthropic"`, the closure `Coordinator` passes to `MeetingLibraryService` falls back to `"anthropic"`, and `MeetingLibraryService.init`'s own default is `{ "local" }` (ARCH14 owns the type; this task only stops the fallback being chosen in three places).

The model's collaborators are also attached after construction: `Coordinator.init` sets `libraryModel.workflowStore = workflowStore`, then after `super.init()` sets `libraryModel.coordinator = self` and `libraryModel.library = library`, each declared optional "so headless tests and the initial-state path don't need it".

`MeetingLibraryService.init` takes `launcher` plus ten closures (`outputDir`, `notifyError`, `enqueue`, `summarizationBackend`, `originalsDir`, `recordCorrection`, `enqueueRetranscribe`, `refreshLibrary`, `libraryRunLane`, `notifyFailure`). Seven have defaults that do nothing or answer falsely (`recordCorrection` returns `false`, `refreshLibrary` is `{}`, `libraryRunLane` returns `nil`, `enqueueRetranscribe` fails), so a construction site that forgets one compiles and degrades silently. Correction to the audit: these are passed at init, not "wired after init"; the after-init wiring is on `LibraryWindowModel`.

## Scope

1. **`LibraryHost` protocol** (in its own file beside `LibraryWindow.swift`) with exactly what the Library needs, named for intent rather than for the Coordinator's menu selectors: `startRecording()`, `openPreferences(pane:)` (one entry point replacing `menuPreferences`, `menuPreferencesIntegrations` and `preferencesWindow?.show(initial:)`), `cancelActiveJob()`, `dequeuePendingJob(id:)`, `downloadLocalModel()`, and a read-only snapshot for `summarizationUserLabel`, `regulatedMode`, `summarizationBackend`, `localModelPreflight` and `publishTargets`. `Coordinator` conforms in a `Coordinator+LibraryHost.swift`; `LibraryWindowModel.coordinator` becomes `weak var host: (any LibraryHost)?`.
2. **Route the three view copies through the model**: `MeetingDetailView`, `AskView` and `DigestsView` call `libraryModel.openPreferences(pane:)` and `libraryModel.downloadLocalModel()`, so no view names `coordinator` or `preferencesWindow`.
3. **Group `MeetingLibraryService`'s closures into two or three small port structs** passed at init with no defaults (for example a jobs port: `enqueue`, `enqueueRetranscribe`, `libraryRunLane`; a notify port: `notifyError`, `notifyFailure`, `refreshLibrary`; a config port: `outputDir`, `originalsDir`, `summarizationBackend`, `recordCorrection`). Tests build them from one `.fake()` helper, so forgetting one is a compile error, not a silent no-op.
4. Fix the `LibraryWindowModel.coordinator` doc comment as part of the rename.

## Explicitly not / out of scope

- Not a service locator in a new costume: `LibraryHost` lists intents, never subsystems, and does not expose `Coordinator`'s windows, stores or the job dispatcher.
- `StatusBarController` also holds `weak var coordinator: Coordinator?`. Same smell, different surface; leave it unless the change is trivially the same protocol, and say so in the commit body.
- `PipelineDriver`'s fat interface and the views that build their own `PipelineLauncher()` (`TranscriptTab`, `PeopleView`, two Preferences views) are ARCH5's driver leg.
- The session-side seam is ARCH7. A headless composition root for wiring tests (go-live SA-8) is T7's; this task gives it one more fakeable seam but does not build it.
- The backend's type and its fallback value are ARCH14's; this task passes whatever ARCH14 settles through the snapshot.

## Acceptance

- `grep -rn "coordinator" daemon/Sources/MeetingPipe/{LibraryWindow,MeetingDetailView,AskView,DigestsView}.swift` finds no reference to the app `Coordinator` (the doc comment and the protocol conformance file aside).
- A `FakeLibraryHost` in the test target and at least 5 new tests: Record from the empty Library calls `startRecording()`; each of the three "open settings" call sites requests the right pane; cancel and dequeue reach the host with the right id; the model's backend and regulated reads come from the host snapshot, not a literal fallback.
- `MeetingLibraryServiceTests` builds the service through the port structs with no defaulted closure left in `init`.
- `cd daemon && swift build` warning-clean, `swift test` green, `bash scripts/ci-local.sh` green, N new tests in the commit body. ARCHITECTURE.md's Library UI row names `LibraryHost` in the same commit.
