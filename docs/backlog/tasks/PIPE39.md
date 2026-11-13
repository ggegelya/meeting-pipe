---
id: PIPE39
title: Notion gets a note once: replace wipe-and-append republish with an appended dated revision, stop uploading the full transcript, and remove the LAN sink
category: Pipeline
status: new
priority: P2
comment: Filed 2026-11-13 (product-direction band, idea I43, 14.00 of 20): a Notion republish deletes every block on the page then appends without retry (F017, F088 high), rewrites Date and Status on every update, and uploads the whole transcript, which contradicts SETUP's claim that only the summarizer sees it (G032). Alternative remedy to the F017 and F088 defect fixes, so decide before repairing. A 3-day owner-run count (R updates, H hand-edited pages, T transcript share) pre-registers GO (appended revision, transcript dropped at T 70%) or NO-GO (retry the append instead). LAN sink needs no probe. Child of [EPIC4](./EPIC4.md).
---

# PIPE39: Notion gets a note once

Band origin: filed 2026-11-13 from the product-direction band ([report](../../research/2026-11-12-product-direction.md), idea I43, "Notion gets a note once: delete the rewrite path and the transcript upload, and drop the LAN sink"). Child of epic [EPIC4](./EPIC4.md). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context, verified 2026-11-13

- `pipeline/src/mp/publish_notion.py` (774 lines, 795 test lines beside it): republish runs parallel block deletes, then an append that is deliberately not retried. The 2026-11-12 [audit](../../audits/2026-11-12-independent-audit.md): F017 and F088 (high), F091 (a failure leaves a wiped page), G032 (SETUP says only the summarizer sees the transcript while the default Notion sink uploads it), and G034 gets simpler to state. These are being filed as defect tasks by the parallel 2026-11-13 audit filing (search the backlog for the finding ID); this task is the alternative remedy, so it is decided before they are repaired in place. It does not fix F107 (all four publishers ignore the Library's overlays).
- **Field evidence (2026-11-13).** In the [field pack](../../audits/2026-11-13-field-evidence.md) Notion was last used in 2026-07: all 74 recordings from 2026-09-29 to 2026-11-13 published one Obsidian note each, so F017, F088 and F091 had no chance to occur in that window. Notion is the configured default sink but not the owner's daily path today. The probe therefore reads historical pages (R and H over everything the integration created); if H is 0 and the sink stays unused, the cheaper subtraction may be the sink itself, which goes to [FEAT22](./FEAT22.md)'s witness rule rather than this task.
- FEAT21 records republish as today's routine repair for unnamed speakers, so the destructive path is exercised, not theoretical. The tests-python slice notes the republish is checked by key names only, so the replaced behaviour needs a real assertion first.
- What changed since FEAT18 kept the Notion sink out of scope: this keeps the sink and cuts its rewrite path and transcript upload, which no task proposes; Notion rebuilt its MCP on 2026-10-19 so outside agents can write into it, making a bespoke two-way sync less necessary.
- The LAN sink: FEAT18 leans Cut and records `[lan] host` empty on this Mac (`pipeline/src/mp/publish_lan.py`). It is removed here unless [FEAT22](./FEAT22.md) step 1 has already removed it.

## Pre-registered probe (copied from the report; owner-run, read-only, counts only, 3 days)

From `.publish.json` files and `publisher` rows: R = share of Notion publishes that updated an existing page. One read-only Notion API query of the target database: H = pages last edited by a person after the integration created them. From the block fixtures or one sampled page: T = share of a page's blocks that are transcript.

| Verdict | Measured | Next |
|---|---|---|
| **GO** | H at least 1 OR R at least 10% | Replace wipe-and-append with an appended dated revision under the existing page; stop sending Date and Status after creation; drop the transcript body if T is at least 70% (the page carries the summary plus a deep link to the exact second in the local library) |
| **NO-GO** | H is 0 across at least 50 pages | The wipe has nothing of the owner's to destroy; a retry on the append is the cheaper fix, done in the F017 defect task |

## Scope (whichever verdict)

- First, pin today's republish behaviour with a real assertion (blocks deleted, blocks appended, properties sent), so the change is measured against intent rather than key names.
- The `<stem>.publish.json` result and the exit-3 all-sinks-failed contract are unchanged (CONVENTIONS, publish result).
- LAN sink removal: `publish_lan.py`, its config keys, Preferences row, GUIDE recipe and tests in one commit; the config truth fence stays green.

## Explicitly not

- Removing the Notion sink here (it is the default sink and on both earlier audits' keep lists; removal, if the field disuse holds, is a FEAT22 witness decision).
- Fixing F107 here.
- A two-way Notion sync.

## Owner walkthrough

The H query reads a remote system, so the owner runs it (command written into the spike note, read-only, prints a count). The owner also answers one question before any change: do they read transcripts in Notion? A yes keeps the transcript body regardless of T.

## Acceptance

- The count script (R and T local; H the owner's one query) and a dated verdict recorded here.
- On GO: the appended-revision republish with tests (republish appends a dated revision and deletes nothing; Date and Status sent only on create; transcript omitted when configured; a failed append leaves the page intact), `uv run --extra dev pytest -q` green with the new tests counted by the session that writes them, ruff and pyright green, [docs/SETUP.md](../../SETUP.md) and [docs/GUIDE.md](../../GUIDE.md) updated in the same commit so G032's sentence becomes true.
