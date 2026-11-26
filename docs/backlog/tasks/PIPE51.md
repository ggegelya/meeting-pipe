---
id: PIPE51
title: All four publishers send the raw transcript, so speaker names and text corrections made in the Library never reach Notion, Obsidian, the filesystem or LAN
category: Pipeline
status: owner-verify
priority: P2
verification: simple
comment: Shipped 2026-11-18 (all four sinks, fanout, publish_notion.publish); 2026-11-26 amendment shipped: a publish now refuses an unreadable speaker-label or correction overlay before any sink (exit 3, publish.json records it), tested. Remaining: the owner's one real rename + Republish to Notion/Obsidian to see the names land. Owner approved owner-verify on 2026-11-26.
---

# PIPE51: All four publishers send the raw transcript, so speaker names and text corrections made in the Library never reach Notion, Obsidian, the filesystem or LAN

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: the 2026-11-12 [independent audit](../../audits/2026-11-12-independent-audit.md), finding F107 ("All four publishers send the raw `<stem>.md`, ignoring the Library's speaker and text-correction overlays"), lens data, medium, confirmed, backlog "Claimed fixed, not holding (FEAT3-SEGMENT, PIPE9)".

**A done task's fix does not hold.** FEAT3-SEGMENT (done, `d9983d9c`, archived in [q6-final.md](../q6-final.md)) resolved its acceptance line "a subsequent republish reflects it" by making the speaker overlay a Swift-to-Python contract, but wired it into `summarize` only, so a regenerate reflects names in the summary while the transcript every sink publishes does not. PIPE9 (done, `712b63af`) states corrections reach "the pipeline" and wired `summarize` and `embed_index` only. Neither reaches a publisher.

Re-verified in code at HEAD `3a2da4fc` on 2026-11-14:

- In-app naming and line edits write only overlays: `<stem>.speaker_labels.json` (`SpeakerLabelStore`) and `<stem>.transcript_corrections.json` (`TranscriptCorrectionStore`). Enroll runs with `--no-relabel`, so `<stem>.md` keeps the raw diarization labels and the raw ASR text by design (FEAT3-UNDO).
- `transcript_corrections.overlaid_markdown(transcript_md)` returns the transcript re-rendered with both overlays, or `None` when neither changes anything. Its callers are `summarize` (`overlaid if overlaid is not None else transcript_md.read_text(...)`), `embed_index` and `mcp_tools`. No publisher calls it.
- `publish_router.fanout` passes every sink the same `transcript_md: Path`, and each sink reads it raw: `publish_notion._build_blocks` (`_transcript_toggle(transcript_md.read_text(encoding="utf-8"))`, on by default since `include_full_transcript: bool = True`), `ObsidianPublisher` (`"## Transcript\n\n" + transcript_md.read_text(...)`), `FilesystemPublisher` and `LanPublisher` (`transcript_md.read_text(...)` into the `.transcript.md` copy).
- So after the owner names a cluster and fixes a sentence, Republish sends the original wording and the raw label in every sink's transcript, while a Regenerate's summary uses the name. The filesystem sink's `signature_sha256` hashes the raw text too, so a correction alone reads as "unchanged" and is skipped as idempotent.

Field evidence: the 2026-11-13 [field evidence report](../../audits/2026-11-13-field-evidence.md) finds no instance: the pack holds no overlay sidecars and the log has no naming or correction events in the window, so this is latent for the owner's current use, not exercised.

Correction at filing: none to the mechanism; the four read sites are exactly as the audit cites. One clarification: the Obsidian sink also uses `transcript_md` for the note's stem and the audio attachment, so the publisher keeps receiving the path and gains the text beside it, rather than the path being replaced.

