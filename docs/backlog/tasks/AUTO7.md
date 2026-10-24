# AUTO7: any app or clicked link can start or stop a recording, run a digest, or auto-run an Ask through the unauthenticated `meetingpipe://` scheme

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) S6, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) PP-8). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

`AppDelegate.application(_:open:)` parses every URL with `AutomationCommand.parse` and calls `coordinator?.handleAutomation(command)` with the default `source: "url_scheme"`. `Coordinator.handleAutomation` (`Automation/Coordinator+Automation.swift`) then acts with no confirmation, re-read on 2026-10-24:

- `.toggle` calls `session.toggleManual()`: a link can stop a live recording.
- `.record(byo:)` calls `startRecordingViaAutomation`, which refuses only when not idle: a link can start one.
- `.stop` calls `session.forceStop(reason: "url_scheme")`.
- `.digest` opens the Digests rail and runs `libraryModel.generateDigest()` at once, which on the default cloud engine is an API call.
- `.ask(question:)` sets `libraryModel.pendingAskQuestion`; `AskView` hands it to `AskModel.acceptDeeplink`, which sets the field and calls `start(q, ...)`, so the question runs without a click (README's table says "prefilled and run it"). It too may be a cloud call.

A web page, a chat message, a calendar invite or any local app can open such a URL; macOS gives the receiver no caller identity for a URL open. `.openLibrary` and `.openMeeting` (AUTO2's transcript deeplinks from published notes) only show UI and are fine.

The App Intents in `Automation/MeetingPipeAppIntents.swift` all execute "by opening the matching `meetingpipe://` URL", and on this ad-hoc-signed build they cannot be invoked at all (that file's 2026-07-19/20 measurement; AUTO1, P3, gated on D8). A gate in the URL router therefore covers them too.

**The `--` claim, narrowed.** `PipelineLauncher.askArgs` builds `["ask", question, "--out", ...]` with no `--`. `mp ask`'s parser has `question` as `nargs="+"` plus `--dir`, `--index-dir`, `--model`, `--rebuild`, `--out`, `--json`. argparse treats a token as positional when it contains a space, so a normal question cannot be read as an option; a question that is exactly an option token (for example `--rebuild` or `--model=x`) is consumed as that option, the required positional is then missing, and `mp ask` exits 2 with a usage error. That is a confusing failure rather than an exploit, and `--` fixes it in one line.

## Scope

1. In `handleAutomation`, when `source == "url_scheme"`, the state-changing and cost-incurring verbs (`toggle`, `record`, `record_byo`, `stop`, `digest`) do not act directly: they present a small confirm panel naming the action and its origin ("A link asked MeetingPipe to stop the current recording"), with the action as the default button so a Stream Deck or Raycast user pays one click or one Return. In-app callers (`source: "quick_find"` and any other non-URL source) are unchanged.
2. `ask` from a URL prefills the Ask field and opens the rail but does not run; `AskModel.acceptDeeplink` gains a parameter (or a sibling) that sets the field without calling `start`. Quick Find's in-app handoff keeps auto-running.
3. `askArgs` becomes `["ask", "--out", out.path, "--context-tokens", String(contextTokens), "--", question]`.
4. Same commit: README's URL table (the `ask` and `digest` rows, and a note on the confirm), GUIDE.md's automation sentence, and `AutomationReference` (Preferences ▸ Advanced ▸ Automation), whose rows are pinned by `AutomationReferenceTests` to every `AutomationCommand` case.

A "trust automation without confirm" preference was considered and is not in scope: it is one more knob, and the owner can ask for it after living with the one-click confirm.

## Explicitly not

- Authenticating callers (signed URLs, a shared secret in the query). macOS gives a URL handler nothing to check against, and a secret in a Shortcut is readable by the same apps the gate is about.
- App Intents' own `perform()` paths and the Developer ID they need: AUTO1, D8.
- The MCP surface: AUTO6.
- `url_unrecognized` logging the full URL (it can carry a question): noted, not filed.

## Acceptance

- A new automation-router test file with a fake confirm presenter (no test drives `handleAutomation` today: `AutomationCommandTests` covers parsing, and `MeetingSessionControllerBranchTests` covers `startManual` below the router): each of `toggle`, `record`, `record_byo`, `stop`, `digest` from `source: "url_scheme"` presents the confirm and performs nothing until it is accepted; declining performs nothing and logs `automation` / `command_declined`; the same verbs with an in-app source act at once; `open` and `library` never present it.
- An `AskModelTests` case that a URL-sourced deeplink sets `question` and leaves `inFlight` nil, and that Quick Find's source still starts the run.
- A `PipelineLauncherTests` case for `askArgs` that `--` precedes the question and that a question of `--rebuild` is the last argv element.
- `MeetingPipeAppIntentsTests` and `AutomationReferenceTests` stay green (updated rows only).
- `cd daemon && swift build` and `swift test` green, new test count in the commit body; `python3 scripts/truth_fences.py` clean for the new action.
- Owner check (confirms): `open meetingpipe://stop` during a recording shows the confirm and the recording continues until it is accepted.
