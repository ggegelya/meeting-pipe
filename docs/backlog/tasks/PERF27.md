# PERF27: A failure's Details window leaks on every click, and tutorial anchors republish on every scroll and resize while no tour runs

Band origin: filed 2026-10-25 from the performance review (eight subsystem finders over HEAD 01e904a, every finding adversarially re-verified). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Two small long-uptime costs in the UI layer, review findings UI-11 and UI-14 (both verified low), re-checked against the tree on 2026-10-25. One task because each is a few lines and neither earns its own.

**`FailureDialog.showDetails` leaks its window (UI-11).** It builds `let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 460), styleMask: [.titled], backing: .buffered, defer: false)`, then `let host = NSHostingController(rootView: FailureDetailsView(failure: failure) { NSApp.stopModal(); window.orderOut(nil) })`, `window.contentViewController = host`, and `NSApp.runModal(for: window)`. The close closure captures `window` strongly, and the window owns the host, which owns the root view, which owns the closure, so the window, its hosting controller and the diagnostics text it shows (often a full stderr tail) are never freed. The window is only ordered out, never closed, and its `contentViewController` is never cleared. One leak per Details click, for the process lifetime. It is reached from all seven `FailureDialog.show` call sites (including a stem-less failure banner's click in `Coordinator`'s `notifier(_:didRequestFailure:stem:)`) and directly from the model-download Details row in `StatusBarController` (`FailureDialog.showDetails(FailurePresentation(diagnostics: error, operation: .model))`). Small and rare per click; the review checked every other window (Preferences, Diagnostics, Guide, Correction) and each is released on close through its delegate, so this is the one exception.

**Tutorial anchor frames publish with no tour running (UI-14).** `.tutorialAnchor(_:)` reports its control's frame through the `TutorialAnchorFrames` preference. `TutorialStage`, on the Library root and the Preferences root, forwards every change: `.onPreferenceChange(TutorialAnchorFrames.self) { frames in TutorialSession.shared.report(frames, on: window) }`. `TutorialSession.report` dedupes only on equality (`guard frames[window] != reported else { return }; frames[window] = reported`) into `@Published private(set) var frames`, with no `run != nil` gate. Scrolling a Preferences pane that carries an anchor (`.speakerLabels` in `PreferencesView+Pipeline`, `.regulatedMode` in `PreferencesView+Permissions`, `.vocabulary` in `VocabularyEditor`) or resizing the Library therefore publishes on every frame, and both stages, each holding `@ObservedObject private var session = TutorialSession.shared`, re-evaluate, although FEAT15's tour runs only when someone picks Tutorial... from the menu. The stage is a `ViewModifier` whose `content` is not rebuilt, so each re-evaluation is cheap: waste, not a stall.

## Scope

1. **`FailureDialog.showDetails`**: capture `[weak window]` in the close closure, and after `NSApp.runModal(for:)` returns set `window.contentViewController = nil`. If the pickup prefers `close()`, set `isReleasedWhenClosed = false` first: a window built with `init(contentRect:styleMask:backing:defer:)` defaults it to true, and the extra release on `close()` is a crash risk under ARC. Lift the window construction into a function that returns the window, so a test can hold it weakly without entering a modal session.
2. **`TutorialSession.report`** keeps the latest frames per window in a plain, unpublished cache and writes the published `frames` only while `run != nil`. `start(steps:)` seeds `frames` from the cache, so the first step's anchor is there at once rather than after the next layout pass (the verifier's caution: without the seed the tour opens before any anchor reports).

## Explicitly not

- The failure dialog's titles, explanation text and relaunch survival: [UX93](./UX93.md). Both touch `FailureDialog`, in different functions; whichever lands second rebases.
- Moving `TutorialSession` to `@Observable`: [ARCH15](./ARCH15.md) lists it among the classes that migrate on touch, and Observation would still publish a changed frame.
- `Notifier.doneEntries` growing unboundedly (review UI-12 and MAINTHREAD-11): amended into [UX93](./UX93.md), whose item 4 already moves the failure map's state into `userInfo`. `PermissionsCenter.commit` publishing unchanged statuses (UI-13): amended into [OBS5](./OBS5.md), which edits the same function. The Guide's re-parse on rail hover (UI-15): amended into [PERF13](./PERF13.md) item 4.
- Adding tutorial anchors to the prompt or HUD: ARCH16's recorded adjacency.

## Acceptance

- A test that builds the details window through the lifted function, runs its close closure, drops the strong reference, and sees weak references to the window and its hosting controller go nil.
- `TutorialTests` cases: with no run, `report` changes no published state (an `objectWillChange` subscriber counts zero) while the cache holds the frames; `start(steps:)` after a report exposes the first step's anchor frame immediately; during a run, a changed frame publishes once.
- `TutorialFenceTests` green unchanged.
- `cd daemon && swift build` and `swift test` green, N new tests in the commit body; `bash scripts/ci-local.sh` green.
