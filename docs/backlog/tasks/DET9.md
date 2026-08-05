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

## Measured at pickup 2026-08-05, and it corrects the filing above

Three readings from the owner's `events.jsonl`, recorded because two of them change which fix works. Do not re-derive them from the filing's summary.

**1. The 60.5 s re-prompt is the cooldown expiring, not a fresh detection.** The full 2026-07-27 sequence is `prompt_timeout` 13:49:17.191Z, `candidate_dropped` (title-only) 13:49:53.476Z, then **`discovery_shadow_pick` at 13:50:05.396Z with the complete live-call signature** (`calling_controls_toolbar`, `leave_button`, `mute_button`, `title_match` all true, score 11), then `prompt_shown` 13:50:17.663Z. So a confident winner returned at **48.2 s**, hit an already-lapsed latch, fell through to the cooldown branch and was discarded; the prompt then fired the moment the 60 s cooldown expired. The gap the latch actually has to bridge is 48 s, which is what sized the new grace, with END9's independently measured 21-33 s control blackout as the second point.

**2. Scope's first shape is refuted: a title-only sighting is not liveness.** Of 294 `candidate_dropped` events for `com.microsoft.teams2` in the log, **293 are title-only** (`leave_button`, `mute_button`, `calling_controls_toolbar` all false; the single exception carried a mute button), and they fire around the clock, including 07:22, 22:54 and 23:54 with no meeting anywhere near. Refreshing the latch on those would hold it permanently for Teams and silently swallow every later meeting in that app, which is a worse P1 than this one. The scan genuinely cannot tell a live call from an idle Teams window during a control blackout, so the gap is absorbed by the grace instead.

**3. The mic is not available as a blackout-immune oracle.** `mic_busy_started` / `mic_busy_ended` have fired **zero** times in the current log generation, so DET3's span tracker produces nothing on this Mac and `onMicBusyBundle` cannot corroborate liveness. Do not build on it without re-measuring first.

## The skeptic's narrowing, recorded

This is not an unbounded loop. Every re-skip calls `abandonPrompt`, which re-arms the latch, so each further re-prompt requires another missed scan. The observed shape is a handful of re-prompts across a call rather than one every 60 s for its whole duration.

A second consequence is worth naming: the menu bar's `Suppressed (<app>)` label reads `isSkipLatched`, so it collapses back to `Start Recording` at the same moment, destroying DET7's attach affordance while the meeting is still running.

## Scope

Decouple the latch's liveness oracle from "a scan produced a confident winner". Any of three shapes works and the pickup should pick one deliberately:

- Refresh the latch on any scan where the skipped bundle is still a running candidate, including a sighting that ends in `candidate_dropped`.
- Refresh it in the cooldown branch too.
- Derive the grace from the live `DiscoveryScanCadence.idle` rather than a constant that assumes a 3 s poll.

Fix the three stale comments (`DetectionStateMachine.swift:40-45`, `MeetingSessionController.swift:1103-1105`) and the `ARCHITECTURE.md:582` glossary entry in the same commit.

**Shipped 2026-08-05: the third shape only, deliberately.** The measurements above rule the first out (harmful) and the second out (unreachable at the shipped default: latch lapse is `lastSeen + grace` and cooldown expiry is `skip + cooldown` with `lastSeen >= skip`, so at any grace >= the cooldown the cooldown branch cannot be reached by a skipped bundle). `DiscoveryScanCadence.discoveryDefault` now names the watcher's real intervals, and `DetectionStateMachine.skipLatchGraceSec` is `skipLatchGracePolls` (5) times that idle poll, so the comment's original "5x the poll" intent holds by construction and cannot decay again the way it did when PERF6 moved the poll from 3 s to 12 s.

## Acceptance

Suite green with new tests. A `DetectionStateMachine` test drives the latch at the **idle** cadence rather than only at t and t+grace+1, and fails against today's constant. A skipped meeting stays latched across a scan that produces no confident winner. The menu bar keeps showing `Suppressed (<app>)` across that same gap.

## Owner walkthrough

Steps tagged [owner] / [session] by who acts.

1. [session] `./scripts/rebuild.sh`, then tell the owner it is ready.
2. [owner] On the next Teams call you do not want recorded, dismiss the Record prompt and then switch to another app and work normally for the length of the call. Pass: the prompt does not come back, and the menu bar keeps saying `Suppressed (Microsoft Teams)` for the whole call rather than reverting to `Start Recording`.
3. [owner] After that call ends, glance at the menu bar within a minute. Pass: it has returned to `Start Recording`, so the latch still lapses when the meeting genuinely ends rather than sticking forever.
4. [owner] Say "DET9 good to close" or what is wrong.
