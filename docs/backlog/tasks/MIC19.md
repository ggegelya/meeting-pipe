---
id: MIC19
title: The blind clear drops a latched mute that is still true about 19 times in 20 and is not gated on capture mode, so under the regulated gate an aside spoken while muted is written to disk, and Zoom's mute is unreadable for about 90 percent of a call
category: Recording
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). 108 mute_state_cleared_blind rows in 36 recordings, 82 of a muted state, re-read muted in 75; on Zoom the latch was off for 88 to 91 percent of each call; engageMicGate's onMuteCleared calls clearAxMute with no capturesLosslessly gate while its two sibling discredits have one. Owner decides the ADR 0016 trade (or MIC18 makes it moot), then one pure Core discredit policy of (capture mode, evidence), a Zoom AX dump before trusting Zoom reads, and a watcher-to-MicGate test per capture mode; promote before enabling regulated or NDA.
---

# MIC19: the blind clear drops a latched mute that is still true about 19 times in 20 and is not gated on capture mode

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

**Sources.** [Independent audit](../../audits/2026-11-12-independent-audit.md) F003 and G007 (and F035, folded in below); [recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md) and its [evidence](../../audits/2026-11-13-recording-reliability-evidence.md) D107 and D059; [field evidence](../../audits/2026-11-13-field-evidence.md) "Blind clear drops a latched mute that is still true about 19 times in 20" and "F003 and G007 path is routine: 108 blind clears of the mute state".

**The code, re-verified at HEAD on 2026-11-13.** `MeetingSessionController.engageMicGate` builds a `MeetingAXWindowWatcher` with three discredit closures. Two are mode-gated: `onStaleMuteContradiction` clears only when `self.activeCaptureMode?.capturesLosslessly ?? false`, and `blindOnWindowDisagreement` returns the same expression. The third is not: `onMuteCleared: { [weak self] in self?.coordinator.micGate.clearAxMute() }`. In the watcher's poll, a nil `fuse(...)` increments `consecutiveBlindPolls`, and at `blindClearThreshold` (default 3, one poll a second) it emits `mute_state_cleared_blind`, sets `lastEmitted = nil` and calls `onMuteCleared()`. `MicGate.clearAxMute` routes through `applyMuteReading(nil, source: .ax)`, which `MuteSourceFusion.accepts` refuses only while a SlimCore log reading is younger than `defaultLogFreshness` (5.0 s), so for Teams a log-sourced mute older than 5 s is dropped, and Zoom, Slack and Webex have no log guard at all. With `axMute` nil, `MicGate.decide` falls through to HAL VAD and RMS, so under `.regulatedGate` an aside spoken while muted reaches the mic file until the next confident poll re-latches `.muted`.

**Why it is shaped this way.** The ungated clear is the TECH-MIC6 rescue (done, archived in [q4-final.md](../q4-final.md)): it fired 0 times in 19 days while it was coupled to the watcher's own state, and the 2026-06-08 incident it answers zeroed the owner's whole turn on a stale muted button. [ADR 0016](../../decisions/0016-capture-first-mute-redaction.md) keeps a real-time gate for regulated and NDA workflows and names hardening the oracle as that path's only reliability lever, so the clear is a deliberate capture-over-privacy trade. MIC10 (done, archived beside MIC6) then gated the two sibling discredits with "privacy still wins under the regulated gate", and nothing records why the blind clear was left out. The pinned watcher test (`MeetingAXWindowWatcherTests.test_blind_polls_after_muted_clear_the_stale_mute`) exercises a mode-agnostic callback and would pass unchanged under a host-side gate; no test drives `engageMicGate`'s wiring.

**Field evidence (work laptop, 74 recordings, 2026-09-29 to 2026-11-13).** 108 `mute_state_cleared_blind` rows in 36 recordings, always after 3 blind polls: Teams 60 (2.1 per recorded hour), Zoom 47 (31.9 per hour over 3 recordings), Chrome 1. 82 had `previous` muted; the next confident reading was muted again in 75 (median 30 s later, p90 170 s, max 649 s, 5,310 s in total), unmuted in 4, absent in 3. 36 of the 108 followed a `mute_state_window_disagreement` within 10 s. Owner speech inside the 75 windows was 6.5 s, so a regulated leak would have been small here. Still occurring in the newest build (13 blind clears in 6 recordings, 2026-11-12 and 2026-11-13). The reliability audit counts differently (D059: 71 mid-call clears of a muted state in 19 recordings, inside recording windows only), and the totals differ by definition, not by disagreement.

**Zoom (D107).** On each Zoom recording the latch was off between a blind clear and the next `mute_state_polled` for 91 percent of 20260930-180324, 88 percent of 20261013-170136 and 89 percent of 20261112-170131 (47 clears, 40 from muted, 38 of those re-read muted). Zoom's gate sat at `silent_by_rms` for 73.9 percent of recorded time and `muted_by_app` for 8.6 percent. The era C `micgate_attached` row has `mute_button` true, so handles resolve; why the control reads blind (an auto-hiding control bar is the leading guess) is not established. The substring mute-button matching the field pack suspects (audit F042) is filed under [DET15](./DET15.md).

**Harm not yet observed.** `workflow_nda_mode` is false on 113 of 113 meta sidecars and every recording ran capture-first, so in the field the clear changed only the mute verdict, the unused mute timeline and the idle streak. The privacy symptom is code-derived; the frequency is demonstrated.

