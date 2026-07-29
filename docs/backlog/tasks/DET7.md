# DET7: Record the suppressed meeting: attach off the live discovery candidate

Band origin: filed 2026-07-29 (owner exploratory sweep, item 7: "if the meeting got suppressed cause I didnt click record, after this I am not able to start the meeting recorder connected to a teams, only 'generic' one"). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md). P2; the owner hits this in live dogfood, so re-band to P1 on the next recurrence that costs a meeting's attribution.

## Context

After a prompt dismissal (Skip, the close button, force-stop while prompting, or timeout with the skip default), `abandonPrompt` arms the cooldown and the skip latch and returns the state machine to `.idle` (`DetectionStateMachine.swift:104-109`). The latch is refreshed by every discovery sighting (~3 s cadence) for the meeting's whole lifetime (`MeetingSessionController.swift:1058-1061`), lapsing ~15 s after the app stops being seen. That suppression design is correct and stays.

The gap is the way back in. `toggleManual` has a correct attach branch: for `.prompting` and `.suppressed` it dismisses the prompt, clears suppression, and begins recording with the source (`MeetingSessionController.swift:171-187`, comment included). But `.suppressed` is legacy: nothing in production ever sets it (`DetectionStateMachine.setSuppressed` is documented as legacy, :79-85), and after `abandonPrompt` the machine is `.idle`, so every manual start takes the `.idle` branch: `beginRecording(source: nil)`. The status-bar menu deliberately keeps offering "Start Recording" during suppression, with a comment saying a skipped meeting must keep a menu route to record (`StatusBarController.swift:509-515`), but the route it offers is the generic one. The strong hint is that this feature existed and was lost to a refactor, not never designed: the dead `.suppressed` branch is exactly the wanted behavior.

What a generic (`source: nil`) recording costs: workflow resolution falls to the default (`MeetingSessionController.swift:345-349`), the meta sidecar carries no source bundle, display name, kind, or meeting title (`MeetingMetaSidecar.swift:33-37`) so the Library row has no app chip, and there is no lifecycle end-detection anchor (`armLifecycleLeaveButton` early-returns on nil, `MeetingSessionController.swift:1111`), leaving the stop to the silence backstop, which in this dogfood has historically fired approximately never (real ends are AX-detected), so a forgotten generic recording can trail many minutes of silence.

The one attached re-entry that exists is narrow: the timeout-skip path posts a notification whose "Start recording" action rebuilds the source, clears suppression, and records attached (`Notifier.notifySkippedMeeting` fired only from the timeout branch, `MeetingSessionController.swift:728`; handler `didRequestStartLate` at `Coordinator+Delegates.swift:121-133`). An explicit Skip or close posts nothing, and the notification route dies with Notification Center.

Where the live candidate is available: `handleDiscovery` receives a fresh `AppSource` every ~3 s while latched and discards it (`MeetingSessionController.swift:1058-1061`). Caveat for the affordance's label: discovery-path sources carry no `meetingTitle` (`MeetingSourceScanner` constructs without it, :93-96, :126-129, :175); only the lifecycle `.starting` path resolves titles. So the affordance names the app ("Record this Teams meeting"), not the meeting, unless it calls `MeetingTitleResolver.resolve` itself.

Adjacent fact, folded here rather than filed separately: `meetingpipe://record` / `toggle` are unconditionally `source: nil` too (`Coordinator+Automation.swift:44-45`), so a Raycast/Stream Deck start mid-meeting is also unattributed. The same cached-candidate preference can serve both.

## Scope

- Cache the last latched sighting where it is currently discarded (`MeetingSessionController.swift:1058-1061`) as `lastSuppressedCandidate: (source: AppSource, seenAt: Date)`, exposed through `SessionHost` (per daemon/CLAUDE.md: session logic reaches the host, not the Coordinator), cleared when the latch lapses.
- Add an explicit `recordAttached(to:)` entry that runs the `didRequestStartLate` sequence: clear suppression for the bundle, dismiss any prompt remnant, `beginRecording(source:)`.
- Surface it in the status-bar menu's suppressed state: the existing "Start Recording" row, when a live latched candidate exists, becomes (or is joined by) "Record this <App> meeting", built through `StatusBarModel` so the row logic is table-tested; plain "Start Recording" stays for the truly-idle case.
- Prefer the cached candidate in `toggleManual`'s `.idle` branch and in the `meetingpipe://record`/`toggle` router when the latch is live, so the hotkey and automation paths attach too. Record the decision if the hotkey is deliberately left generic.
- Decide-and-record: whether `notifySkippedMeeting` should also fire on explicit Skip/close (the plumbing is end-to-end already); recommendation is yes with a quiet banner, since the explicit-skip regret case is exactly the one the owner reported.

## Explicitly not in scope

Reviving the `.suppressed` machine state (the latch + `.idle` design is deliberate; add the candidate cache beside it rather than re-litigating the state machine). Changing latch/cooldown semantics or durations. Prompt re-display (this is record-without-reprompting). Title resolution improvements (CAL3's territory; the affordance may call the existing resolver, nothing more).

## Acceptance

Tests against `FakeSessionHost` (`MeetingSessionControllerBranchTests` idiom): a latched discovery sighting populates the cached candidate and refreshes it; the cache clears when the latch lapses; `recordAttached(to:)` clears suppression and begins recording with the source (meta sidecar inputs carry bundle id and display name); `toggleManual` from `.idle` with a live cached candidate records attached, and without one records generic; the automation `record` verb with a live candidate attaches.

`StatusBarModel` tests pin the menu row: suppressed-with-candidate shows the named attach row, idle shows plain Start Recording.

`cd daemon && swift build` and `swift test` green (baseline at filing: 1770). Repo dash guard green.

Owner eyeball: let a Teams prompt time out (or skip it), open the menu bar: "Record this Microsoft Teams meeting" appears; click it; the HUD shows the workflow chip, the Library row carries the Teams chip, and the recording stops on its own when the call ends (AX end detection armed).