Related: [STOR9](./STOR9.md) (summarize silently drops an overlay it cannot read; the same fail-open rule must hold here), [PIPE47](./PIPE47.md) (merge drops each fragment's overlays), [PIPE39](./PIPE39.md) (may drop the Notion transcript body; this task still applies to whatever transcript any sink sends), [ARCH21](./ARCH21.md) (lists F107 as an open issue in its schema notes).

## Scope

1. **One publish view, resolved once.** A small helper beside `overlaid_markdown` in `transcript_corrections.py` returns the publish text: `overlaid_markdown(transcript_md)` when it returns text, else `transcript_md.read_text(...)` when the file exists, else empty. `publish_router.fanout` calls it once per run. Pass the result to every publisher as a new keyword (for example `transcript_text: str | None`) on `MeetingPublisher.upsert` in `services.py`, beside the existing `transcript_md`.
2. **Every sink uses it.** `publish_notion._build_blocks`, `ObsidianPublisher`'s body render, `FilesystemPublisher` and `LanPublisher` read the passed text instead of `transcript_md.read_text`. The filesystem and LAN signatures then hash the overlaid text, so a correction republishes instead of reading as unchanged.
3. **Same fail-open rule as summarize.** An unreadable overlay falls back to the raw transcript exactly as `summarize` does today (STOR9 owns making that visible); this task does not add a second policy.
4. `publish_notion.publish`, which calls `NotionRestPublisher.upsert` directly without `fanout`, resolves the same view through the same helper, so no entry point bypasses it; `publish_router.UnavailablePublisher` accepts the new keyword.

## Explicitly not

- Rewriting `<stem>.md` from the overlays (the one-way door FEAT3-UNDO closed on purpose).
- Rewriting names inside the summary prose (README records why: a name substituted in the model's sentences would misstate what it wrote).
- Copy transcript (formatted), which is Swift and already applies the names the app shows.
- Making a missing or corrupt overlay loud: [STOR9](./STOR9.md).

## Acceptance

- New tests, one per sink (`test_publish_notion.py`, `test_publish_obsidian.py`, `test_publish_fs.py`, `test_publish_lan.py`): with a `<stem>.speaker_labels.json` naming a cluster and a `<stem>.transcript_corrections.json` editing one line, the published transcript carries the name and the edited text and not the raw label or old text; with no overlays the output is byte-identical to today's.
- A `test_publish_router.py` test that `fanout` reads the overlays once and hands every publisher the same text; a filesystem-sink test that a correction added after a publish makes the next publish write rather than skip as idempotent.
- The overlay golden fixtures stay the single resolution contract: the new tests build their overlays from `Fixtures/speaker-overlay-golden.json` and `Fixtures/transcript-corrections-golden.json` cases rather than restating the resolution, and CONVENTIONS' cross-tree fixture table names the publishers as readers.
- `cd pipeline && uv run --extra dev pytest -q` green with the new tests counted by the session that writes them; ruff and pyright green; `python3 scripts/truth_fences.py both` green.
- README's Transcript-tab note and [docs/GUIDE.md](../../GUIDE.md)'s naming and correction recipes say, in the same commit, that a Republish carries names and corrections into every destination.

## Amendment 2026-11-21 (second fix review)

Found by the [second fix review](../../audits/2026-11-21-second-fix-review.md) (pipeline report, M1), confirmed by reading the code at `8426758b`.

Scope item 3 says publishing follows the same rule as summarize. That rule changed under it: since STOR9, `summarize.refuse_unreadable_overlays` raises `OverlayUnreadable` ("Nothing was summarized; fix or remove ..."), and `merge_meetings` calls it too. `transcript_corrections.publish_text` still documents "Fail-open exactly as `summarize` is" and returns the raw text (`return overlaid if overlaid is not None else transcript_md.read_text(...)`), pinned by `test_publish_text_falls_back_to_raw_when_an_overlay_cannot_be_read`.

Failure: the owner corrects a line to take a remark out, then `<stem>.transcript_corrections.json` becomes unreadable (a partial write, a hand edit, a sync conflict). A publish-only path (Republish, a Retry of a publish-stage failure, `mp publish`) does not run summarize, so nothing refuses, and every sink receives the raw transcript with the remark in it. The filesystem and LAN signatures change, so the notes are really rewritten.

Scope: `publish_text` (or `publish_router.fanout` before any sink) calls `refuse_unreadable_overlays` and the publish fails with the same named reason. Acceptance: the pinning test is rewritten to expect the refusal, a new test shows no sink is called and `<stem>.publish.json` records the reason, and the summarize and publish messages name the same file. Pipeline suite green, 2 tests changed or added.

**Progress (2026-11-26): amendment shipped.** `publish_text` calls `summarize.refuse_unreadable_overlays(outcome="published", stores=PUBLISH_OVERLAYS)`, so a present but unreadable `<stem>.speaker_labels.json` or `<stem>.transcript_corrections.json` raises `OverlayUnreadable` with summarize's sentence ("Nothing was published" in place of "Nothing was summarized", same file named). `fanout` catches it before any sink: one `log.error` line with the sentence, one failure metadata write (`cause: overlay_unreadable`, `operation: publish`), every resolved sink recorded failed in `<stem>.publish.json` (`state: none`) with a `sink_failed` row carrying `error_type` and `cause` only (OBS3), so every caller exits 3 and Retry republishes. Deliberate narrowing: an unreadable `<stem>.markers.json` does not stop a publish, since flagged moments feed the summary that already exists and no sink reads the file. The pinning test is rewritten to expect the refusal; new tests cover the fanout (no sink called, publish.json, events), `mp publish` (exit 3, the line names the file), the shared wording with summarize, and the markers exclusion; a Swift test pins that `overlayRefusal` reads the clean first line. The owner's live rename + Republish from the original acceptance is still owed.

## Owner walkthrough

1. [session] Confirm the installed build is newer than the landing commit (`./scripts/rebuild.sh` if not).
2. [owner] In the Library, open a meeting already published to Notion or Obsidian, name one speaker on its Transcript tab (and, optionally, correct one line), then Republish. Pass: the Notion page's or Obsidian note's transcript shows the new name (and the corrected line) in place of the raw label. Undo the rename and Republish again if wanted.

Cost: about five minutes, no recording, no live call. Why not a harness: each sink's test runs against a fake publisher or a temp directory; only the real Notion page and the real vault show the names landing as they render there.
