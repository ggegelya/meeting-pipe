# CONC10: An open alert or menu stalls every default-mode Timer on the detection, end-of-call, prompt and HUD paths, and the prompt and HUD cannot be clicked while an alert is up

Band origin: filed 2026-10-25 from the performance review (eight subsystem finders over HEAD 01e904a, every finding adversarially re-verified). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Review finding UI-7 (verified medium), re-checked against the tree on 2026-10-25.

**The mechanism.** `Timer.scheduledTimer` adds its timer to the current run loop in the default mode only. AppKit runs the main loop in `NSModalPanelRunLoopMode` for the whole of an app-modal session (`NSAlert.runModal()`, `NSApp.runModal(for:)`, `NSOpenPanel.runModal()`) and in `NSEventTrackingRunLoopMode` while a menu is tracking, so a default-mode timer does not fire until the alert is dismissed or the menu closes. Main-queue GCD blocks and `@MainActor` tasks keep running, because the main queue is serviced in the common modes, so the app looks alive. Two sites already account for this: `AudioPlaybackController` (`RunLoop.main.add(t, forMode: .common) // keep ticking during sheet/menu interactions`) and `PermissionsCenter.startPolling` (`RunLoop.main.add(t, forMode: .common)`).

**The modal sites.** 21 at 01e904a, all on main: `CorrectionWindow` 4 (for example `return alert.runModal() == .alertFirstButtonReturn ? .keep : .reopen`), `FailureDialog.show` and `FailureDialog.showDetails` (`NSApp.runModal(for: window)`), `LibraryDialogs` 4 (including the folder `NSOpenPanel`), `MeetingDetailView+Header` 4, `RosterRename.run` 1, and 6 in the Preferences panes (`PreferencesView+Pipeline` 1, `+Recording` 1, `+Integrations` 1, `+Storage` 3). Every one is user-initiated, but two are reached from a notification click while the owner may be in a call: a stem-less failure banner opens `FailureDialog.show` through `Coordinator`'s `notifier(_:didRequestFailure:stem:)`, and an Edit summary banner opens `CorrectionWindow`, whose load and save errors and close prompt are `runModal` alerts. This is an accessory app, so after the owner clicks back into Teams the alert can sit behind it, and it stays up until they find it.

**The timers that stop while it is up**, all `Timer.scheduledTimer` on the main run loop:

- `MeetingDiscoveryWatcher.armPollTimer` (`pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false)`): the discovery backstop, DET3's mic-busy sample, and the only path for a meeting no workspace notification announces.
- `DetectionStateMachine.startPromptTimeout` (`promptTimeoutTimer = Timer.scheduledTimer(withTimeInterval: timeoutSec, repeats: false)`) and `MeetingPromptWindow.scheduleAutoDismiss` (`dismissTimer`). The owner's config has `default_prompt_action = "skip"` and `prompt_timeout_sec = 30.0`, so for them the prompt simply outlives its 30 s; with `record` as the default action the auto-record does not happen and the start of the meeting is not captured.
- `MeetingLifecycleCoordinator.defaultScheduler` (repeating), which `reconcileTick` arms to advance END17's `.endingProvisional` toward `.ended`, and `MeetingSessionController.beginTeardownHold`'s oracle (`Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.consultTeardownOracle() }`). An ended meeting keeps recording until the alert closes.
- `MeetingAXWindowWatcher.defaultScheduler` and `LogMuteAdapter.defaultScheduler` (one-shot, re-armed): the MIC16 window watcher and the Teams log mute reader.
- `RecordingHUDWindow`'s `ticker` and `meterTicker`: the HUD clock and meter freeze.
- `AXMuteButtonProbe.defaultScheduler` and `ProcessAudioSignal.defaultScheduler`, which [PERF10](./PERF10.md) moves to queue `DispatchSourceTimer`s.

Already immune: `CallTeardownWatcher` (a `DispatchSourceTimer` since END10), `AXLeaveButtonSignal.queueScheduler`, and `ShareableContentSignal`'s queue scheduler.

