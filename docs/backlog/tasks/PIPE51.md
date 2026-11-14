---
id: PIPE51
title: All four publishers send the raw transcript, so speaker names and text corrections made in the Library never reach Notion, Obsidian, the filesystem or LAN
category: Pipeline
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). Speaker names and line edits live only in the Swift-written overlays; summarize, embed_index and MCP read through transcript_corrections.overlaid_markdown, but the Notion, Obsidian, filesystem and LAN publishers read `<stem>.md` directly, so a Republish keeps the old words and raw labels beside a summary that uses the names (F107; FEAT3-SEGMENT's republish acceptance does not hold for the published transcript; no overlay sidecars in the field window). One publish view of the transcript resolved in fanout and handed to every sink, pinned by a test per sink.
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
