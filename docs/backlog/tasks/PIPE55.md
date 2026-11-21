---
id: PIPE55
title: The Library and the pipeline resolve a meeting's title with opposite precedence, so an in-app rename never reaches a sink
category: Pipeline
status: partial
priority: P2
comment: Shipped 2026-11-18 under the owner's decision (a): user_title, then captured meeting_title, then summary.title in both trees, pinned by title-precedence-golden.json. Library labels change for meetings with a captured window topic (they now show it instead of the summary title). Owner owes one real rename + Republish to a sink; Obsidian reuse relies on PIPE31 (landed) 2026-11-21 second fix review: a rename no longer reaches the digest, actions, Ask's index, the MCP tools or prep (they read summary.title only), and renames made before PIPE55 are outranked by the captured title with no migration; see the amendment.
---

# PIPE55: The Library and the pipeline resolve a meeting's title with opposite precedence, so an in-app rename never reaches a sink

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: F126 in [2026-11-12-independent-audit.md](../../audits/2026-11-12-independent-audit.md) (lens quality, confirmed). Re-verified in code at HEAD `3a2da4fc` on 2026-11-13. No field instance: the field window 2026-09-29 to 2026-11-13 had no title edits or republishes ([2026-11-13-field-evidence.md](../../audits/2026-11-13-field-evidence.md), section Pipeline and publishing).

**Swift: summary title first.** `Meeting.displayTitle` in `MeetingStore.swift` is documented "summary title > meeting title > {source} at HH:mm > raw stem" and returns `summaryTitle` when non-empty. `MeetingDetailView.writeTitle` writes `summary.json["title"]` when a summary exists, else `meta.json["meeting_title"]`. The Summary editor's `titleField` edits the same `summary.title`, which `SummaryTab.persistEdit` writes back.

**Python: captured title first.** `publish_notion.apply_meeting_title` reads `<stem>.meta.json` and, when `meeting_title` is non-empty, returns `summary.model_copy(update={"title": meeting_title[:120]})`. `publish_router.fanout` calls it for every sink (PIPE2/AUD-15 chose this so every sink shows the same title), and the legacy `publish_notion.publish` does too. `meeting_title` is filled at recording start from AX window titles.

**Result.** For any meeting with a captured topic, a rename (or an editor title change) updates the Library but Republish sends the captured topic to Notion, Obsidian and the filesystem sink. The two trees also disagree with no rename at all: the Library shows the model's title while the sinks show the window topic. GUIDE's glossary says "Republishing sends the current version again, which is what you do after editing a summary", which is not true of the title today.

**Correction at filing.** The audit names only the rename; the Summary editor's title field has the same defect, since it also writes only `summary.title`. The audit's second half, a rename over 120 characters failing every later `mp publish`, is [PIPE54](./PIPE54.md)'s and is not repeated here.

**Why neither obvious shortcut works.** Writing the rename into `meta.json["meeting_title"]` would make Python pick it up, but `meeting_title` is also a routing signal: `MeetingLibraryService`'s workflow reassignment calls `recordCorrection(bundleID, existing["meeting_title"] as? String, workflow)` (AI9), and workflow rules can match on the meeting title, so a user's rename would be learned as the window topic. `writeTitle`'s else branch already does this today for a meeting without a summary. Flipping Python to prefer `summary.title` instead would change the title of every published note since PIPE2 on the next republish, and would still let a re-summarize silently undo a rename.

**Obsidian note path.** `ObsidianPublisher._compute_note_path` builds the filename from today's date plus `_slugify(summary.title)` and ignores the `note_path` recorded in `<stem>.obsidian.json`, so once a rename does reach the sink, each rename plus republish would write a second note and orphan the first. [PIPE31](./PIPE31.md) (new) owns reusing the recorded `note_path`; this task depends on it.

Related: [SEC28](./SEC28.md) adds a scrub inside `apply_meeting_title`, which the override must pass through; [ARCH10](./ARCH10.md) owns `writeTitle`'s parse safety; [ARCH21](./ARCH21.md) is the per-meeting file schema spike.

**Owner's decision (2026-11-18, relayed by the parent session): precedence below `user_title` is (a), the spec default: `user_title`, then captured `meeting_title`, then `summary.title`, in both trees.**

## Scope

