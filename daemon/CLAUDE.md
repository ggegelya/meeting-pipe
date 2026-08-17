# daemon/ — Swift menu-bar app

Loaded when you touch files in this subtree. The full subsystem map is in [`../ARCHITECTURE.md`](../ARCHITECTURE.md); patterns in [`../CONVENTIONS.md`](../CONVENTIONS.md); terms in [`../ARCHITECTURE.md#glossary`](../ARCHITECTURE.md#glossary). This file is the short list of things that bite if you forget them.

Each rule is one line and links to [`docs/gotchas.md`](docs/gotchas.md) for the incident that produced it, most of which record a measurement. **Read the linked section before you argue with a rule, change it, or decide your case is the exception.** Keep the split that way round: rules here, evidence there. A new rule is a line here plus a section there, in the same commit, and never a paragraph here (DOC14; `scripts/truth_fences.py claude` enforces it).

## Build + test

```bash
swift build               # from daemon/
swift test                # full Xcode required locally (CI on macos-14 has it)
../scripts/coverage.sh swift   # T3: llvm-cov report, not a gate; needs full Xcode
```

`swift test` fails with `import XCTest` if only Command Line Tools are installed. Write tests anyway — CI runs them. To run locally, `sudo xcode-select -s /Applications/Xcode.app` first.

## Patterns to match

- **Strict concurrency is on for this target too.** A new `Sendable` warning is a real cross-thread finding; fix it, don't silence it. Two documented `@unchecked Sendable` exist; don't add a third. → [gotchas](docs/gotchas.md#strict-concurrency-is-on-for-this-target) (CONC4)
- **Pure logic on its own type with explicit inputs.** Lift non-trivial branching into a `decide(at:…) -> Action` on its own struct. "It is only presentation" is a reason to extract, not to skip. → [gotchas](docs/gotchas.md#pure-logic-on-its-own-type-with-explicit-inputs) (T3)
- **`MeetingSessionController` talks to `SessionHost`, not `Coordinator`.** A new subsystem goes on `SessionHost` and `FakeSessionHost`; a global read has to come through the host. → [gotchas](docs/gotchas.md#meetingsessioncontroller-talks-to-sessionhost-not-coordinator)
- **Fully-qualified type name in stored-property initializers.** `Self.foo` fails on Swift 5.9+; write `StatusBarController.foo`. → [gotchas](docs/gotchas.md#fully-qualified-type-name-in-stored-property-initializers)
- **Combine subscriptions filter to value changes.** `removeDuplicates()` + `dropFirst()` before triggering rebuilds. → [gotchas](docs/gotchas.md#combine-subscriptions-filter-to-value-changes)
- **`ObservableObject` + `@Published` debounce writes.** `ConfigStore.scheduleSave` is the template: 500 ms timer gated on `isInitialized`. → [gotchas](docs/gotchas.md#observableobject-and-published-debounce-writes)
- **TOML round-trip preserves unknown keys.** Read into `TOMLTable`, mutate only what the UI models. New tables need `ensureTable("foo")`; the glossary preserves per *key*, not per table. → [gotchas](docs/gotchas.md#toml-round-trip-preserves-unknown-keys) (FEAT11, UX44)

## Don't

- Don't call Anthropic / Notion APIs from the daemon. Outbound HTTP belongs in the pipeline. → [gotchas](docs/gotchas.md#no-outbound-http-from-the-daemon)
- Don't `bootout` the resident `com.meetingpipe.daemon` agent, and don't add a second mechanism for login-start. `LaunchAtLoginService` is the one owner, and it owns relaunch-after-quit too. Editing `scripts/lib/login-agent.sh` means re-running `sh scripts/test-login-agent-guard.sh`. → [gotchas](docs/gotchas.md#launch-at-login-has-one-owner) (UX42, UX55)
- Don't run a `Process` round-trip on main because the control around it looks cheap, and don't cache a machine reading for a view's lifetime. Every `launchctl` call is watchdogged and off-main; the pane re-reads on `.onAppear`, never per render. → [gotchas](docs/gotchas.md#a-preferences-control-that-shells-out-is-on-the-freeze-list-too) (UX67)
- Don't add startup work to `App.main()` above `SingleInstanceGuard.standDownIfPeerIsRunning()`. Its exit status must stay `EXIT_SUCCESS`, and never read this process's identity from `NSRunningApplication.current` there — before `NSApplication` it is a placeholder with pid -1. → [gotchas](docs/gotchas.md#startup-work-and-the-single-instance-guard) (UX54)
- Don't add a key to `MeetingMetaSidecar.build` without also updating `mp.workflow.apply_overrides`. One contract, two sides. → [gotchas](docs/gotchas.md#the-sidecar-is-a-single-swift-to-python-contract)
- Don't read a per-sink sidecar (`<stem>.notion.json`) to learn whether a run published; read `<stem>.publish.json` via `PublishResult.resolveState`. Changing the Python writer means regenerating the CI4 fixtures. → [gotchas](docs/gotchas.md#publish-state-comes-from-publishjson) (PIPE1, PIPE14)
- Don't spawn `mp summarize` / `mp publish` for an existing meeting outside the pipeline lane; enqueue a `.libraryRun` job. Inside the lane, the regenerate chain calls `performRepublish`, not `republishMeeting`. → [gotchas](docs/gotchas.md#re-runs-go-through-the-pipeline-lane) (PIPE11)
- Don't report a subprocess this app killed as a failure. Ask `PipelineLauncher.isCancellation(err)` first. A cancelled job still completes as a failure and still writes a marker; the cancel flag is per run, never a bool on the launcher. → [gotchas](docs/gotchas.md#a-subprocess-this-app-killed-is-not-a-failure) (UX50)
- Don't log or write files from inside an audio render callback. Real-time threads; blocking work glitches the recording. → [gotchas](docs/gotchas.md#nothing-blocking-inside-an-audio-render-callback)
- Don't merge the two capture channels without an explicit length policy, and don't let a byte count stand in for "the merge worked". `RecordingPostProcessor.mergeLengths` is the policy; a late-starting channel carries the END of the meeting, so it must be delayed, not zero-anchored. → [gotchas](docs/gotchas.md#the-two-capture-channels-need-an-explicit-length-policy) (REC9)
- Don't re-open a capture file to resume writing it — `AVAudioFile(forWriting:)` truncates. Keep the handle and pad the gap. And don't leave a teardown path unbounded because a sibling path is bounded. → [gotchas](docs/gotchas.md#never-re-open-a-capture-file-to-resume-writing) (REC10, REC11)
- Don't take Teams' mute state off the newest file in its log directory, don't believe the timezone that file prints (UTC with a local offset suffixed), and don't add a third app-mute producer without a source tag. → [gotchas](docs/gotchas.md#teams-mute-state-and-how-to-read-its-log) (MIC8)
- Don't `print(...)` for event-stream data. Use `Log.event(category:action:attributes:)`. A new category goes in the `CONVENTIONS.md` table in the same commit, snake_case, fenced by `scripts/truth_fences.py`. → [gotchas](docs/gotchas.md#event-stream-data-goes-through-logevent) (CI5)
- Don't hardcode a config default at its read site when more than one reader needs it. `ConfigDefaults` is the single home. → [gotchas](docs/gotchas.md#config-defaults-live-in-configdefaults) (ARCH5)
- Don't put a parenthetical promise about the network in a control's copy without deriving it from the routing. `DigestNarration` is the digest's owner. → [gotchas](docs/gotchas.md#network-promises-in-copy-are-derived-from-the-routing) (UX63)
- Don't spell a summarization backend's display name at its render site. `SummarizationEngine` is the one home, in three registers. A new backend adds one entry there and one `WorkflowBackend` case. → [gotchas](docs/gotchas.md#backend-display-names-live-in-summarizationengine) (UX31)
- Don't describe a privacy clamp in copy written beside it rather than derived from it. Every string builds from `RegulatedMode.effectiveBackend`, and the copy is gated on whether the clamp actually moves anything. → [gotchas](docs/gotchas.md#regulated-mode-copy-is-derived-from-the-clamp) (UX60)
- Don't spell a publish sink's name at its render site, and don't infer the destination from anything but `<stem>.publish.json`. `page_url` says what to open, not who wrote it. A notification action's title is baked into its category at registration. → [gotchas](docs/gotchas.md#publish-sink-names-live-in-publishlanding) (UX49)
- Don't treat a test that two write paths agree as a test that they conflict. `TranscriptOverlayCarry.carry` takes the meeting's resolved glossary terms and counts a contradicting correction apart from `carriedCorrections`; matching is `Clarify.containsTerm`, never a looser rule. → [gotchas](docs/gotchas.md#a-no-op-test-is-not-a-conflict-test) (UX66)
- Don't read a transcript row's speaker off `segment.speakerID`, and don't let one row answer "who is this line" twice. `MeetingCast.rowSpeaker(for:overlay:voiceprintLabels:)` is the one read; `MeetingCast.colorIndex(for:in:)` is the only way to a speaker hue. → [gotchas](docs/gotchas.md#one-row-one-speaker-identity) (UX57, UX58, UX59)
- Don't add a config key to `Config.swift` / `ConfigStore.swift` without a consumer and a line in `config.example.toml`. CI5 fails on a dead knob. → [gotchas](docs/gotchas.md#a-config-key-needs-a-consumer)
- Don't add a field to `<stem>.summary.json` on the Python side without modeling it in Swift's `MeetingSummary` — an unmodeled field is deleted, not preserved. And `<stem>.summary.json`'s mtime never means "generated then"; read `<stem>.run.json`'s `ts`. → [gotchas](docs/gotchas.md#fields-in-summaryjson-must-be-modeled-in-swift) (FEAT10, UX41)
- Don't let a window that holds user-authored text write a record about a file it read once and never re-checked. Re-read and compare identity at save time, and say what moved. → [gotchas](docs/gotchas.md#a-window-holding-user-text-must-re-check-what-it-read) (UX65)
- Don't keep a running job's state in a view the navigator rebuilds. Run state lives on `LibraryRootView` as a `@StateObject`. An unstructured `Task {}` is NOT cancelled when its view dies. → [gotchas](docs/gotchas.md#run-state-must-outlive-the-view-that-started-it) (UX37)
- Don't finish an operation that rewrote a meeting's files without publishing `MeetingStore.revision`, and don't grow a second signal beside it. Publishing is almost never the problem; the break is a pane with `.task(id: meeting.stem)` or `.onAppear` over a disk read. → [gotchas](docs/gotchas.md#finish-an-operation-by-publishing-meetingstorerevision) (UX52, UX53)
- Don't keep state a step must not lose in a view the navigator rebuilds, and don't treat `WorkflowStore.delete` as guaranteed — it returns `false` for the default. `WorkflowDeletion.run` is the one delete flow; an editor saves through `update`, never `upsert`. → [gotchas](docs/gotchas.md#step-state-must-outlive-a-navigator-rebuild) (WF9, UX30)
- Don't pile inline styles into a SwiftUI view, and don't declare a shared-looking primitive `private`. New primitives go in `Preferences/PreferencesControls.swift` or `Design/MPButtonStyle.swift`. A real second caller is the trigger to promote, not a hypothetical one. → [gotchas](docs/gotchas.md#shared-primitives-are-the-design-system-and-are-not-private) (UX30, UX51)
- Don't anchor a `CALayer` mask on a scrolling view at `origin: .zero`. Take `clip.bounds` whole. → [gotchas](docs/gotchas.md#never-anchor-a-calayer-mask-at-origin-zero) (UX47)
- Don't frame-size a scroll view's document that hosts Auto Layout content. Constraint-host it: TAMIC false, width pinned to `scroll.contentView`. → [gotchas](docs/gotchas.md#never-frame-size-a-scroll-views-auto-layout-document) (UX34, UX47)
- Don't put a bare `Rectangle` (or any `Shape`) as a stack sibling when you want the stack sized to its content. Draw an underline as an `.overlay(alignment: .bottom)`. → [gotchas](docs/gotchas.md#shapes-are-greedy-in-both-axes) (UX36)
- Don't let a `SettingsRow`'s control column fight its label column for width, and don't set a window's minimum below the floor its SwiftUI root declares — use `contentMinSize`, not `minSize`. → [gotchas](docs/gotchas.md#settingsrow-column-widths-and-window-minimums) (UX43)
- Don't offer a picker option whose setter drops it. Either make it a real target or offer it only as a readout. → [gotchas](docs/gotchas.md#never-offer-a-picker-option-whose-setter-drops-it) (UX43, DIAR3)
- Don't put a detail pane's header on one of its tabs' content measures, and don't centre a measured column in an uncapped one. Cap the column, then left-align. A footer gets the width of the thing it serves. → [gotchas](docs/gotchas.md#the-detail-header-is-chrome-not-content-measure) (UX36, UX33)
- Don't cap a pane's content at the width its narrowest allowed window would dictate. Derive a ceiling from what the content wants to read at; let the frame handle the floor. → [gotchas](docs/gotchas.md#derive-a-content-ceiling-not-a-floor) (UX33)
- Don't front, activate, or count a Dock-participating window from its own `show()`. `WindowActivationManager` owns the open sequence and the way back; it counts by window identity, since `isVisible` is false while miniaturized. → [gotchas](docs/gotchas.md#window-activation-has-one-owner) (UX39, UX56, UX48)
- Don't fix a missing command-key shortcut with a hidden control in the view hierarchy. `MainMenu.swift` is the one place, every item on a nil target. → [gotchas](docs/gotchas.md#command-key-shortcuts-need-a-main-menu) (UX48)
- Don't assume the reading surfaces have a right-click Copy to fall back on. There is no `NSTextView` in this app outside editing sheets. A real mouse selection does engage a working Copy; what is unmeasured is reading that selection programmatically. → [gotchas](docs/gotchas.md#the-reading-surfaces-have-no-nstextview) (UX48, FEAT13)
- Don't reference another file's types from `Automation/MeetingPipeAppIntents.swift`. `install.sh` compiles it standalone; the breakage is silent (`swift build` still passes, the Shortcuts actions vanish). → [gotchas](docs/gotchas.md#app-intents-compile-standalone)
- Don't try to make the native App Intents run on an ad-hoc-signed build, and don't re-derive why they don't. Six causes were excluded by measurement; the remaining one is code signing. → [gotchas](docs/gotchas.md#app-intents-are-discoverable-but-not-invocable)

## Where things live (quick index)

Orientation only — one hop to the right file. [`../ARCHITECTURE.md`](../ARCHITECTURE.md)'s Daemon section carries what each one does and why, and [`docs/gotchas.md`](docs/gotchas.md) carries the traps.

| Subsystem | Entry file(s) |
|---|---|
| State machine + dispatch | `Coordinator.swift` (+ `Coordinator+*.swift`), `MeetingSessionController.swift`, `SessionHost.swift`, `Coordination/` (`DetectionStateMachine`, `SinkDispatcher`, `PipelineJobDispatcher`, `ConfigRefreshCoordinator`) |
| Meeting detection (start + end) | `MeetingPipeCore/Lifecycle/`, `MeetingDiscoveryWatcher.swift`, `MeetingSourceScanner.swift`, `MeetingSourceScorer.swift`, `MeetingAppRegistry.swift`, `MicBusySpanTracker.swift`, `MicInUseTier.swift`, `MicInputAvailability.swift`, `Resources/meeting_apps.toml` |
| Mute gating | `MeetingPipeCore/MicGate/`, `MicGateWriter`, `AXMuteButtonProbe`, `MeetingAXWindowWatcher`, `Adapters/LogMuteAdapter.swift`, `SlimCoreMuteLog.swift`, `MuteSourceFusion.swift` |
| Recording | `MeetingRecorder.swift`, `RecordingPostProcessor.swift`, `RecordingDurationParity.swift`, `SystemAudioCapture.swift`, `SystemCaptureRetryPlanner.swift`, `CaptureRecoveryPlanner.swift`, `SerialBufferWriter.swift`, `MuteRedactor.swift`, `AudioRetention.swift` |
| Transcription (ASR + diarization) | `Transcription/` (`FluidAudioRunner`, `TranscriptionRunner`, `SegmentBuilder`, `TranscriptionService`), `SpeakerAccuracy.swift`, `TranscriptOverlayCarry.swift` |
| Derived copy (engines, sinks, clamps) | `SummarizationEngine.swift` (UX31), `PublishLanding.swift` (UX49), `RegulatedMode.swift` (UX60), `DigestNarration.swift` (UX63), `SummaryStaleness.swift` (UX65) |
| Workflows | `Workflow.swift`, `WorkflowStore.swift`, `WorkflowMatcher.swift`, `WorkflowsView.swift`, `PublishTargets.swift`, `WorkflowContextHint.swift`, `WorkflowDeletion.swift`, `WorkflowRowActions.swift`, `WorkflowInspectorPresentation.swift`, `WorkflowInspector.swift`, `WorkflowRoutingHint.swift`, `WorkflowCorrectionStore.swift` |
| Library UI | `LibraryWindow.swift`, `LibraryListView.swift`, `MeetingDetailView.swift`, `MeetingStore.swift`, `LibraryProcessing.swift`, `ReSummarizeMenu.swift`, `LibraryDialogs.swift`, `BatchActionConfirmation.swift` |
| Library: search + smart folders | `SearchIndex.swift` (SQLite FTS5), `SearchIndexer.swift`, `SearchQuery.swift`, `SavedSearch.swift`, `SavedSearchStore.swift`, `SavedSearchViews.swift` |
| Library: Ask (AI3) | `AskModel.swift`, `AskPane.swift`, `AskContextWidth.swift`, `AskView.swift` |
| Library: Facts + evidence | `Facts.swift`, `FactsView.swift`, `SummaryRenderedView.swift` (`EvidenceChips`) |
| Quick Find (Cmd+K) | `QuickFindWindow.swift`, `QuickFindRanker.swift`, `QuickFindList.swift` |
| Speaker naming | `TranscriptTab.swift`, `MeetingCast.swift`, `SpeakerLabelStore.swift`, `Library/MeetingLibraryService.swift`, `VoiceResolution.swift`, `VoiceResolutionBar.swift` |
| People rail (DV3) | `PeopleRail.swift`, `PeopleView.swift`, `RosterProfile.swift`, `RosterRename.swift` |
| Meeting time rail (AI8) | `MeetingStats.swift`, `StatsView.swift` |
| Preferences | `PreferencesWindow.swift`, `Preferences/` (`PreferencesView.swift`, `PreferencesControls.swift`, `UISettings.swift`, `VocabularyEditor.swift`), `NotionDatabasePicker.swift`, `GlossaryStore.swift`, `RestoreFlow.swift` |
| Vocabulary + clarify | `VocabularyCandidate.swift` (FEAT12), `Clarify.swift` + `ClarifySheet.swift` (FEAT13) |
| Menu bar + onboarding | `StatusBarController.swift`, `StatusBarModel.swift`, `SetupChecklist.swift`, `Onboarding/`, `OnboardingGate` |
| Application menu bar | `MainMenu.swift` (UX48) — the App / Edit / Window bar, distinct from the menu-bar *extra* above |
| Window activation | `WindowActivationManager.swift` (UX39/UX56) — owns the policy flip, and installs/removes `MainMenu` with it |
| Permissions | `PermissionsCenter.swift` |
| Pipeline subprocess | `PipelineLauncher.swift`, `LocalServerReaper.swift`, `LocalModelPreloader.swift`, `LocalModelTier.swift` |
| Scheduled `mp` jobs | `LaunchAgentScheduler.swift`, `DigestSchedulerService.swift` (AI4), `BackupSchedulerService.swift` (STOR4) — a new job adds a thin service here, not a second plist writer |
| Launch at login | `LaunchAtLoginService.swift` (UX42) — the agent that installs the app, distinct from the one-shots above |
| One instance only | `SingleInstanceGuard.swift` (UX54) |
| Event log | `Logger.swift` (`Log.event` / `Log.writeLine` / `Log.main`, size-rotated) |
| Diagnostics viewer (UX20) | `DiagnosticsWindow.swift`, `DiagnosticsView.swift`, `DiagnosticsLog.swift`, `DoctorRunner` |
| User guide (DOC11) | `GuideWindow.swift`, `GuideView.swift`, `GuideDocument.swift` — text is `docs/GUIDE.md` and *only* that; never paste guide prose into Swift |
| Automation (`meetingpipe://` + App Intents) | `Automation/` (`AutomationCommand.swift`, `AutomationReference.swift`, `Coordinator+Automation.swift`, `TranscriptDeeplink.swift`, `MeetingPipeAppIntents.swift`), `AppDelegate.application(_:open:)` |
