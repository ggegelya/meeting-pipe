---
id: END26
title: Switch Teams recording ends to the reducer behind one flag, keeping PromotionEngine log-only as the comparator (gated)
category: Detection
status: new
priority: P3
comment: Filed 2026-11-13 (audit band 2026-11-13). The plan's stage 10, behind its GATE: proceeds only if, after END23 has run two weeks and DET25's shadow ten working days, the ledger still shows a Teams failure class the patches cannot reach, or the shadow beat the old engine on a real call, or the owner rejects the 60 s Confirming end minute (4 of 4 era C Teams ends held 60.0 to 60.1 s); otherwise the decision and its numbers are written here and Teams stays on the patched engine. Scope if it proceeds: the reducer ends Teams recordings behind one flag, a finishing HUD state, level-based ceilings, a session boundary that fixes D068's fused back-to-back calls, and an ADR superseding ADR 0017's Teams end rules.
---

# END26: Switch Teams recording ends to the reducer behind one flag, keeping PromotionEngine log-only as the comparator (gated)

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: the GATE and stage 10 ("End switch for Teams behind one flag") of the staged plan in the [recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md), section "Recommended target design", with the reducer's state machine (states 6 to 9, constants D, G and R) in the [research and designs](../../audits/2026-11-13-recording-reliability-research-and-designs.md) under "Mic Session"; finding D068 in the same audit's verified failure modes; field numbers from the [field evidence](../../audits/2026-11-13-field-evidence.md) and the [reliability evidence](../../audits/2026-11-13-recording-reliability-evidence.md) (D103).

**What Teams ends look like on the newest field build** (from 2026-11-12T09:19Z). All 4 recorded Teams ends were held 60.01 to 60.07 s with the HUD reading Confirming end (holds at 2026-11-12T14:32:36.273Z, 14:53:37.066Z, 15:44:27.928Z and 2026-11-13T07:42:25.713Z), each ended by `PromotionEngine`'s 60 s pair dwell because the SlimCore teardown line was never on disk during a hold; `recorder`/`held_end_trimmed` marked 60.1 to 60.6 s each, mode suggested, audio kept. The other 5 holds of that era (3 Teams, 2 Zoom) were released by the same call's own signals after 5.5 to 38.3 s, one of them a real 22.0 s mic drop on stem 20261112-172307. The 60 s is the cost the GATE weighs; [END17](./END17.md) chose it deliberately.

**D068, a new call inside an open hold** (re-read at HEAD 2026-11-13). `PromotionEngine.handleEndingProvisional` reverts a hold on any `.live` from a signal that had itself gone ended (`let returning = previous?.state == .ended`), and the engine keys on the engagement's `MeetingLifecycleContext` (bundle id, kind, pid and the title read at engage), with no notion of which call. A process-audio release at the end of one meeting followed by the same app opening the mic for the next meeting inside the 60 s dwell reverts the hold to `.inMeeting`, so two meetings become one recording under the first one's workflow and routing. The pack holds no fused recording; the exposure is that 4 of 69 recordings saw the same app's mic true again within 60 s of a release (30.9, 32.3, 43.8 and 55.7 s, scan upper bounds), which at HEAD lands inside a 60 s hold. D068 is graded "not seen" and code-derived.

**Why it is gated.** The audit's own dissent argues most of the reducer should not be built: in the newest build 0 of 6 recordings were ended early by a wrong proxy and the 4 trims were correct, and the defects seen there are small patches on END17's structure ([END20](./END20.md), [END21](./END21.md), [END23](./END23.md)). The plan answers it by keeping Teams on the patched engine by default unless the ledger says otherwise.

## Gate (decide first, no code)

Decided once [END23](./END23.md) has run two weeks and [DET25](./DET25.md)'s shadow reducer ten working days. Proceed only if at least one holds:

- The ledger still shows a Teams failure class the patches cannot reach: an early stop, an overrun past 130 s, a repeated prompt withdrawal, or a wrong trim from a Leave-led hold.
- DET25's shadow `would_close` beat `PromotionEngine` on a real call (an earlier correct end, or no end where the engine chopped).
- The owner finds the 60 s Confirming end minute unacceptable.

If Teams shows zero early stops, zero overruns past 130 s and zero unrecorded calls of 2 minutes or more, the default is to stop here: write that decision into this file with the numbers beside it, and state its cost (two end paths stay alive, `PromotionEngine` for Teams and Zoom and the reducer for browsers, and the delete stage shrinks).

