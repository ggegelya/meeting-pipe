---
id: PIPE50
title: Publish from paste rewrites the user's pasted summary with a lossy re-render before any sink runs, so prose it cannot parse is replaced by a placeholder
category: Pipeline
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). publish_from_paste keeps only what parse_summary_md recognises (bullets under known H2s, ten summary bullets, a 120-char title) and overwrites the pasted `<stem>.summary.md` and `.summary.json` before fanout, so prose under ## Summary becomes the placeholder bullet in the file and every sink (F016); last used 2026-06-09 (55 paste requests 2026-05-28 to 06-09). Leave the pasted file byte-identical, refuse when a filled section parses empty, write summary.json atomically.
---

# PIPE50: Publish from paste rewrites the user's pasted summary with a lossy re-render before any sink runs, so prose it cannot parse is replaced by a placeholder

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: the 2026-11-12 [independent audit](../../audits/2026-11-12-independent-audit.md), finding F016 ("publish-from-paste overwrites the pasted summary.md with a lossy re-render before publishing"), lens data, high, confirmed by both verifiers, backlog New. The verifiers ran the real `parse_summary_md` plus `render_summary_md` on a scratch sample: a 201-char input with prose under `## Summary` rendered to 130 chars holding only the placeholder bullet plus its one Decisions bullet; a 377-char input with nested bullets, H3 prose, unchecked action bullets, a prose Next Steps section and a table rendered to 84 chars; 12 summary bullets rendered as 10.

Re-verified in code at HEAD `3a2da4fc` on 2026-11-14:

- The Swift side (`MeetingLibraryService.publishFromPaste`, reached from the Summary tab's paste box Save & publish) writes the pasted text atomically to `<stem>.summary.md` and spawns `mp publish-from-paste <stem>.md`.
- `publish_from_paste.publish_from_paste` reads that file, runs `parse_summary_md`, and, unless regulated mode is on, writes `summary_json_path.write_text(summary.model_dump_json(...))` and then `summary_md_path.write_text(render_summary_md(summary, deeplink_stem(transcript_md)), ...)` before calling `fanout`. Both are plain `write_text`, not `storage.atomic_write_text`, although `summarize` writes the same two files atomically.
- `parse_summary_md` keeps: the first H1 truncated to 120 chars, `- ` or `* ` bullets under the known H2s (`_extract_bullets` uses `_BULLET`), at most ten summary bullets, and `[ ]`/`[x]` to-do lines under Action Items. Prose under `## Summary` matches no bullet, so `summary_bullets` is empty and becomes the single placeholder bullet that begins "(no summary section detected". Its own docstring says "Anything we can't parse is dropped silently". Unknown H2 sections with bullets survive as `extra_sections` (WF7), so the audit's claim slightly understates what is kept.
- The comment above the re-render says it "preserves user content but drops whatever ad-hoc styling the LLM produced", which the parser does not do.
- Tests pin the overwrite: `test_publish_from_paste_round_trip` asserts the re-rendered `.summary.md` carries `## Summary` and `## Action Items`, and `test_parse_handles_minimal_markdown` pins the placeholder. Only `test_publish_from_paste_regulated_mode_preserves_user_md` keeps the user's file, and its docstring concedes that overwriting "would silently destroy editorial content".
- `<stem>.summary.md` is not only a publish input: `embed_index` reads it for the Ask index and `MeetingDragItem` drags it, so the lossy file is what the rest of the app sees afterwards.

Reachability: the paste box is the documented flow for BYO meetings and for cloud transcripts over `skip_above_chars` (80000), and the bundled prompt asks for a tool call, not a Markdown shape, so a frontend's natural prose output is the common case rather than an edge.

Field evidence: the 2026-11-13 [field evidence report](../../audits/2026-11-13-field-evidence.md) rates F016 "cannot tell": `publish-from-paste requested` appears 55 times in daemon.log from 2026-05-28 to 2026-06-09 and none since, and no files from then are in the pack.

Correction at filing: none to the mechanism. One refinement: the pasted source text usually survives in the frontend the owner copied it from, so the loss is the on-disk file and every published copy, not necessarily the only copy anywhere. A second refinement: [HYG18](./HYG18.md) already lists that placeholder as a published placeholder line; this task does not change its wording, it only makes the prose case refuse instead of reaching it.

Related: [PIPE30](./PIPE30.md) (the ten hand-rolled atomic writers; it lists this module's non-atomic writes, so whichever lands first fixes them and the other drops the item), [HYG18](./HYG18.md) (placeholder wording), [OBS3](./OBS3.md) (`publish_from_paste.main` logs a failure with no event; its `command_failed` helper is what the refusal below should go through once it lands), WF7 (done, archived in [q6-final.md](../q6-final.md); kept non-standard H2 bullets).

## Scope

All in `pipeline/src/mp/publish_from_paste.py`, with the Swift side unchanged except for the error text it already shows inline.

1. **Never rewrite the pasted file.** Drop the `summary_md_path.write_text(render_summary_md(...))` step. `<stem>.summary.md` stays exactly what the owner pasted, so the Ask index and drag-out keep the full text; `<stem>.summary.json` carries the parsed form every sink renders from. Update the misleading comment.
2. **Refuse a lossy parse instead of publishing a placeholder.** Before writing anything, if a known section heading is present with non-whitespace content but parses to nothing (prose under `## Summary`, prose under `## Decisions`, untickable lines under `## Action Items`), raise a `ValueError` whose message names the section and the shape it expects (one bullet per line, `- [ ] **Owner**: task` for actions). `main` already exits 1 on it and the paste box shows the reason inline. The placeholder stays only for a paste with no `## Summary` heading at all, which is today's minimal-markdown case.
3. **Say what was cut.** When the parse truncates (title over 120 chars, more than ten summary bullets), log it and emit one `pipeline` event with the counts, so a trimmed publish is visible rather than silent.
4. **Atomic write.** `summary.json` goes through `storage.atomic_write_text`, matching `summarize`.

## Explicitly not

- Teaching the parser prose, tables or H3 structure (a richer parser is a bigger, separate decision; refusing is the smallest honest fix).
- The other nine hand-rolled writers and the 0600 chmod: [PIPE30](./PIPE30.md).
- Rewording the placeholder or removing its em-dash: [HYG18](./HYG18.md).
- Changing the regulated-mode branch, which already preserves the file and skips publish.

## Acceptance

- New tests in `pipeline/tests/test_publish_from_paste.py`: a paste with prose under `## Summary` raises before any write, leaves `.summary.md` byte-identical, writes no `.summary.json` and calls no sink; a paste with well-formed bullets publishes and leaves `.summary.md` byte-identical while `.summary.json` holds the parsed form; a paste with twelve summary bullets publishes ten and emits the truncation event with the counts; `main` on the prose case exits 1 with the section name in the logged error.
- `test_publish_from_paste_round_trip` is rewritten to assert the pasted file is unchanged rather than re-rendered; `test_parse_handles_minimal_markdown`, the regulated-mode test and the fanout and exit-3 tests stay green.
- `cd pipeline && uv run --extra dev pytest -q` green with the new tests counted by the session that writes them; ruff and pyright green; the event row added to CONVENTIONS keeps `python3 scripts/truth_fences.py both` green.
- [docs/GUIDE.md](../../GUIDE.md) and README's paste-box sentence say, in the same commit, that the pasted summary needs one bullet per line under its headings and that a paste the app cannot read is refused with the reason.