1. **One user-title key, owned by the rename.** Add `user_title` (string, optional) to `<stem>.meta.json`, written only by the rename. `MeetingDetailView.writeTitle` always writes it there (both branches), through a pure helper beside `MeetingMetaSidecar.reassigned` that preserves every other key, and never touches `meeting_title` or `summary.json`. The Summary editor's title field writes the same key when the title changed, rather than `summary.title`. Clearing the field removes the key, which reverts to the computed title.
2. **Both trees read it first.** `Meeting.displayTitle` returns `user_title` first; `apply_meeting_title` substitutes `user_title` first, before `meeting_title`, through the same 120-character cut and, once [SEC28](./SEC28.md) lands, the same scrub. A re-summarize leaves `user_title` alone, so a rename survives Reprocess and Re-summarize.
3. **One precedence below it, pinned.** Below `user_title`, both trees use the same order. The default is Python's (captured `meeting_title`, then `summary.title`), because every published note since PIPE2 already carries it and the sinks are the durable record; that changes the Library label of meetings with a captured topic. This is the one choice the pickup session confirms with the owner before coding; whichever order is chosen, both trees use it. Pin it in a hand-maintained cross-tree fixture `title-precedence-golden.json` (cases: user title only, all three present, captured plus summary, summary only, none), read by a Swift test against `displayTitle` and a pytest against `apply_meeting_title`, and listed in `CONVENTIONS.md`'s fixture table.
4. **Contract docs.** `user_title` goes into `CONVENTIONS.md`'s sidecar schema table, a `meta-contract/` fixture case, and `test_workflow_overlay.py`, per the sidecar contract.

## Explicitly not

- The title length limit and refusing an over-long rename: [PIPE54](./PIPE54.md).
- Reusing the recorded Obsidian `note_path` and the publish-day date in the filename: [PIPE31](./PIPE31.md). Non-Latin titles slugging to near-empty filenames is a separate field finding in this band.
- Notion page identity across a title change: Notion is matched by its sidecar page id, not by title; F017, F088 and F091 own Notion republish behaviour.
- Scrubbing hostile titles: [SEC28](./SEC28.md).
- Changing what `meeting_title` is captured from, or its use as a routing signal.

## Acceptance

- The fixture tests on both sides pass against `title-precedence-golden.json`.
- A Swift test that `writeTitle` with and without an existing `summary.json` writes `user_title` to `meta.json`, leaves `meeting_title` and `summary.json` byte-identical, and that a workflow reassignment afterwards still records the captured `meeting_title` (AI9) and keeps `user_title` (`MeetingMetaSidecar.reassigned` preserves it).
- A Swift test that an editor save with a changed title writes `user_title` and leaves `summary.title` as generated.
- `pytest`: `fanout` with `meta.json` carrying `meeting_title` and `user_title` hands every sink the user title; with `user_title` absent, behaviour is unchanged from `main`.
- With PIPE31 landed (or its `note_path` reuse carried here if this lands first), a rename plus republish leaves exactly one Obsidian note for the stem, the one `<stem>.obsidian.json` names, carrying the new title.
- `docs/GUIDE.md` says a renamed title is what Republish sends and that a re-summarize keeps it, in the same commit.
- `cd daemon && swift test`, `cd pipeline && uv run --extra dev pytest -q`, ruff and pyright green, with the number of new tests in the commit body; `python3 scripts/truth_fences.py` and `bash scripts/ci-local.sh` green.

## Amendment 2026-11-21 (second fix review)

Found by the [second fix review](../../audits/2026-11-21-second-fix-review.md) (pipeline report, M2), confirmed by reading the code at `8426758b`.

The rename moved out of `summary.json` and five Python readers did not follow. `UserTitleStore.write` (the only writer, used by `MeetingDetailView.writeTitle` and the inline editor) writes `<stem>.meta.json["user_title"]`. In the pipeline only `publish_notion.apply_meeting_title` resolves it (`_TITLE_KEYS = ("user_title", "meeting_title")`), which is what the sinks use. `digest`, `actions`, `embed_index._read_title`, `prep` and `mcp_tools` still read `summary.get("title")`.

Failure 1, a regression on those surfaces: a meeting renamed in the Library after PIPE55 landed shows the rename on its row and in every sink, while the weekly digest, `mp actions`, Ask citations, the MCP tools and the prep card show the generated title. Before PIPE55 they showed the rename, because it lived in `summary.title`.

Failure 2, no migration: a meeting renamed before PIPE55 keeps its rename in `summary.title`, which now ranks below the captured `meeting_title`, so its Library label reverts to the window topic.

Scope: one Python title resolver with the `apply_meeting_title` precedence, moved out of `publish_notion` and used by the five readers; then an owner decision on migrating a `summary.title` that differs from the generated one into `user_title` (the correction record can tell an edited title from a generated one). Acceptance: one table-driven test per reader with a `user_title` in the sidecar, and a migration test if the owner takes it. Pipeline suite green, 5 new tests or more.
