# ARCH16: The detection prompt and the recording HUD are 2,435 lines of hand-laid AppKit beside a SwiftUI app, so their look, accessibility and focus are built a second time

Band origin: filed 2026-10-24 (go-live assessment SA-13; the 2026-10-24 audit band mapped SA-13 to [UX27](./UX27.md), which owns only keyboard operability and sits at P4 by the owner's 2026-07-22 decision). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## What is wrong

The two surfaces a user sees in every meeting are the only windows not built in SwiftUI. On 2026-10-24 `MeetingPromptWindow.swift` is 1,378 lines and `RecordingHUDWindow.swift` 1,057. Each creates an `NSPanel` with `styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView]` and lays its content out by hand: 42 and 41 `NSTextField`, `NSButton`, `NSStackView`, `addSubview` and constraint constructions, and no `NSHostingView`.

Everything else hosts SwiftUI in an AppKit shell: Library, Preferences, Guide, Diagnostics, Onboarding, Correction, the FailureNotice details window (`NSHostingController(rootView: FailureDetailsView(...))`), and QuickFind, which is itself a panel (`NSPanel(contentViewController: host)`).

So `daemon/Sources/MeetingPipe/Design/` carries two primitive sets. AppKit: `MPButton: NSButton`, `RecordKey: NSControl`, `WorkflowChipView: NSButton`, `LEDMeterView`, `LiveWaveformView` and `DismissProgressView`, with no consumer outside the two panels, plus `AppGlyphView`, which the Library row also reaches through an `NSViewRepresentable` in `MeetingRow` and so stays. SwiftUI: `MPGhostButtonStyle`, `MPSurface`, `MechanicalToggleStyle`, `MPControlAccent`. A change to a shared look lands twice, and accessibility labels and focus behaviour are implemented once per stack. UX27's attempt at Tab and Space on the panels, built in AppKit, was reverted on 2026-07-22.

Correction to the go-live finding, recorded so it is not repeated: it said the tutorial's anchors cover both stacks. They do not. `TutorialWindow` has two cases, `library` and `preferences`, so FEAT15's tour cannot point at either panel. Noted here as an adjacency, not scoped.

## Scope

Keep each `NSPanel` shell exactly as it is (borderless, nonactivating, positioning, show and hide, the passive appearance) and replace only its content view with an `NSHostingView` of a SwiftUI view built from the SwiftUI primitives.

1. **Proof first, on the HUD** (the smaller panel). Host its content and show, before porting anything else: showing the panel still does not activate the app or change the key window, clicks on its controls stay nonactivating as they are today, hit testing works on the borderless panel, and it looks the same (the owner's eyeball, since the menu-bar app is not screenshotable from a session). If any of the first three fails, stop and report rather than working around it in AppKit.
2. Port the HUD, then the prompt, one commit each, at visual parity.
3. Delete each AppKit primitive in `Design/` once it has no consumer left.

P3 by the refactor rule (the ARCH5 precedent: promote on touch). Promotion trigger: the next non-trivial design change to either panel, or UX27 being promoted, since a hosted panel gives the SwiftUI focus model (`.focusable`, `.onKeyPress`) that UX27 would try next.

## Explicitly not

- Keyboard operability and focus rings: [UX27](./UX27.md) (P4, owner decision 2026-07-22). This task must not make either panel take key focus or activate the app; its passive appearance is the point.
- Any change to how the panels look or behave. This is a parity port.
- Replacing the panel shell with a SwiftUI `Window` or `MenuBarExtra` scene. A nonactivating floating panel needs `NSPanel`.
- Tutorial anchors for the two panels (the correction above).

## Acceptance

- Proof leg: a test, or where headless AppKit cannot show it the owner's check recorded in the commit body, that showing the hosted HUD leaves `NSApp.isActive` and `NSApp.keyWindow` unchanged.
- `RecordingHUDTests` and the prompt's existing tests green, retargeted only where they assert AppKit view structure. Source-text fences that name AppKit types are retargeted, not deleted.
- No reference left to a deleted `Design/` primitive, and `bash scripts/ci-local.sh design-tokens` green.
- `bash scripts/ci-local.sh` green, with the number of new tests in each commit body.
- A `simple` row in `owner-verification.md`, with the owner's approval: prompt and HUD look and behave as before, in a real meeting.
