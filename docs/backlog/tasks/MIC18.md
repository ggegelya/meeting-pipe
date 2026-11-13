---
id: MIC18
title: Decide by count, then delete the regulated real-time mic gate and the destructive stop-time cut, so regulated and NDA meetings keep lossless capture with offline redaction and a reversible trim
category: Recording
status: new
priority: P1
comment: Filed 2026-11-13 (product-direction band, idea I41, 13.99 of 20, picked by codebase-engineer and owner-advocate): the strictest mode is the lossiest, and the audit's one critical (G001, the cut deletes in-call audio for good) and a high (F004, a stale verdict zero-fills the mic) live in exactly this path. P1 because it decides the remedy for that critical before an in-place fix starts; owner may re-band. Reverses an ADR 0016 clause, so the owner decides; a 2-day counts-only probe pre-registers GO (delete) or NO-GO (fix in place). Lands only after the F001 and F020 sole-copy fixes and with the library off iCloud. Child of [EPIC4](./EPIC4.md).
---

# MIC18: decide by count, then delete the regulated real-time gate and the destructive end cut

Band origin: filed 2026-11-13 from the product-direction band ([report](../../research/2026-11-12-product-direction.md), idea I41, "Regulated mode means zero egress, not zero recovery: delete the real-time gate and the destructive end cut"). Child of epic [EPIC4](./EPIC4.md). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Why P1

The 2026-11-12 [audit](../../audits/2026-11-12-independent-audit.md)'s one critical, G001, is the stop-time `truncated` cut, pinned at the hold's first stamp, which under this mode deletes in-call audio permanently; F004 (high) is a stale mute verdict zero-filling the mic. The parallel 2026-11-13 audit filing is turning both into defect tasks (search the backlog for the finding ID). Repairing them in place and then deleting the path would pay twice, so this decision belongs before that fix starts. The broken promise: a recording of the most sensitive meetings can silently lose audio that was spoken in the call. The owner may re-band (the DIAR2 precedent).

## Context, verified 2026-11-13

- `daemon/Sources/MeetingPipe/CaptureMode.swift` has three cases and one resolver (`resolve`): `.captureFirst`, `.captureFirstRedact`, `.regulatedGate`. `MeetingSessionController`'s `keepsHeldTail` is the only place the `truncated` cut is chosen.
- END17 shipped the non-destructive `held_end_trim_sec` suggestion (HeldEndTrim) for every lossless mode; `MuteRedactor` with its runaway-redaction guard is the offline redactor; the off-the-record hotkey is the deliberate real-time zeroing. Event rows: `held_end_trimmed` (with `mode`), `lifecycle_end_held`, `micgate_attached`.
- ADR [0016](../../decisions/0016-capture-first-mute-redaction.md) kept a real-time gate for regulated and NDA and accepted its residual data-loss risk; ADR [0017](../../decisions/0017-hold-long-trim-later-end-detection.md) rejected never-auto-end (not proposed here: the stop stays, only the cut goes). What changed: the audit found a critical and a high in exactly that accepted corner, plus G026 and two MIC8 fixes not holding (F036, G027), and END17 has since shipped the alternative for every other mode.

- **Field evidence (2026-11-13).** The [field pack](../../audits/2026-11-13-field-evidence.md) (74 recordings, 2026-09-29 to 2026-11-13) has `workflow_nda_mode` false on all 113 meta sidecars and all 4 `held_end_trimmed` rows in mode `suggested`: the truncating cut never ran in the field and F004 could not show. So the probe below is expected to land in its NO FIELD EVIDENCE row, and the decision rests on the audit's code reading and the owner's one-line answer. It also means the mode's real-world cost today is zero while its code cost (a critical, a high, two capture paths for one recorder test to cover) is not.

## Pre-registered probe (copied from the report; owner-run, read-only, counts only, 2 days)

From `events.jsonl`: N = recordings that ran as `regulated_gate`. For each `held_end_trimmed` row with mode `truncated`, discarded seconds = stop time minus start time minus `limit_sec`, joined to the matching `lifecycle_end_held` row for its dwell values. Then ffmpeg `silencedetect` over the left channel of those N recordings: M = recordings whose mic channel is exact digital silence for more than 50% of its length.

| Verdict | Measured | Next |
|---|---|---|
| **GO (delete the mode)** | Any truncated row discarded more than its dwell plus 60 seconds, OR M is at least 1 | Scope below |
| **NO-GO** | Both zero across at least 20 regulated recordings, OR the owner states that zero muted audio at rest is an external obligation and not a preference | G001 and F004 are fixed in place by their defect tasks and the mode stays |
| **NO FIELD EVIDENCE** | Both zero AND fewer than 20 regulated recordings (the expected case: the field pack below shows none) | The count cannot decide. The owner decides on the audit's code-level reading of G001 and F004 plus one line: is zero muted audio at rest an external obligation (NO-GO) or a preference (GO) |

## Scope on GO

- `CaptureMode.resolve` returns `.captureFirstRedact` for regulated and NDA; `.regulatedGate` and the `truncated` branch of `keepsHeldTail` are deleted with their tests; the held tail becomes the same reversible `held_end_trim_sec` suggestion every other meeting gets.
- The mode's promise is restated in README, [docs/GUIDE.md](../../GUIDE.md) and the Preferences copy: nothing leaves this Mac, muted asides never reach transcript, notes or sinks, the unredacted original expires on a short stated retention.
- ADR 0016 is amended (a superseding ADR) with the owner's sign-off recorded in it.

## Preconditions (hard, not advisory)

The kept original becomes the recovery copy, so this lands only after the audit's F001 (the originals reaper deletes sole copies) and F020 (default uninstall deletes them) are fixed, and with the library moved off the iCloud-synced Documents folder (SEC12 in [q6-final.md](../q6-final.md), [SEC18](./SEC18.md)), since audio at rest there means audio at Apple.

## Explicitly not

- Never-auto-end (ADR 0017 stands).
- Changing the default capture mode for unregulated meetings.
- Removing the off-the-record hotkey.

## Owner walkthrough

Run the counts command written into the decision note, read GO or NO-GO, and state in one line whether zero muted audio at rest is an external obligation. Either answer closes the decision when the counts cannot (the expected case); GO then needs the ADR sign-off.

## Acceptance

- The probe script (read-only, counts only) and a dated verdict recorded in this file.
- On GO: one commit deleting the gate and the cut; tests pinning that regulated and NDA resolve to `.captureFirstRedact`, that no code path writes a `truncated` trim, and that the held tail is offered as a reversible suggestion; `swift build`, `swift test` and `bash scripts/ci-local.sh` green; the README, GUIDE and ADR edits in the same commit.
