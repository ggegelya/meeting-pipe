# DET9: the skipped-meeting latch lapses mid-call, so a dismissed prompt re-opens over the live meeting

Filed 2026-08-03 by the audit band. Proposed high, sent to an independent skeptic, held at high with one narrowing recorded below.

## What is wrong

`SkippedMeetingLatch` is refreshed only on a discovery scan that produced a confident winner, and its grace is a hardcoded 15 s whose documented justification no longer holds. `DetectionStateMachine.swift:40-45` reads `5x the MeetingDiscoveryWatcher 3 s poll, so a few missed scans mid-call do not drop the latch` above `static let skipLatchGraceSec: Double = 15`, but `MeetingDiscoveryWatcher.swift:55` is `private var cadence = DiscoveryScanCadence(active: 3, idle: 12)`. PERF6 moved the quiet poll to 12 s, so the grace is **1.25 poll intervals, not 5**, and a single missed or slow scan lapses the latch mid-call.

Once lapsed it cannot be re-armed inside the cooldown window. `MeetingSessionController.swift:1108-1109` is the only `refreshSkipLatch` call site in the daemon, reached only when `onDiscovered` produced a confident winner, and the cooldown branch at `MeetingSessionController.swift:1119-1124` returns without refreshing. So a returning winner inside the 60 s reprompt cooldown does not re-arm it, and when the cooldown expires the prompt re-opens over the still-live call.

`MeetingSessionController.swift:1103-1105` repeats the stale premise in an inline comment, and `ARCHITECTURE.md:582`'s glossary entry asserts the latch "lapses ~15 s after discovery stops seeing the meeting (i.e. shortly after it ends)", equating "discovery stopped seeing it" with "it ended". The log disproves that equivalence.

## Observed, not theorized

From the owner's own `events.jsonl`:

- 2026-07-02: three explicit skips of one Teams call inside 3.5 minutes, with gaps of 68.0 s and 121.8 s.
- 2026-07-27: `prompt_timeout {bundle_id: com.microsoft.teams2, default_action: skip}` at 13:49:17.191Z, then `candidate_dropped {bundle_id: com.microsoft.teams2, leave_button: False, mute_button: False, calling_controls_toolbar: False, reason: no_confident_winner}` at 13:49:53.476Z, then a re-prompt at 60.5 s.

The AX control walk returning no Leave, Mute or toolbar mid-call is the normal way this happens: Teams switches its call UI to a compact or background state and one scan finds nothing.

## The skeptic's narrowing, recorded

This is not an unbounded loop. Every re-skip calls `abandonPrompt`, which re-arms the latch, so each further re-prompt requires another missed scan. The observed shape is a handful of re-prompts across a call rather than one every 60 s for its whole duration.

A second consequence is worth naming: the menu bar's `Suppressed (<app>)` label reads `isSkipLatched`, so it collapses back to `Start Recording` at the same moment, destroying DET7's attach affordance while the meeting is still running.

## Scope

Decouple the latch's liveness oracle from "a scan produced a confident winner". Any of three shapes works and the pickup should pick one deliberately:

- Refresh the latch on any scan where the skipped bundle is still a running candidate, including a sighting that ends in `candidate_dropped`.
- Refresh it in the cooldown branch too.
- Derive the grace from the live `DiscoveryScanCadence.idle` rather than a constant that assumes a 3 s poll.

Fix the three stale comments (`DetectionStateMachine.swift:40-45`, `MeetingSessionController.swift:1103-1105`) and the `ARCHITECTURE.md:582` glossary entry in the same commit.

## Acceptance

Suite green with new tests. A `DetectionStateMachine` test drives the latch at the **idle** cadence rather than only at t and t+grace+1, and fails against today's constant. A skipped meeting stays latched across a scan that produces no confident winner. The menu bar keeps showing `Suppressed (<app>)` across that same gap.

## Owner walkthrough

Steps tagged [owner] / [session] by who acts.

1. [session] `./scripts/rebuild.sh`, then tell the owner it is ready.
2. [owner] On the next Teams call you do not want recorded, dismiss the Record prompt and then switch to another app and work normally for the length of the call. Pass: the prompt does not come back, and the menu bar keeps saying `Suppressed (Microsoft Teams)` for the whole call rather than reverting to `Start Recording`.
3. [owner] After that call ends, glance at the menu bar within a minute. Pass: it has returned to `Start Recording`, so the latch still lapses when the meeting genuinely ends rather than sticking forever.
4. [owner] Say "DET9 good to close" or what is wrong.