**The panels go dead too** (the verifier's addition). During an app-modal session AppKit delivers mouse events only to the modal window and to panels whose `worksWhenModal` is true; it defaults to false, and nothing under `daemon/Sources` sets it. `MeetingPromptWindow` and `RecordingHUDWindow` build plain `NSPanel(...)` instances, so the prompt's Record and Skip and the HUD's Stop do nothing while any alert is up. Whether the Carbon hotkeys (`HotkeyManager`, `RegisterEventHotKey(..., GetApplicationEventTarget(), ...)`) still fire inside a modal session is not established; the owner walkthrough checks it.

**Menu tracking** is the same mechanism for shorter spans: the status-bar menu and every context menu run `NSEventTrackingRunLoopMode` while open, so the same timers pause for as long as a menu is held open.

P2 on the verifier's medium: every trigger needs the owner to open a dialog, and dismissing it restores everything. If the walkthrough finds the force-stop hotkey dead inside a modal session too, a live recording cannot be stopped from any control until the alert is found and closed, which breaks the promise that Stop and the hotkeys work during a recording; the owner may then promote this to P1.

## Scope

1. **Main-run-loop timers in the common modes.** [HYG17](./HYG17.md) item 4 creates `Schedulers.mainRunLoopRepeating` and `Schedulers.mainRunLoopOnce` in `MeetingPipeCore/Infra/`, byte for byte with no timing change. If it has landed, change those two helpers to create the `Timer` unscheduled and `RunLoop.main.add(timer, forMode: .common)`. If it has not, create them here under those names with the common-mode behaviour, and HYG17 rebases onto them. The five `defaultScheduler`s then inherit it. Side effect to watch: `AXMuteButtonProbe` and `ProcessAudioSignal` then also poll during menu tracking, so a slow Teams AX read could stutter an open menu until PERF10 moves them off main; if that shows up, leave those two on the default mode until PERF10 lands and say so in the commit body.
2. **Move the direct sites to the helpers**: `MeetingDiscoveryWatcher.armPollTimer`, `DetectionStateMachine.startPromptTimeout`, `MeetingPromptWindow.scheduleAutoDismiss`, `MeetingSessionController.beginTeardownHold`, and `RecordingHUDWindow`'s two tickers. Intervals and semantics unchanged.
3. **Let the two passive panels work during a modal session**: `panel.worksWhenModal = true` where `MeetingPromptWindow` and `RecordingHUDWindow` build their `NSPanel`. This must not change their nonactivating, never-key behaviour, which is the point of both panels.
4. **A fence on new default-mode timers.** A source-reading test in `MeetingPipeTests` that lists every remaining `Timer.scheduledTimer(` under `daemon/Sources` with its reason, failing on a new unlisted site and on a listed site that is gone (the `CLAUDE_ALLOWLIST` stale-entry contract). Seed: the three debounced saves (`ConfigStore`, `SecretsStore` and `GlossaryStore` `saveTimer`, where firing after the alert is harmless; [CONC8](./CONC8.md) is reshaping them), `StatusBarController`'s two display timers, and `SinkDispatcher.startStallTracking` (an elapsed-time check that only fires late).
5. **One sentence in `daemon/CLAUDE.md`'s existing timer entry** ("A repeat scheduled off the main queue needs a `DispatchSourceTimer`") naming the helper for main-run-loop timers, inside CI5's 800 B per-entry budget; if the entry cannot grow, the sentence goes in `daemon/docs/gotchas.md` under that entry's anchor.

Re-entrancy check, stated in the commit body: with these timers live during menu tracking, a timer path that ends in `StatusBarController.rebuildMenu` (`item.menu = menu`) can run while the menu is open. Main-queue GCD state changes already reach `rebuildMenu` during tracking today, so this is not a new class, but name which timer paths can reach it.

## Explicitly not

- Replacing the 21 `runModal` sites with sheets (`beginSheetModal(for:)`) or non-modal windows. It removes the app-modal session but not menu tracking, a `FailureDialog` reached from a notification has no parent window to attach a sheet to, and HYG17 item 6 is consolidating the confirms and folder pickers into two `LibraryDialogs` helpers, which is where a later sheet conversion would start. Observed, not filed.
- `AXMuteButtonProbe` and `ProcessAudioSignal` threading: [PERF10](./PERF10.md). Until it lands they inherit item 1's helper.
- HUD tick rates and tolerance: the task filed from finding UI-10 ([PERF26](./PERF26.md)) (the same review). Whichever lands second rebases onto the other.
- Keyboard focus on the panels: [UX27](./UX27.md) (P4). `worksWhenModal` governs mouse delivery during a modal session, not becoming key. The SwiftUI port of the panels: [ARCH16](./ARCH16.md) (P3).

## Acceptance

- `MeetingPipeTests` cases for each helper: a timer it schedules fires while the main run loop runs only in `RunLoop.Mode.modalPanel`, and again only in `.eventTracking`; a control `Timer.scheduledTimer` in the same test does not fire in `.modalPanel` within the same window, so the test fails against today's helpers. If the test host has not registered AppKit's modes as common, the test registers them with `CFRunLoopAddCommonMode` first, as AppKit does, and says so.
- The item 4 fence passes on the landing tree and fails on a planted `Timer.scheduledTimer(` in a scratch source file (tried and reverted, said in the commit body).
- Both panels set `worksWhenModal`: a test where the panel can be built headless, otherwise a source fence that says why.
- Existing `MeetingLifecycleCoordinator`, `DetectionStateMachine`, `MeetingDiscoveryWatcher`, teardown-hold and `RecordingHUDTests` suites green with their fake schedulers unchanged.
- `cd daemon && swift build` and `swift test` green, N new tests in the commit body; `bash scripts/ci-local.sh` green.

## Owner walkthrough

Needed because event delivery into a nonactivating panel during a real `runModal` session, and whether Carbon hotkeys fire inside one, depend on the window server and real input, which a headless test cannot reproduce, and the daemon's windows are not screenshotable from a session.

1. [owner] On the current build, before the change: start a manual recording with the record hotkey, open the Library, choose Move to Trash on any meeting and leave the confirm open. Watch the HUD clock for 10 s, click the HUD's Stop, then press the force-stop hotkey. Report whether the clock moved, whether Stop did anything, and whether the hotkey stopped the recording, then Cancel the alert.
2. [session] Record the answers in this file. If the hotkey did not stop it, put the P1 question to the owner before landing.
3. [owner] After `./scripts/rebuild.sh` with the change: repeat step 1. The HUD clock keeps counting with the confirm open, and the HUD's Stop stops the recording.
4. [session] Quote the `recording_stopped` rows for both runs (`mp logs --action recording_stopped`) in the commit body.
