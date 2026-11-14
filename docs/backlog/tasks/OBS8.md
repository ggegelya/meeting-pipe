---
id: OBS8
title: A quarter of model-proposed citations are dropped by verification with no reason logged, and a quarter of action items end up with no anchor
category: Observability
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). evidence_verified carries only kept and dropped counts, so 661 of 2,676 anchors dropped (24.7 percent, 110 stems, worst kept 1 of 21 in 20261021-120034, 176 of 761 actions left unanchored) cannot be split into model error and rule strictness, and the speaker cleanup's 18.1 percent relabel rate has no per-meeting surface either. Scope: a drop reason per anchor counted on evidence_verified, resolve idempotent on its own snapped time, the drop and relabel shares persisted per meeting and flagged in the Library above one half.
---

# OBS8: A quarter of model-proposed citations are dropped by verification with no reason logged, and a quarter of action items end up with no anchor

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Sources: two field findings in [2026-11-13-field-evidence.md](../../audits/2026-11-13-field-evidence.md), "A quarter of the citations the model proposes do not survive verification, and a quarter of action items have none" (Transcripts and summaries, finding 10) and "Two LLM passes change what the owner reads and nothing measures whether they are right" (Pipeline and publishing, finding 8). Neither is in the [independent audit](../../audits/2026-11-12-independent-audit.md). Code re-read at HEAD `3a2da4fc` on 2026-11-13.

**The field numbers (work laptop, 110 summarized stems).** `evidence_verified` rows sum to 2,015 anchors kept and 661 dropped (24.7 percent); the rate is the same in English (25.0) and Cyrillic (24.9) meetings and lower under 10 minutes (15.8). 12 stems lost half or more: kept 1 of 21 in `20261021-120034`, 6 of 29 in `20260928-200131`, 5 of 24 in `20260922-123414`. After the drop, 176 of 761 actions, 76 of 329 questions, 72 of 526 bullets and 14 of 158 decisions carry no anchor. By build era the drop share is 24.6 (A), 26.1 (B) and 10.3 percent (C, 10 of 97 on 5 stems, too few to call). What is stored is sound: 2,007 of the 2,015 kept anchors re-resolve against the stored transcript, and the other 8 quotes exist elsewhere in it.

