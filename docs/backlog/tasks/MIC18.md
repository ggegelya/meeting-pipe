---
id: MIC18
title: Decide by count, then delete the regulated real-time mic gate and the destructive stop-time cut, so regulated and NDA meetings keep lossless capture with offline redaction and a reversible trim
category: Recording
status: new
priority: P1
comment: Filed 2026-11-13 (product-direction band, idea I41, 13.99 of 20, picked by codebase-engineer and owner-advocate): the strictest mode is the lossiest, and the audit's one critical (G001, the cut deletes in-call audio for good) and a high (F004, a stale verdict zero-fills the mic) live in exactly this path. P1 because it decides the remedy for that critical before an in-place fix starts; owner may re-band. Reverses an ADR 0016 clause, so the owner decides; a 2-day counts-only probe pre-registers GO (delete) or NO-GO (fix in place). Lands only after the F001 and F020 sole-copy fixes and with the library off iCloud. Child of [EPIC4](./EPIC4.md). Amended 2026-11-13 by the audit band: withheld redaction spans surfaced and the toggle copy made true in either branch, and on NO-GO no regulated start on a source with no mute oracle (F024, D061).
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

## Amendment 2026-11-13 (audit band)

Added from the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md) finding F024 (low, confirmed; classed there as a known, accepted trade-off of MIC12, now done and archived in [q6-final.md](../q6-final.md), and of ADR 0016's MIC9 amendment) and the [2026-11-13 recording-reliability audit](../../audits/2026-11-13-recording-reliability-audit.md) finding D061 (low, unverified there, not observable in the field). Recorded on this task because it now owns the redaction design. Both readings were re-verified in code at HEAD (`3a2da4fc`) on 2026-11-13. The class came in at P2; this task stays P1.

**F024, the redaction keeps speech-bearing muted spans and says nothing.** `MuteRedactor.partitionSpans` keeps an auto (`.mute`) span for redaction only when `micChannelMeanDb(of: wav, in: span)` reads at or below `speechFloorDb`, which is `-50`; a louder or unreadable span is withheld. Manual off-the-record spans are exempt (MIC14: `source == .manual` always redacts). The only record of a withhold is `recorder` / `mute_redaction_withheld` (counts only: `muted_spans`, `withheld_spans`, `redacted_spans`, `reason: speech_in_muted_span`) plus a `recorder.log` line, and when every auto span is withheld `redactIfNeeded` reaps the timeline and returns `.notNeeded`. Nothing in `daemon/Sources` or `pipeline/src` reads that event, so the owner is never told. The copy promises the opposite in three places: `WorkflowsView`'s toggle "Redact muted spans from the notes" ("On, muted moments are removed from the consumed notes offline"), `WorkflowInspectorPresentation`'s "Muted spans are redacted from the notes", and the mute-tracking sublabel in `PreferencesView+Recording` ("lets a workflow's "Redact muted spans" remove those moments from the notes offline"). The audit's scenario: redaction on, the owner mutes in Teams for five minutes and talks to someone in the room, the span's mean is above -50 dBFS, it is withheld, and the aside is transcribed, summarized and published with no notice.

**D061, what a verdict does differs by mode.** In `MeetingRecorder`'s tap, `.captureFirst` and `.captureFirstRedact` add every buffer to the timeline with `muted: verdict.indicatesMute`, which is true only for `.mutedByApp` and `.mutedByHardware`, and `persistAfterMerge` writes the full timeline only `if captureMode == .captureFirstRedact` (a manual-only one under `.captureFirst`). Under `.regulatedGate` the tap calls `MicGateWriter.apply`, where `isHot = !forceMuted && verdict.passesLiveAudio` is true only for `.hot`, so `.silentByRMS` and `.uncertain` zero-fill live exactly as the two muted verdicts do. A browser source has no app-mute oracle (`MeetingAXHandleBuilder.build` returns an empty `MicGateAdapterHandle()` for `kind == .browser`, see [MIC7](./MIC7.md)), so under the gate a quiet mic on a browser call reads `silent_by_rms` and the owner's side is zeroed with nothing kept to recover.

**Field exposure: none.** The [field evidence](../../audits/2026-11-13-field-evidence.md) (work laptop, 2026-09-29 to 2026-11-13) has 1 `mute_timeline_written` and 1 `mute_redacted` with 1 span, and the recording-reliability audit found that row is a manual off-the-record span, not an auto-mute redaction; `workflow_nda_mode` is false on every sidecar. The verdict log does show what the gate would do: 1,220 in-recording crossings between hot and not-hot, each a zero-fill decision under the regulated gate, and `silent_by_rms` held 6.7% of recorded time; `vad_unsupported` was logged on 70 of 70 gated recordings, so no voice-activity evidence backs any of those verdicts.

Correction at filing: the class summary said capture-first "records spans only for mutedByApp or mutedByHardware"; precisely, every buffer is added with `muted:` taken from `indicatesMute`, so only those two verdicts become muted spans. The audit cited two copy sites; `PreferencesView+Recording` is a third with the same promise.

**Scope additions, either branch of the decision.**

1. **Surface withheld spans.** When `partitionSpans` withholds any auto span, `redactIfNeeded` returns the withheld spans in its `Outcome` instead of only logging, including the all-withheld case that returns `.notNeeded` today. The meeting then carries a held-back state the owner sees: a Library row badge and a line in the done notification naming how many muted stretches were kept because the mic picked up speech, with their times, and two actions: redact them anyway (applied as manual spans, which MIC14 already treats as intent) or keep them. Whether the publish waits for that answer or goes out with a review flag is put to the owner before the build; the proposal here is to wait, since the toggle exists to keep asides out of the notes.
2. **Make the copy say what the guard does.** The three strings name the guard: muted stretches with no speech are removed, and a muted stretch where the mic picked up speech is kept and flagged for review. [DOC20](./DOC20.md) owns the README, SETUP and CONVENTIONS statements; the GUIDE.md recipe for the toggle changes in the same commit as the strings (the CLAUDE.md same-commit contract).

**Scope addition, NO-GO only (the gate stays).**

3. **No regulated recording on a source the gate cannot read.** Refuse to start a regulated or NDA recording whose MicGate has neither an app-mute oracle nor working voice-activity evidence (today every browser source and every source-less hand start), rather than recording a mic that RMS silence zero-fills. The refusal is visible at the start surface with its reason and logs `coordinator` / `recording_start_refused` with `reason: no_mute_oracle`. On GO this item is moot, since `.regulatedGate` is deleted.

**Acceptance additions.**

- `MuteRedactor` tests: one quiet and one speech-bearing auto span redacts the first and returns the second as withheld in the outcome; an all-withheld timeline keeps the full mic and still returns its withheld spans; a manual span is never withheld.
- A test that the held-back state reaches the Library row and the done notification for a meeting with withheld spans, and does not appear for one without.
- A test or fence that none of the three strings promises unconditional removal.
- NO-GO only: a `MeetingSessionController` test with a browser source under regulated mode (fake MicGate with no oracle, VAD unsupported) refuses the start and emits `recording_start_refused`; a native source with a mute button still starts.
- `cd daemon && swift build` and `swift test` green, `python3 scripts/truth_fences.py` green for the new event action, new test count in the commit body.
