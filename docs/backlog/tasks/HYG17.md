# HYG17: Swift small duplication and dead code: eight scheduler typealiases, re-declared NSLock.withLock, dead symbols, dialog boilerplate, bare sample rates and release-compiled test seams

Band origin: filed 2026-10-25 from the 2026-10-25 code-quality audit band ([code-quality audit](../../audits/2026-10-25-code-quality-audit.md) SW4, SW8, SW9, SW10, SW11, CV7, TS8). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Re-checked at filing on 2026-10-25: the eight `Scheduler` typealiases are seven in Core plus one in the executable, and the default timer bodies are not five identical copies but three identical repeating `Timer` bodies, two one-shot `Timer` bodies and three `DispatchSource` ones, so one alias already spells two semantics; eight dead symbols survive a re-grep (two of the audit's candidates belong to STOR6 and the token mirror); sample-rate literals are nine sites, not ten; the inline `runMP` timeouts are dropped from scope below.

1. **Dead symbols**, each referenced only by its own declaration across `daemon/`, `design/`, `scripts/`, `docs/` and the root `.md` files (an archive row in `q5-final.md` is history, not a caller): `MPButton.bindAsDefault()`; `RecordKeyView` (the SwiftUI host "for the Library toolbar (DSN27)", with its `Coordinator`); `SpeakerLabelStore.removeSegment(_:stem:in:)` (the batch `removeSegments` is live); `Endpoints.appIconResource`; `Endpoints.launchAgentLabel`, whose comment calls it the "single source of truth for install.sh and `mp doctor`" while neither reads it; `MeetingSessionController.currentActiveWorkflow`; `WorkflowDeletion.Outcome.didDelete`; `SummaryTab.summaryMarkdownURL`; and `extension Color { init?(hex:) }` in `MeetingRow.swift`, a fourth hex parser beside `HexColor.parse`.
2. **`NSLock.withLock` re-declared three times** as `private extension NSLock` in `MicGate.swift`, `MeetingLifecycleCoordinator.swift` and `ShareableContentSignal.swift`, shadowing Foundation's `NSLocking.withLock(_:)` (macOS 13, below the macOS 14 floor).
3. **`swiftUIColor(forHex:)` three times**, byte-identical (`if let ns = HexColor.parse(hex) { return Color(ns) }; return Color.secondary`) as file-private functions in `LibrarySidebar`, `LibraryToolbar` and `WorkflowInspector`.
4. **`typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void`** in `AXMuteButtonProbe`, `LogMuteAdapter`, `MeetingLifecycleCoordinator`, `CallTeardownWatcher`, `AXLeaveButtonSignal`, `ShareableContentSignal`, `ProcessAudioSignal` (Core) and `MeetingAXWindowWatcher` (executable). The `defaultScheduler` bodies: `Timer.scheduledTimer(..., repeats: true)` in `AXMuteButtonProbe`, `MeetingLifecycleCoordinator` and `ProcessAudioSignal`; `repeats: false` in `LogMuteAdapter` and `MeetingAXWindowWatcher`; a repeating `DispatchSource` timer in `ShareableContentSignal` and `AXLeaveButtonSignal.queueScheduler` and a one-shot one in `CallTeardownWatcher`. The same function type means "repeat" in five types and "fire once" in three.
5. **Bare sample rates**: `16000` four times in `RecordingPostProcessor` (two `aresample=16000` filter chains, two `"-ar", "16000"`), once in `MuteRedactor`, and `16_000` twice in `FluidAudioRunner`; `48000` twice in `SystemAudioCapture`, in `captureFormat` and in `config.sampleRate`, which must agree.
6. **Dialog boilerplate.** 13 `NSAlert()` constructions in 6 files. Five are the same two-button confirm (`confirmSoftDelete`, `confirmWorkflowDelete`, `confirmNDATransition`, `confirmRetranscribe`, the roster `beginRemove`), each ending `runModal() == .alertFirstButtonReturn`. Two, `CorrectionWindow.presentLoadError` and `presentSaveError`, are hand-built error alerts against CONVENTIONS' "UI failures use `FailurePresentation` and `FailureNotice`/`FailureDialog`". Five of the six `NSOpenPanel()` sites are the same folder picker (`canChooseFiles = false`, `canChooseDirectories = true`, `canCreateDirectories = true`, single selection) in `LibraryDialogs`, `PreferencesView+Recording`, `PreferencesView+Storage` (two) and `PreferencesView+Integrations`.
7. **A provenance clump.** `CorrectionStore.write` takes eleven parameters, five of which (`stem`, `transcriptPath`, `summaryJsonPath`, `modelId`, `backend`) travel together from all three production callers (`CorrectionWindow`, `SummaryTab.persistEdit`, `Coordinator+Delegates`).
8. **Test seams compiled into release**: `MicLevelMonitor.isMeteringLive` and `markMeteringLiveForTest` (their comment says "no app code calls either"), `PermissionsCenter.simulateStatusForTesting`, and `TranscriptionService.testingOverride` with `overrideRunnerForTesting`, which production `makeRunner` reads on every call.

## Scope

One commit per item, in this order, each green on its own: 1, 2 (deletions), then 3 to 8.

1. Delete the nine, and the `RecordKey` header comment's "`RecordKeyView` wraps it for SwiftUI".
2. Delete the three extensions; call sites use Foundation's `withLock` unchanged.
3. One internal `HexColor.swiftUIColor(_:)` beside `HexColor.parse` in `Design/WorkflowChipView.swift`; the three callers use it.
4. One `public typealias Scheduler` in `MeetingPipeCore/Infra/`, plus two helpers there, `Schedulers.mainRunLoopRepeating` and `Schedulers.mainRunLoopOnce`, replacing the five `Timer` bodies byte for byte. The `DispatchSource` defaults stay where they are (their queues are per-type). Each type's nested alias goes; parameters keep their labels, so call sites compile. The doc on the two helpers carries the `daemon/CLAUDE.md` rule that a `Timer` only repeats on a run-loop thread. No timing changes.
5. `RecordingPostProcessor.pipelineSampleRate = 16_000`, read by the filter chains, `MuteRedactor` and `FluidAudioRunner`; `SystemAudioCapture.config.sampleRate` reads `captureFormat.sampleRate`.
6. `LibraryDialogs.confirm(title:message:confirmButton:destructive:) -> Bool` for the five confirms, copy unchanged; the two `CorrectionWindow` alerts become `FailureDialog.show(FailurePresentation(error:title:))`; `LibraryDialogs.chooseFolder(prompt:message:startingAt:) -> URL?` for the five pickers. The three-button chooser, the four-button correction prompt, the rename text field, `reportRetranscribe` and `reportNothingToCopy` stay hand-built.
7. `CorrectionStore.Provenance` (the five fields), with `write(provenance:verdict:originalSummary:correctedSummary:notes:timestamp:directoryOverride:)`; the run-sidecar caller builds it from `run.json` as today.
8. Wrap each seam, and `makeRunner`'s `if let override` read, in `#if DEBUG`, matching `MicGate`'s precedent.

## Explicitly not / out of scope

- `Endpoints.Paths.recordingsRelative`, also dead: [STOR6](./STOR6.md) deletes it with the default-path change.
- `NSFont.mpTitle()` and the unreferenced colour and type tokens in `Tokens.swift` (`ink200`, `danger100`, `mpText3XL` and the rest): they mirror `design/colors_and_type.css`, where the names are the contract.
- The 16 inline `timeout:` literals across `PipelineLauncher`'s `runMP` calls: each sits beside the doc comment that justifies it for that command, and a constants table would split the number from its reason. CONC7 (filed the same day) owns `runMP`'s split.
- The test-side copies (`ManualScheduler` seven times, `FakeDriver`): T13, filed the same day, which can build its one `ManualScheduler` on item 4's alias.
- `NSError(domain:)`: [HYG15](./HYG15.md). The release build that proves item 8 compiles in release: [CI9](./CI9.md); until it lands, run `swift build -c release` locally.
- Python duplication: HYG16, filed the same day.

## Acceptance

- Per item, `swift build` and `swift test` green at that commit; tests change only at call sites (items 4, 7).
- Item 1: a re-grep in the commit body shows zero references to each deleted name.
- Item 3: a `HexColor` test that a malformed hex yields `Color.secondary` and `#FF6B6B` round-trips through `hexString(from:)`.
- Item 4: Core tests that `mainRunLoopOnce` fires once and `mainRunLoopRepeating` fires at least twice on the main run loop, and both cancel when the returned closure runs.
- Item 6: no `NSOpenPanel()` left outside `LibraryDialogs` for a folder choice, and no `NSAlert` in `CorrectionWindow` for an error.
- Item 8: `swift build -c release` succeeds, and `grep` shows each seam inside `#if DEBUG`.
- `bash scripts/ci-local.sh daemon` green at the end; new test count in each commit body.
