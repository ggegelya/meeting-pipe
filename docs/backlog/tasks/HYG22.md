---
id: HYG22
title: Two UI lifetime antipatterns the rest of the app already removed: the onboarding window is closed without isReleasedWhenClosed = false, and the summary editor binds list rows by array index
category: Hygiene
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). OnboardingWindowController builds an NSWindow(contentViewController:) and calls close() with the flag at its default true, the over-release shape every other closing window controller fixed (F077); CorrectionEditorBody's four string lists bind rows by position, the stale-binding shape WorkflowEditor and the vocabulary editor replaced (G017); no crash reproduced for either. Set the flag behind a testable window factory, give the string lists id-keyed rows, and fence both shapes. [Spec](./HYG22.md)
---

# HYG22: Two UI lifetime antipatterns the rest of the app already removed: the onboarding window is closed without isReleasedWhenClosed = false, and the summary editor binds list rows by array index

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md), low findings table: F077 ("Onboarding window is closed without isReleasedWhenClosed = false", partially confirmed, reported medium) and G017 ("Summary editor's list rows bind by array position", partially confirmed, reported medium). Both re-verified at HEAD (`3a2da4fc`) on 2026-11-13. Neither has a reproduced crash; both are shapes the codebase already removed elsewhere, so a regression here is a lifetime bug no test would catch.

**1. The onboarding window (F077).** [`OnboardingWindow.swift`](../../../daemon/Sources/MeetingPipe/Onboarding/OnboardingWindow.swift)'s `OnboardingWindowController` is a plain `final class`, not an `NSWindowController`. `show()` builds `let w = NSWindow(contentViewController: host)` and never touches `isReleasedWhenClosed`, which defaults to true for an `NSWindow`. `close()` is `window?.close(); window = nil`, so AppKit's release-on-close lands on top of ARC's release when the property is cleared. The window's style is `[.titled, .fullSizeContentView]` with no close box, so `close()` is reached only from `OnboardingRootView`'s completion closure (Skip setup, or the last step), which runs `OnboardingGate.markCompleted()`, `deps.onFinish()` and `self?.close()` from inside a SwiftUI button action hosted by that same window. `Coordinator.presentOnboardingIfNeeded()` guards on `OnboardingGate.isCompleted`, so this runs at most once per process, at the end of first run.

**Correction at filing: "every other window controller sets the flag" is too broad.** The five that build an `NSWindow(contentViewController:)` and close it set `isReleasedWhenClosed = false`: `LibraryWindow`, `PreferencesWindow`, `DiagnosticsWindow`, `GuideWindow`, `CorrectionWindow`. `QuickFindWindow`, `MeetingPromptWindow` and `RecordingHUDWindow` use `NSPanel`, whose default is already false. `FailureDialog.detailsWindow(for:)` in `FailureNotice.swift` uses `init(contentRect:...)` and orders out instead of closing, for exactly this reason (its doc comment: "a window built with this initializer is released on close, an extra release ARC does not expect"); [PERF27](./PERF27.md) shipped that. Onboarding is the one left.

**2. The summary editor (G017).** [`CorrectionEditor.swift`](../../../daemon/Sources/MeetingPipe/CorrectionEditor.swift)'s `CorrectionEditorBody.listSection(title:items:placeholder:)` renders Summary, Decisions, Open questions and Attendees with `ForEach(items.wrappedValue.indices, id: \.self) { i in ... TextField(placeholder, text: items[i], ...) ... items.wrappedValue.remove(at: i) }`. Row identity is the index, so deleting a middle row shifts every later row's identity and focus onto its neighbour, and a positional `items[i]` binding read after the array shrank traps. The same file's action items already use `ForEach($model.actions)` over `EditableAction: Identifiable`, `WorkflowEditor.ruleBinding(_:_:)` in `WorkflowsView.swift` documents the fix ("Id-keyed binding into `matchingRules`, so a row never holds a positional binding that goes stale when a different row is removed (TECH-WF crash fix)"), and `VocabularySection.binding(_:_:)` in `Preferences/VocabularyEditor.swift` copies it. The lists are `CorrectionViewModel`'s `@Published var summary`, `decisions`, `questions`, `attendees: [String]`; `makeCorrectedSummary()` trims them and FEAT10's `remappedEvidence(original:summary:decisions:questions:)` re-aligns evidence from the trimmed strings, so a wrapper type in the model does not change what evidence sees. `CorrectionEditorBody` is hosted by both `CorrectionWindow` and `SummaryTab`'s inline editor. No crash is traced for this plain `VStack`.

## Scope

1. **Onboarding.** Lift the window construction out of `OnboardingWindowController.show()` into a static factory returning the built `NSWindow` (the `FailureDialog.detailsWindow(for:)` shape), and set `isReleasedWhenClosed = false` in it. `show()` and `close()` keep their behaviour otherwise.
2. **Editor rows.** Add a small `EditableLine: Identifiable, Equatable` (`let id = UUID()`, `var text: String`) beside `EditableAction` in `CorrectionWindow.swift`. `CorrectionViewModel`'s four string lists become `[EditableLine]`, built in `init` and mapped back to `[String]` before `trimmed` in `makeCorrectedSummary()`. `listSection` iterates `ForEach(items.wrappedValue)` and binds each row through an id-keyed helper modelled on `WorkflowEditor.ruleBinding`, and deletes with `removeAll { $0.id == id }`.
3. **One fence for each shape** in an existing fence-style test file or a new `UILifetimeFenceTests.swift`: every file under `daemon/Sources` that constructs an `NSWindow(` also sets `isReleasedWhenClosed = false`, with `FailureNotice.swift` the one allowlisted file (it orders out, PERF27); and no `ForEach(... .indices, id: \.self)` paired with a positional binding in `CorrectionEditor.swift`.

## Explicitly not

- The first-run flow's content and step wiring: [UX84](./UX84.md).
- The two `ForEach(options.indices, id: \.self)` loops in `Preferences/PreferencesControls.swift`: they render fixed option lists that no row edits or deletes, so the stale-binding hazard does not apply. The fence covers the editor only.
- Dialog boilerplate and window-construction duplication across controllers: [HYG17](./HYG17.md).

## Acceptance

- New test: the onboarding factory's window has `isReleasedWhenClosed == false`; and, on `FailureLayoutTests.test_details_window_is_released_once_closed_and_dropped`'s pattern (`autoreleasepool`, a weak reference, `spin`), a factory-built window that is closed and dropped is released exactly once: the weak reference goes nil and the test does not crash. The test never calls `show()`, which activates the app and needs the full dependency set.
- New `CorrectionViewModel` test: three summary rows, an id-keyed binding taken for the third, the second removed by id; writing through the binding changes the third row's text and leaves the first untouched; `makeCorrectedSummary().summary` is the two remaining strings in order.
- `EvidenceTests` updated for the new element type and still asserting the same evidence remap.
- The fence fails on a planted `NSWindow(contentViewController:)` without the flag in a scratch Source file, and on a restored `.indices, id: \.self` loop in `CorrectionEditor.swift` (both tried and reverted, said in the commit body).
- `cd daemon && swift test` green, about 4 new tests; `bash scripts/ci-local.sh daemon` green.

## Owner walkthrough

1. [owner] Open a meeting's summary editor, add three Summary lines, put the cursor in the third, delete the second with its minus button, and keep typing: the text lands in the row that was third, and nothing crashes.
2. [owner] Optional, after resetting the `mp.onboarding.completed` default (`OnboardingGate.reset()`): relaunch, finish first run with Skip setup; the window closes and the app keeps running.
