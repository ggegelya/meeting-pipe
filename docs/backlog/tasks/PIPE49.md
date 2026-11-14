---
id: PIPE49
title: A Notion republish deletes every block on the page, owner-added ones included, and then appends the new body with no retry
category: Pipeline
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). publish_notion._update_page deletes every top-level block on the page (owner notes and to-dos included) and then appends the new body once with no retry, so a rate-limited append leaves the page empty until a later publish (F017); Notion was last used in 2026-07, so not exercised in the field window. Decide [PIPE39](./PIPE39.md) first; if this path stays, append first, delete only the pipeline's own previous blocks (ids recorded in `<stem>.notion.json`), and retry the append on 429 only.
---

# PIPE49: A Notion republish deletes every block on the page, owner-added ones included, and then appends the new body with no retry

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: the 2026-11-12 [independent audit](../../audits/2026-11-12-independent-audit.md), finding F017 ("Notion republish deletes every block on the page, then appends the new body without retry"), lens data, high, confirmed by both verifiers, backlog New. The audit's author re-read F017 in source at HEAD `4949c9c0`, and a MockTransport run reproduced it (properties patched, both blocks deleted including one standing in for an owner note, one append attempt on 429, exception raised).

Re-verified in code at HEAD `3a2da4fc` on 2026-11-14. `NotionRestPublisher.upsert` takes the update branch whenever `<stem>.notion.json` carries a `page_id`, and `_update_page` then does three things in order:

1. PATCHes the page properties through `_request_retrying` (idempotent, retried).
2. Lists every top-level child through `_fetch_all_child_ids` and deletes all of them in parallel (`ThreadPoolExecutor(max_workers=8)`, each `_request_retrying(client, "DELETE", f"/blocks/{bid}")`). There is no authorship filter: a block the owner typed into the page in Notion is deleted exactly like a block the pipeline wrote. The function's own comment says it: "Wipe existing children and replace. Notion has no atomic 'replace children' call, so we delete and re-append."
3. Appends the new body in 100-block chunks through `_request_once`, which never retries. That is deliberate and correct for 5xx: the docstring records the 2026-05-11 duplicate-page bug, where a 502 came back after Notion had committed, and a retried append would double the body. But `_do_request` raises on 429 the same way it does on 5xx, so a rate limit on the append, right after a burst of up to eight parallel DELETEs, also fails without a retry.

What the owner loses: (a) deterministically, on every republish, any block they added to the page in Notion; (b) if the append fails after the deletes, the whole body until the next successful publish. The verifiers' refinement holds and is kept here: (b) is not silent or permanent, since the sink is recorded as failed (exit 3 when Notion is the only sink, PIPE1), the old sidecar keeps `page_id`, and the next publish re-runs the update path and restores the body from the local summary. The 429-after-burst trigger is inferred from Notion's documented limits, not demonstrated against live Notion. The deterministic leg is (a).

Why it matters: README's batch-pane paragraph draws the confirm line at "whether the action destroys something you wrote by hand", and on that rule **Republish all** does not confirm, so the docs read as a promise that republish destroys nothing hand-written. Republish is reached from Republish, Republish all, Regenerate (which chains into publish), merge and Retry, and FEAT21 records republish as the routine repair for unnamed speakers.

Field evidence: the 2026-11-13 [field evidence report](../../audits/2026-11-13-field-evidence.md) rates F017 "cannot tell". The Notion sink ran from 2026-05-18 to 2026-07-31 (117 `sink_completed` over 53 meetings, 60 `sink_failed` inflated by test rows, 2 meetings where a failure followed an earlier success) and has had 0 publishes since; all 74 recordings from 2026-09-29 to 2026-11-13 published to Obsidian only. Notion is still the configured default sink.

Correction at filing: none to the mechanism. Two narrowings. Retrying the append on 5xx stays wrong (it is the 2026-05-11 duplicate bug); only 429, which Notion returns before doing the write, is safe to retry. And a tick the owner places on a to-do the pipeline created (`_action_block` writes `to_do` with `checked: resolved`) is on a pipeline-owned block, so the ownership fix below protects owner-added blocks but still resets that tick to the local `resolved` flag; that is the two-way-sync question, named under Explicitly not.

