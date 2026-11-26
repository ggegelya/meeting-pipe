---
id: AUTO11
title: A link's Stop confirm left open across one recording ending and the next starting stops the new recording when accepted, because the confirm carries no recording identity
category: Automation
status: new
priority: P2
comment: Filed 2026-11-26 (owner approved 2026-11-25/26, left over from AUTO7 8875e6b7): AutomationConfirmation.expectsRecording is a Bool, so a toggle decided as stop and a recording that ended and restarted both read "recording" at accept; the stop verb has no check at all, and forceStop also cancels a start in flight. Scope: carry the recording's file from AppState into the confirm and perform a stop only on that recording.
---

# AUTO11: A link's Stop confirm left open across one recording ending and the next starting stops the new recording when accepted, because the confirm carries no recording identity

Band origin: filed 2026-11-26 from the AUTO7 amendment session (commit `8875e6b7`), whose note in [`daemon/docs/gotchas.md`](../../../daemon/docs/gotchas.md) ("A confirm with no timeout has to re-check what it promised at accept") ends on this gap. Owner approved filing on 2026-11-25/26. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

**What AUTO7 closed.** A `meetingpipe://` link's `toggle`, `record`, `record_byo`, `stop` and `digest` ask first, through an `NSAlert` with no timeout (`AutomationRouter.confirmWithAlert`). The 2026-11-21 amendment (shipped 2026-11-26) made the panel carry the decision it names: `AutomationGate.confirmation` sets `AutomationConfirmation.expectsRecording` to `true` (Stop Recording) or `false` (Start Recording) for `toggle`, and `AutomationRouter.route` re-reads `isRecording()` at accept, performing nothing and logging `automation` / `command_stale` on a mismatch. The read is `AutomationGate.toggleStops(state, startInFlight:)`.

**What it still cannot see (read at HEAD `0f141418` on 2026-11-26).**

1. `toggle`. `expectsRecording` is a `Bool`. A link arrives during recording A; the panel says "A link asked MeetingPipe to stop the current recording." and waits. A ends (the call ends, or the owner stops it), and recording B starts (the next meeting, a prompt accepted). The owner clicks Stop Recording: `isRecording()` is `true`, equal to `expected`, so the router performs `session.toggleManual(surface: .automation)`, which stops B. The gotcha names this exact case.
2. `stop`. Its confirmation carries no `expectsRecording` at all ("Nil for verbs whose perform re-checks the state itself"), and `performAutomation` calls `session.forceStop(reason: "url_scheme")`, which stops whatever is current. The re-check is stop-only, not which-recording: the same sequence stops B, and a `stop` link accepted while idle with nothing in flight at arrival stops a recording that began after it. `forceStop` also cancels a start in flight (`startLatch.cancel(by: reason)`, END20), so the stale accept can kill B's bring-up.
3. `record` and `record_byo` are not affected: `startRecordingViaAutomation` starts only from idle, so a stale accept either starts (what the panel said) or does nothing.

**The identity is already in the state.** `AppState.recording(file: URL, source:, summaryMode:)` and `.stopping(file:, ...)` carry the recording's file, whose stem names the meeting; a start in flight (`session.startLatch.isInFlight`) has none yet.

**Reach.** Needs a link opened during one recording and its panel left unanswered until after the next has started. The panel is modal and in front (`NSApp.activate()` before `runModal`), so this is a narrow window, but the cost is a live recording cut short by a click the owner believes refers to the previous one, with nothing in the panel to tell them apart.

## Scope

1. Replace the `Bool` with what the stop promise refers to: at arrival, for `toggle` decided as stop and for `stop`, record the current recording's file from `AppState` (nil when the stop would cancel a start in flight or there is nothing to stop). The router's live read at accept returns the same shape. Seam: `AutomationConfirmation`, `AutomationGate.confirmation(for:source:isRecording:)`, `AutomationRouter.route`, and the read closure in `Coordinator+Automation.handleAutomation`.
2. At accept, a stop is performed only if the recording it named is still the current one (same file); a toggle decided as start keeps today's rule (perform only if a toggle would still start). Anything else performs nothing and logs `command_stale`, with `decided` as today and no stem or title in the row.
3. A stop decided over a start in flight (no file yet) is stale once that start has committed to a recording or failed; the pickup picks the simplest check that holds, for example the latch's own attempt identity if it has one, otherwise treat "a recording is now current" as stale.
4. Update the AUTO7 gotcha's last sentence and the CONVENTIONS `command_stale` row if `stop` now emits it, in the same commit.

## Explicitly not

- Naming the recording in the panel (its title or start time): useful, but the panel's text is written at arrival and the identity check is what prevents the wrong stop. A follow-up if the owner wants it.
- A timeout on the panel: AUTO7 chose no timeout so a slow click is not lost; the identity check makes a late click safe instead.
- `record` / `record_byo` and `digest`: not affected (see Context item 3).

## Acceptance

- `AutomationGateTests`: a `toggle` decided as stop on recording A, accepted after the state moved to recording B, performs nothing and logs `command_stale` with `decided: stop`; the same with A still current performs the toggle once.
- Same file: a `stop` decided on recording A and accepted on recording B performs nothing and logs `command_stale`; a `stop` decided while idle and accepted during a recording performs nothing; a `stop` decided and accepted on the same recording performs `forceStop` once.
- Same file: a stop decided over a start in flight, accepted after that start became a recording, follows the rule chosen in scope item 3, pinned by one test.
- The existing AUTO7 tests (`test_a_toggle_decided_as_start_does_nothing_if_a_recording_began_before_accept`, `test_a_toggle_decided_as_stop_does_nothing_if_the_recording_ended_before_accept`, `test_toggle_stops_matches_what_toggleManual_would_do`) stay green, adjusted only for the new read's shape.
- The new A-to-B tests red against the pre-fix code.
- `cd daemon && swift build` and `swift test` green, with the number of new tests in the commit body; `bash scripts/ci-local.sh` green (the events fence covers `command_stale` if `stop` now emits it).