Correction at filing: the field pack cites the emitter as "line not located" in MicGate; the clear is emitted by `MeetingAXWindowWatcher`'s poll and applied by `MeetingSessionController.engageMicGate`'s `onMuteCleared`, both confirmed above. G007's "Teams goes compact" branch is weaker than F003 states, since the watcher's scope now anchors on the call panel; the AX blackout branch is the field-observed one.

**Related.** [MIC18](./MIC18.md) (P1) decides whether the regulated gate exists at all; on its GO this task's regulated leg is moot and only the policy and Zoom legs remain. [MIC24](./MIC24.md) covers the same producers from the other side (a stale log line outranking the live button). [MIC21](./MIC21.md) owns the missing HAL VAD input. [MIC7](./MIC7.md) owns browser mute.

## Scope

1. **Owner decision first (ADR 0016).** Under `.regulatedGate`, either (a) the blind clear is gated like its siblings: the latch is kept (or the mic held at zero) while the control is unreadable, accepting the MIC6 failure (owner zeroed while really unmuted, which on Zoom today would be most of a call), or (b) the clear stays and the leak is written into ADR 0016 as accepted. The audits' direction is (a). The answer is recorded in ADR 0016 (amended or superseded), or the leg closes as moot on MIC18's GO.
2. **One pure discredit policy in Core.** Move the three decisions now spread over `engageMicGate`'s closures (`onMuteCleared`, `onStaleMuteContradiction`, `blindOnWindowDisagreement`) into one pure function in `daemon/Sources/MeetingPipeCore/MicGate/` taking the capture mode and the evidence kind (blind streak, VAD contradiction, window disagreement) and returning clear or keep. The three closures call it; the regulated row follows the decision in item 1. A kept latch still emits `mute_state_cleared_blind` with a new `applied` attribute (false when kept) and the capture `mode`, so a kept latch is visible in the log.
3. **Zoom, probe first.** Before changing Zoom's reading, an owner-run AX dump of a live Zoom call with the control bar hidden and then shown (step 2 of the walkthrough). If the bar is the only carrier of the mute control, either read a control that stays in the tree (the menu bar's mute item) or hold the last confident state through blind stretches on Zoom instead of clearing after three polls. The choice is made from the dump, in this task.

## Explicitly not

- Deleting the regulated gate: [MIC18](./MIC18.md).
- The stale SlimCore log line that outranks a live button: [MIC24](./MIC24.md). The mute-button substring matcher: [DET15](./DET15.md). Browser mute: [MIC7](./MIC7.md). A speech detector that works without HAL VAD: [MIC21](./MIC21.md).
- Changing `blindClearThreshold` as the fix: a longer streak only narrows the leak and widens the MIC6 failure by the same seconds.

## Acceptance

- The item 1 decision is recorded with its date in ADR 0016 (amended or superseding) and in this file, or this file records that MIC18's GO made it moot.
- Core unit tests of the discredit policy: every (capture mode, evidence kind) pair, with the regulated row matching the decision; MIC10's existing capture-first behaviour unchanged.
- Host-level tests through `engageMicGate`'s wiring (none exist today), one per capture mode (`.captureFirst`, `.captureFirstRedact`, `.regulatedGate`): latch a `.muted`, feed three blind polls, assert the `MicGate` verdict and the `mute_state_cleared_blind` row's `applied` and `mode` attributes.
- `MeetingAXWindowWatcherTests`' blind-clear tests (`test_blind_polls_after_muted_clear_the_stale_mute`, `test_blind_from_start_still_clears_the_latch`, `test_confident_reading_resets_the_blind_streak`) stay green.
- The Zoom dump's outcome and the chosen reading written into this file; if a Zoom matcher change lands, a test pinning it against the dumped tree shape.
- The new attributes documented in `CONVENTIONS.md`'s event-log schema; `swift build`, `swift test` and `bash scripts/ci-local.sh` green, with the number of tests added in the commit body.

## Low findings folded in

- **F035** ([independent audit](../../audits/2026-11-12-independent-audit.md), accepted MIC10 trade-off, sibling path in `MeetingAXWindowWatcher`'s poll via `contradiction.observe(appMuted:vadActive:)`). Under capture-first, about 4 s of app-muted plus HAL VAD voice clears `axMute`, the verdict turns hot and the mute-timeline span closes, so roughly 25 s of a 30 s aside escapes redaction. It needs another process to have enabled HAL VAD (the daemon never writes the enable bit) and the workflow's redact flag on; the regulated gate is exempt by the host gate. On the work laptop it cannot fire: `vad_unsupported` on 70 of 70 gate starts and 0 `mute_state_cleared_vad_contradiction` rows. Direction, folded into item 2's policy table: do not treat VAD-while-muted as staleness by itself; require a second oracle (panel gone, element unreadable, log disagreement), or keep the span marked when the workflow opted in to redaction.
- **D059** ([evidence](../../audits/2026-11-13-recording-reliability-evidence.md)): a duplicate of F003 and G007 from the reliability audit. Its direction (one pure Core policy of capture mode and evidence) is item 2. Harm cannot occur on the work laptop today, since no meeting there ran with NDA mode.

## Owner walkthrough

1. [owner] Answer item 1: under the regulated gate, keep the latch while the control is unreadable (a), or keep clearing and document the leak (b). Skip if MIC18 has gone GO.
2. [owner] On the next Zoom call, run the AX dump the pickup session provides, once with the control bar hidden and once shown. Cost: one call, about a minute.
3. [session] After a week on the landed build, count `mute_state_cleared_blind` rows by `applied` and `mode`, and the Zoom share of time un-latched, and write both into this file.
