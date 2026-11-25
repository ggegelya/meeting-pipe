---
id: PIPE55
title: The Library and the pipeline resolve a meeting's title with opposite precedence, so an in-app rename never reaches a sink
category: Pipeline
status: partial
priority: P2
comment: 2026-11-26 amendment first half shipped: titles.resolve (promoted from publish_notion._TITLE_KEYS) is read by the sinks, digest, actions, Ask's index (.meta.json now a fingerprint source), mp prep and the MCP tools, and the Swift Last time card matches; remaining is the owner-decided migration of pre-PIPE55 renames from summary.title into user_title, held on an owner question about the signal (see Progress 2026-11-26).
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

**Owner's decision (2026-11-25, relayed by the parent session): do both halves.** (1) One shared Python title resolver, moved out of `publish_notion._TITLE_KEYS`, used by `digest`, `actions`, `embed_index._read_title`, `prep` and `mcp_tools`. (2) Migrate old renames: a rename an older build stored in `summary.title` moves into `user_title`, idempotent, never losing a title, keeping the model-written title recoverable, atomic per file, with where it runs decided by the repo's migration precedent and the old-rename signal grounded in data the files carry (stop and ask if none is reliable).

**Progress (2026-11-26): half (1) shipped, half (2) held on a question.** `mp/titles.py` (`TITLE_KEYS`, `sidecar_title`, `resolve`) is the one rule; `apply_meeting_title` is a thin wrapper over it, and the five readers call `titles.resolve(meta, summary.get("title")) or stem`, reusing the meta read they already made where they had one (`actions`, `mcp_tools`, `prep.candidates`). `.meta.json` joined `embed_index.STEM_SOURCE_SUFFIXES` and `library_fingerprint`, since Ask stores a chunk's title at index time and a rename would otherwise never reach a citation. Not in the amendment: the Swift "Last time" card (`PrepCard`), `mp prep`'s independent mirror, read `summary.title` too, so it now resolves the same order (`PrepCard.sidecarTitle`) rather than disagreeing with `mp prep`. Behaviour change beyond renames, which the amendment implies: a meeting with a captured `meeting_title` and no rename now carries the captured title on all five surfaces (the digest's per-meeting action group key included), as the Library and the sinks already did. Tests: `test_title_readers.py` (one table of 5 cases through all five readers, an unreadable-sidecar fallback per reader, a scrub check, and the rename-invalidates-the-index check; 31 cases, 16 red against the old readers), the golden pinned against `titles.resolve` too, and a Swift prep-card case table.

The migration is held because the spec's premise is only half true. The correction record (`~/Library/Application Support/MeetingPipe/corrections/<stem>.json`, `original_summary.title` against `corrected_summary.title`) exists only for Summary-editor saves. The pre-PIPE55 header rename (`MeetingDetailView.writeTitle` before `ff4c8a3b`) wrote `summary.json["title"]` and nothing else: no record, only a `library/title_edited` event, and the event log rotates (the owner's retained log starts 2026-10-12 and holds none). The one signal that covers both paths is `<stem>.summary.md`'s `# ` heading, which every summarizer renders from the generated title and neither old rename path rewrote, but it is a heuristic with known false positives: a pasted summary keeps its `.summary.md` as pasted while `summary.json` carries the parsed, 120-cut title (PIPE50), and an Apple Intelligence run whose Markdown write failed leaves a stale heading. A false positive pins a generated title as a rename that then outranks the captured title and survives every re-summarize. A pre-PIPE55 rename of a meeting with no summary went into `meeting_title` and cannot be told from a captured topic at all. Census of the owner's library on 2026-11-26 (counts only): 3 summaries, 0 correction records (the directory exists and is empty), 0 heading mismatches, 0 `title_edited` events, no `user_title` or `meeting_title` on any of them, so every candidate signal finds nothing to migrate today; only an older backup restored later could carry one. Where it would run, if taken: a Swift one-shot from `App.swift`'s launch path, the precedent every migration here follows (`LegacyConsentMigration`, `SecretsStore.migrateEnvFileIfPresent`, `WorkflowMigrator`), writing through `UserTitleStore` (the one writer of the key, which refuses over an unreadable sidecar, SEC25) and then restoring `summary.title` to the generated title, so the model's title stays in `summary.json` and the correction record or heading it came from. Owner question: correction-record signal only (misses header renames), the heading signal with paste and stale-heading exclusions, or close the migration given the census.