Order with [PIPE39](./PIPE39.md) (filed 2026-11-13, product-direction band): PIPE39 is the alternative remedy, an appended dated revision that deletes nothing, gated on an owner-run count of hand-edited pages. Its NO-GO row ("H is 0 across at least 50 pages") hands the cheaper fix to this task. Decide PIPE39 first: on its GO this task closes as superseded; on NO-GO, or if PIPE39 is parked, this task is the fix.

Related: [PIPE23](./PIPE23.md) (same publisher: duplicate page on a failed create, a page deleted in Notion, Date and Status reset on update, and its 2026-11-13 amendment on the claimed slug identity); [DOC20](./DOC20.md) (docs that state guarantees the code does not keep).

## Scope

All in `pipeline/src/mp/publish_notion.py`, only if PIPE39 has not replaced this path.

1. **Record what the pipeline owns.** `_update_page` and `_create_page` collect the ids of the top-level blocks they append (the append response's `results`, and for a create, one children listing right after the POST), and `NotionRestPublisher.upsert` writes them into `<stem>.notion.json` as `block_ids` beside `page_id`. Bump that sidecar's `schema_version` and document the key in CONVENTIONS' sidecar section.
2. **Append first, then delete only the previous pipeline blocks.** `_update_page` appends the new body, and only after every chunk has landed deletes the ids in the previous sidecar's `block_ids`. A block not in that list is never deleted. A failed append leaves the old body in place (the page reads twice, old then partial new, rather than empty), and the sidecar is not rewritten, so the next publish still knows the old ids; the partial new chunk is orphaned and named in the failure reason.
3. **Legacy sidecars with no `block_ids`.** Do not fall back to delete-all. Either delete only children whose `created_by` is this integration's bot user (from `GET /v1/users/me`; confirm the field is present at the pinned `NOTION_API_VERSION`) or, if that cannot be established, append and delete nothing, logging that the old body was left in place. The pickup session picks one and states why in the commit.
4. **Retry 429 on the append, and only 429.** A small wrapper around the append that retries on `HTTPStatusError` with status 429 (honouring `Retry-After` when present, bounded attempts), leaving `_request_once` and its 5xx no-retry rule untouched.
5. Emit a `publisher` event when the update path leaves blocks it does not own (count only) and when a legacy sidecar falls back, so the field log can see it; add the actions to CONVENTIONS' event table.

## Explicitly not

- The appended dated revision, dropping Date and Status on update, and dropping the transcript body: [PIPE39](./PIPE39.md).
- The duplicate page on a failed create, a page deleted in Notion, Date and Status reset, and the doctor schema check: [PIPE23](./PIPE23.md).
- Two-way sync of to-do ticks made in Notion back into the local `resolved` flag (PIPE39's Explicitly not rules a two-way Notion sync out).
- Retrying the append on 5xx or a transport error (the 2026-05-11 duplicate-body bug).
- The overlays the published transcript ignores: [PIPE51](./PIPE51.md).

## Acceptance

- New mock-transport tests in `pipeline/tests/test_publish_notion.py`: a republish where the page holds the pipeline's two recorded blocks plus one owner-added block deletes only the two and leaves the owner block; the append happens before any DELETE (assert request order); a 429 on the first append chunk followed by 200 is retried and the old blocks are deleted only after it lands; a 502 on the append is not retried, no DELETE is sent, and the sidecar keeps the previous `block_ids`; a legacy sidecar with no `block_ids` never deletes a block the chosen fallback does not own; create and update both write `block_ids` into the sidecar.
- `test_update_deletes_all_children_in_parallel` and `test_update_paginates_existing_children` are rewritten to the ownership rule rather than deleted; `test_post_pages_does_not_retry_on_502` and `test_patch_pages_still_retries_on_502` stay green unchanged.
- `cd pipeline && uv run --extra dev pytest -q` green with the new tests counted by the session that writes them; `uv run --extra dev ruff check src tests` and `uv run --extra dev --extra mcp pyright` green; `python3 scripts/truth_fences.py both` green after the CONVENTIONS sidecar and event rows are added.