## Scope (only if the gate says go)

1. **The switch.** A single flag selects the end authority for the Teams family. On: DET25's reducer (`MicSession.decide`) stops Teams recordings with cause `mic_release` and the cut at the release plus a 2 s pad; `PromotionEngine` keeps running and logs what it would have done as the comparator. Off: today's path, unchanged. If the flag is a config key it goes through `ConfigStore` and the truth fences like any other.
2. **The finishing state.** On the release the HUD reads a finishing countdown with Still in call (suspends automatic closing until the mic returns, the owner stops, or the ceiling) and Finish now (closes at once). Both clicks are logged as labels. `docs/GUIDE.md` recipes and any tutorial step naming Confirming end change in the same commit (the root `CLAUDE.md` same-commit contract and `daemon/CLAUDE.md`'s tour rule).
3. **Ceilings.** The reducer's ceiling is unconditional and level-based, with no stand-down branch, per [END25](./END25.md)'s rules; the Teams release ceiling of END23 is subsumed and stays as the fallback while the flag is off.
4. **D068: a session boundary.** A same-family mic return after the close grace G opens a new session and a new recording (logged with `resumed_from`, never merged automatically), never a revert. A return inside G stays one recording and writes a gap marker at the release, and the Library gains a Split action at a gap marker so a fused pair is one click from two recordings. Pin G from DET23's uncensored gap table (the larger of 30 s and 1.25 times the longest same-call gap, capped at 60 s), not from the pack.
5. **Stop at sleep** with the mark at sleep time, only if [END22](./END22.md) has not already done it; the far-side quiet check only if DET23's post-release level rows support it.
6. **A new ADR** superseding ADR [0017](../../decisions/0017-hold-long-trim-later-end-detection.md)'s end rules for Teams, with `ARCHITECTURE.md`, `CONVENTIONS.md` (new events and the flag), `README.md` and `daemon/CLAUDE.md` in the same commit.

## Explicitly not

- The Teams start switch (plan stage 11), Zoom (waits on DET24's bar Z1) and browsers (plan stage 9, which is not gated).
- Deleting `PromotionEngine`, `CallTeardownOracle`, the hold or the window and Leave voters (plan stage 14): only after two clean weeks with the flag on, as its own task.
- Title hashes as an end or consent decision, and sound as a class that can block an end (rejected in the audit's grafts).
- Fixing D068 inside `PromotionEngine` (a call-identity check on revert): if the gate says stop, D068 stays an unfixed, unseen risk recorded here, and a recurrence in the ledger is a reason to revisit the gate.

## Acceptance

- CI replay of DET25's level corpus through the real reducer with the flag on: the four October chops stay recording, both gaps near 23 s survive at the chosen G, the three overruns (562 s, 63 s, about 380 s) close G after the release, and the 98.7 s drop yields two linked parts.
- New tests: a same-family mic return after G inside what would have been the old 60 s hold yields two recordings with `resumed_from`, the second under freshly resolved routing; a return inside G yields one recording with a gap marker; Split at a gap marker produces two linked recordings; flag off restores `PromotionEngine` as the authority (a test that runs one trace both ways); Still in call holds through a 5 minute release and Finish now stops at once.
- `cd daemon && swift test` green with the number of tests added in the commit body; `cd pipeline && uv run --extra dev pytest -q` green if the Split touches the sidecar reader; `bash scripts/ci-local.sh` green; truth fences clean.
- Field, two weeks of daily use with the flag on: no false end, no overrun beyond G plus 5 s after a release, a cause on every stop, and every Restore and Still in call click reviewed. Rollback is the flag.

## Owner walkthrough

1. [session] When END23 has two weeks and DET25 ten working days of shadow, assemble the gate numbers: early stops, overruns past 130 s, unrecorded Teams calls of 2 minutes or more, prompt withdrawals, wrong trims, and every call where `would_close` and the engine disagreed.
2. [owner] Decide go or stop against the gate, and say whether the 60 s Confirming end minute is acceptable. The session writes the decision and numbers into this file.
3. [owner] If go: two weeks with the flag on, one test call with five input-device switches, and a click on Still in call or Finish now whenever the finishing state looks wrong.
4. [session] Review every Still in call, Finish now and Restore click against the stop rows and report.
