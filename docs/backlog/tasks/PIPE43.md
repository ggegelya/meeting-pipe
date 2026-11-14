---
id: PIPE43
title: Nothing stops a summary of a transcript too thin to mean anything, so 10 meetings of 20 s to 32 words got summaries with action items
category: Pipeline
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). 10 of 110 field summaries were written for transcripts under 300 words, under 3 minutes or under 20 wpm (a 20 s, 32-word fragment got an 88-word summary), and none of the 110 has zero action items, because run_all's only pre-summary gates are no segments and the suspect check (2.0 wpm, only from 300 s), and MeetingSummary accepts an empty title and no bullets. Add a content floor that writes an empty marker with a new reason instead of a summary, on owner-confirmed thresholds, and give the schema lower bounds.
---

# PIPE43: Nothing stops a summary of a transcript too thin to mean anything, so 10 meetings of 20 s to 32 words got summaries with action items

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: the 2026-11-13 [field evidence report](../../audits/2026-11-13-field-evidence.md), section "Transcripts and summaries", finding "No content floor before summarizing: 10 summaries for transcripts too thin to mean anything, each with action items" (transcripts-and-summaries#7), with F176 from the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md) ("Summary schema accepts empty and blank output as a valid summary") folded in as the schema half.

**Field numbers.** Summaries exist for `20261009-121708` (20 s, 32 words, 88-word summary), `20261009-173127` (32 s, 54 words, 118-word summary), `20261008-173712` (89 s), `20261106-163023` (92 s), `20260916-142015` (97 s), `20260917-123752` (126 s), `20260928-163023` (162 s), `20260925-173113` (272 s, 41 wpm), `20261104-170016` (690 s, 176 words, 15 wpm) and `20260923-154340` (2,692 s, 131 words, 2.9 wpm). Each has 2 to 4 bullets, 1 to 3 action items and 1 to 2 unresolved questions. Across all 110 summaries none has zero actions. By build era: A 8, B 2, C 0 (C has only 5 summaries). The no-speech and suspect-transcript skips each fired once in the field, correctly.

**Gates, re-verified at HEAD `3a2da4fc` on 2026-11-14.** `orchestrate.run_all` runs `skip = _check_no_speech(wav, t, structured) or _check_suspect_transcript(wav, t, structured)` after finalize, then `_check_byo` and `_check_too_long`, and nothing else before summarize. `_check_no_speech` skips only when `structured.get("segments")` is empty. `_check_suspect_transcript` calls `transcript_quality.transcript_issues`, whose words-per-minute floor applies only when `_duration_sec(segments) >= _WPM_MIN_DURATION_SEC` (300.0) and trips only below `_WPM_FLOOR` (2.0); `_duration_sec` is the maximum segment end, not the recording length; the repetition check needs `_REP_MIN_WORDS` (60). The module docstring states the intent: "Conservative by design: only clearly degenerate output is flagged, so a real meeting is never withheld." A skip writes `<stem>.empty.json` through `_mark_empty(wav, reason)` and emits `run_skipped` with the reason.

**Schema half (F176), re-verified.** `schemas.MeetingSummary` sets `title: str = Field(..., max_length=120)` and `summary: list[str] = Field(..., max_length=10)`, upper bounds only. `MeetingSummary.model_validate({"title": "", "summary": [], "decisions": ["  "]})` validates and keeps the blank entry (checked 2026-11-14). `SUMMARY_TOOL` lists `actions` as required but allows an empty array, and its description says "Do not invent action items", so the prompt does not demand an action; the model supplies them anyway.

**Swift reader.** `EmptyReason(marker:)` knows `no_speech` and `suspect_transcript` and falls back to `.noSpeech` for anything else, so a new pipeline reason would show "No speech" in the Library unless Swift learns it in the same commit.

Correction at filing: the field recommendation's "measure the wpm floor against the recorder length" depends on [ASR10](./ASR10.md), which fixes `audio_seconds` and deliberately left this denominator to the content-floor decision. With the 2.0 wpm floor a real length barely moves it (a five-minute meeting at 100 wpm would need a silent tail of about four hours to trip), so this task keeps the suspect check's denominator as it is and adds the floor as a separate gate on words and speech span.

Related: [ASR10](./ASR10.md) (the recorder length), [FEAT21](./FEAT21.md) (attendees and owners as diarization labels), [UX90](./UX90.md) (a skip that notifies "Meeting processed").

## Scope

1. **A content floor gate.** A pure `transcript_quality.below_content_floor(segments) -> str | None` returning a reason when the transcript has fewer than `_FLOOR_MIN_WORDS` words or a speech span (first segment start to last segment end) under `_FLOOR_MIN_SPAN_SEC`. Starting values for the owner to confirm: 150 words and 120 s, per the field recommendation. Wired in `run_all` as a third check after `_check_suspect_transcript`, as `_check_content_floor(wav, t, structured)`, which emits `run_skipped` with `reason="below_content_floor"` and the word count and span, and calls `_mark_empty(wav, "below_content_floor")`.
2. **Swift knows the reason.** `EmptyReason` gains `belowContentFloor = "below_content_floor"` with its pill label, detail, notification title and body (for example "Too short to summarize"), in the same commit as item 1.
3. **Schema lower bounds (F176).** `MeetingSummary`: `title` stripped and at least one character, `summary` at least one non-blank bullet, and blank entries dropped from `summary`, `decisions` and `questions` in the `mode="before"` normalizer, so an empty model answer fails validation and goes down the existing repair or failure path rather than being written as a summary. Legacy `<stem>.summary.json` files that already violate this are read by the publishers through the same model, so the pickup checks the 110 field summaries still validate before landing.
4. **The override stays.** The Library's Re-summarize runs `mp summarize`, which does not go through `run_all`'s gates, so a floor-skipped meeting the owner wants summarized can still be. The pickup confirms that path reaches a meeting carrying `<stem>.empty.json`.

## Explicitly not

- A short-form prompt that may return no actions instead of the floor: it still spends a model call on a 32-word fragment and relies on the model complying, which the field shows it does not (0 of 110 summaries with no actions). A prompt change for ordinary short meetings is a separate decision.
- Changing the suspect check's 300 s and 2.0 wpm or its denominator: see the correction above and [ASR10](./ASR10.md).
- Attendee lists made of diarization labels, and evidence anchors that fail verification: separate findings in the same report section.

## Acceptance

- `test_transcript_quality.py`: `below_content_floor` returns a reason for a 32-word, 20 s transcript and for a 131-word, 2,692 s one; returns `None` for 300 words over 10 minutes; the thresholds are module constants the tests read.
- `test_orchestrate.py`: a below-floor transcript skips with `run_skipped` reason `below_content_floor`, writes `<stem>.empty.json` with that reason and makes no summarize call; an above-floor transcript summarizes as before.
- `test_schemas.py`: an empty title, `summary: []`, and a summary of only blank bullets each fail validation; blank entries in `decisions` and `questions` are dropped; every existing fixture summary still validates.
- `EmptyMarkerTests`: `below_content_floor` parses to `.belowContentFloor` with its own copy; an unknown reason still falls back to `.noSpeech`.
- `below_content_floor` is documented beside the other skip reasons in `CONVENTIONS.md`, and `docs/GUIDE.md` says a very short recording is kept but not summarized, in the same commit.
- Pipeline ruff, pyright and pytest green; `cd daemon && swift test` green; new test counts in the commit body; `bash scripts/ci-local.sh` green.

## Owner walkthrough

1. [session] Before landing, run `below_content_floor` read-only over the owner's library transcripts and report how many of the 113 it would skip, listed by stem with word count and span, against the 10 the field report names.
2. [owner] Confirm or change the two thresholds from that list.
3. [owner] After landing, the next very short recording shows the new Library state instead of a summary, and Re-summarize on it produces one.