**Why the logs cannot say more.** `evidence.verify` runs every anchor through `resolve`, which has three ways to return `None` and does not say which: the normalized quote is empty or longer than `MAX_QUOTE_WORDS` (25), no segment sits within `SNAP_WINDOW_SEC` (45 s) of `anchor.t`, or the quote is in neither one window segment nor the joined window. `_verify_anchors` only counts (`dropped += 1`), and `summarize._verify_evidence` emits `evidence_verified` with `stem`, `kept`, `dropped` and `segments`. The drop itself is by design (the module's "absence over wrong anchors" rule); the 25 percent rate, and whether it is the model misreading `[mm:ss]` markers or the rule being strict about paraphrase, is what nobody can see. The same `verify` serves the staged local path (`summarize_staged`, LOCAL14), so a reason there would cover both call sites; the Swift Apple summarizer emits no anchors at all ([ARCH11](./ARCH11.md)).

**Idempotency, narrower than reported.** `resolve` returns the start of the segment that contains the quote when one does, and re-resolving that time finds the same segment at distance 0, so that branch is idempotent. The fallback branch (a quote that spans a turn boundary and only matches the joined window) returns `min(window, key=...)`'s start, the nearest segment to the model's time; re-resolving from there centres a new 45 s window that can lose the far half of the quote, and the anchor then fails. Correction at filing: the field finding calls `resolve` not idempotent once a time is snapped; at HEAD that holds only for the spanning-quote fallback, and a Library text overlay applied after verification is the other candidate for the 8 non-resolving anchors. Nothing in production re-verifies a stored anchor today, so this is a latent defect that bites the first re-verify (a regenerate over an edited transcript, or a later consistency check).

**The cleanup pass, folded in (field Pipeline finding 8, low).** Speaker cleanup ran on 111 meetings and relabelled 2,919 of 16,092 segments (18.1 percent), merged 486 and refused 42 on voiceprint distance; 23 meetings had a quarter or more relabelled; median cost 12.1 s and 2.86 Anthropic calls a meeting. Correction at filing: the counts are already logged. `diarize_cleanup.cleanup_transcript` emits `pipeline`/`diarize_cleanup` with `merges_count`, `reattributions_count` and `segments`, each applied `EditRecord` being one segment, so the share is computable per row. What is missing is the meeting: the row carries no `stem` (that is [OBS4](./OBS4.md)'s stamp) and nothing surfaces the share per meeting, so an outlier is invisible.

## Scope

1. **A reason per dropped anchor.** Make `resolve` return a small result (snapped time or a reason from a closed set: `quote_empty`, `quote_too_long`, `no_segment_in_window`, `quote_not_found`) instead of `float | None`, keep `VerifyResult.kept` and `dropped`, and add `dropped_by_reason: dict[str, int]`. `summarize._verify_evidence` adds one count attribute per reason to `evidence_verified` (`dropped_quote_not_found` and so on, zero-valued keys omitted). For `quote_not_found`, also count how many of those quotes do appear somewhere in the transcript outside the window (`dropped_quote_elsewhere`), which is the line between a misread timestamp and an invented quote. No quote text in any row.
2. **Idempotent resolve.** In the joined-window fallback, snap to the start of the earliest window segment that the quote's first words fall in (the segment where the quote begins), and pin that `resolve(Evidence(quote, t=resolve(a)), segs) == resolve(a, segs)` for both branches.
3. **Per-meeting shares persisted.** Write `evidence_kept`, `evidence_dropped` and `cleanup_segments_changed` (merges plus reattributions) with `cleanup_segments` beside the summary's provenance (`<stem>.run.json`, which `corrections.write_run_sidecar` writes; the pickup confirms it is the file the Library already reads for provenance). If Swift reads the new keys, they are a cross-tree contract: `CONVENTIONS.md` and the shared fixture in the same commit.
4. **Library flag.** In the meeting detail's provenance line, show a quiet note when more than half of the proposed anchors were dropped, or more than a quarter of segments were relabelled, worded per `docs/GUIDE.md`'s register and added to the guide in the same commit.

## Explicitly not

- Loosening `SNAP_WINDOW_SEC` or `MAX_QUOTE_WORDS`, or fuzzy quote matching. The reasons from item 1 are what would justify either; decide after a week of them.
- Grading the relabels. Without audio the pack cannot say whether a relabel is right; that is an owner sampling exercise (walkthrough step 3), not code.
- A `stem` on `diarize_cleanup` and every other pipeline row: [OBS4](./OBS4.md). Item 3 reads the counts from the cleanup's return value, not from the event.
- Anchors from the Apple Intelligence path, which emits none: [ARCH11](./ARCH11.md).
- Re-running verification over the existing 110 summaries. The rows start with the landing build.

## Acceptance

- `test_evidence.py`: one test per drop reason (an empty quote, a 26-word quote, a time 60 s from every segment, a quote absent from the window), each asserting the reason and that `dropped_by_reason` sums to `dropped`; a quote absent from the window but present 3 minutes away counts in `dropped_quote_elsewhere`.
- Idempotency: for a single-segment quote and for a quote spanning two turns, re-resolving the snapped time returns the same time; the spanning case fails on HEAD's code.
- `test_summarize.py` (or the existing `_verify_evidence` test): `evidence_verified` carries the per-reason keys, omits zero ones, and carries no quote text.
- The run sidecar test writes and reads the four new keys; if the Library reads them, a Swift decode test over the shared fixture.
- `evidence_verified`'s new attributes documented in `CONVENTIONS.md`; `python3 scripts/truth_fences.py events` green.
- `cd pipeline && uv run --extra dev ruff check src tests`, `pyright` and `pytest -q` green, N new tests named in the commit body; `swift test` green if item 4 touched Swift; `bash scripts/ci-local.sh` green.

## Owner walkthrough

1. [session] After a week on the landing build, tabulate `evidence_verified` drop reasons across that week's stems and add the table to this file.
2. [session] If `quote_not_found` with `dropped_quote_elsewhere` dominates, the model misreads timestamps; if `quote_not_found` without it dominates, it paraphrases. Propose the matching follow-up (prompt or rule) to the owner, do not change the rule here.
3. [owner] Grade the speaker relabels on three meetings the session picks (one over a quarter relabelled, two typical) by listening to five relabelled segments in each and marking each right or wrong. Cost: about 20 minutes.
