---
id: FEAT22
title: Flip the default on secondary surfaces: delete the ones the record already condemns, and give the rest 14 days to show use in a local-only witness row
category: Feature
status: new
priority: P2
comment: Filed 2026-11-13 (product-direction band, idea I42, 14.67 of 20, picked by codebase-engineer and owner-advocate): FEAT18's per-surface decision table has waited since 2026-10-24 while the audit found verified defects inside the undecided surfaces (F014 high in series continuity). Replaces the opinion with a rule: immediate cuts on recorded evidence, then a surface_opened row written only to the local event log and a day-15 count with pre-registered keep, Experimental or delete thresholds. People rail and self-voiceprint exempt, Tutorial left out (owner decision 2026-08-18). Supersedes FEAT18's method; FEAT18 not edited. Child of [EPIC4](./EPIC4.md).
---

# FEAT22: delete secondary surfaces on a date unless a local witness shows use

Band origin: filed 2026-11-13 from the product-direction band ([report](../../research/2026-11-12-product-direction.md), idea I42, "Flip the default on the secondary surfaces: deleted on a date unless a local witness shows use"). Child of epic [EPIC4](./EPIC4.md). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context and what changed

[FEAT18](./FEAT18.md) (P2, filed 2026-10-24) holds a decision table, one row per secondary surface with dedicated LOC, evidence of use and the audits' lean, and nothing has been decided. What changed: the 2026-11-12 [audit](../../audits/2026-11-12-independent-audit.md) found verified defects inside the undecided surfaces (F014 high: series continuity, `_prior_meeting_context` in `pipeline/src/mp/summarize.py`, sends a withheld meeting's content to the cloud; G035 a tutorial step pointing at an unrendered control; G015, F047 and F075; conditionally F046, F019 and F099 in resume and merge), so waiting now has a measured cost. The new content is the default flip and the witness, not the table. [DV5](./DV5.md) has Remove pre-registered for the Facts rail; [CAL3](./CAL3.md) found the workflow series key wrong, and the owner called the "Previous meeting" recap senseless on 2026-07-27. FEAT18 is referenced, not amended; its decision table is the inventory this task acts on.

## Scope

**Step 1, immediate cuts on evidence already recorded** (one delete commit per surface, each one revert away): series continuity (removes F014 with it), the prep card, the Facts rail (executes DV5's Remove), App Intents (built but not invocable, deferred behind D8), the LAN sink (`[lan] host` empty on this Mac per FEAT18; `pipeline/src/mp/publish_lan.py`). Each delete removes its Preferences rows, [docs/GUIDE.md](../../GUIDE.md) recipes and tutorial anchors in the same commit, and closes the tasks it makes moot with a one-line reason, after confirming each one really depends only on the deleted surface. The report names UX74, UX75, CAL3, DV5, AUTO1 and the audit's G035; at filing UX74 (mtime durations, partial) reaches beyond the Meeting time view, so it is checked rather than assumed, and AUTO1 (App Intents plus the URL scheme, deferred) keeps its URL-scheme half.

Field evidence (2026-11-13): with one workflow for everything, the series-continuity block is in nearly every summarize request and keys on the previous meeting, not a series ([field pack](../../audits/2026-11-13-field-evidence.md)); no withheld meeting exists in the pack, so F014 had no instance there, but the block's cost is real on every run.

**Step 2, the witness (day 1).** One `library` action, `surface_opened`, with a `surface` attribute, emitted on a deliberate open of Digests, Meeting time and the Guide reader, and of People for information only (exempt from the thresholds below); written to `events.jsonl` on this Mac and nowhere else, documented in CONVENTIONS' event schema so the CI5 events fence accepts it.

**Step 3, the count (day 15, owner-run, counts only, residue-filtered through `mp.events.drop_test_residue`).** Pre-registered, copied from the report:

| Opens in 14 days | Result |
|---|---|
| Fewer than 3 | The surface gets its delete commit |
| 3 to 9 | Behind the Experimental switch |
| 10 or more | Stays |

Resume-after-end and merge are deleted if `recording_resumed_after_end` plus `meetings_merged` total fewer than 3 real rows across all retained generations. **The idea fails as a whole** if more than half of the witnessed surfaces score 10 or more; then FEAT18's table decides the rest by owner opinion as before.

## Exemptions (judge corrections carried)

- People rail: exempt (the voice-census epic feeds it, and other people's commitments live there).
- Self-voiceprint: load-bearing, exempt.
- Tutorial: left out entirely; its scope was a deliberate owner decision on 2026-08-18 (root CLAUDE.md carve-out), and reversing it is the owner's call, not a count's.

## Explicitly not

- Any telemetry: the witness row never leaves the Mac, is never uploaded, and is not readable by any sink or the MCP server.
- The CLI-only dev subcommands; [PIPE20](./PIPE20.md) owns their delete-or-verdict call.
- Cutting the Notion, Obsidian or filesystem sinks (FEAT18 keeps them out of scope; Notion's rewrite path is [PIPE39](./PIPE39.md)).
- A 14-day count missing a monthly habit (a digest) is the known risk: every cut stays one revert away.

## Owner walkthrough

Approve the step-1 cut list (one line), use the app normally for 14 days, then run the day-15 count command (written into this file's progress note) and read the per-surface verdict lines.

## Acceptance

- Step 1: one commit per surface; `bash scripts/ci-local.sh` green after each; truth fences green (config knobs, event categories, dead links).
- Step 2: the `surface_opened` emission with tests (emitted on deliberate open only, never on restore-at-launch; written only to the local log), CONVENTIONS event schema updated, `swift test` green.
- Step 3: the count script with a test on synthetic rows including test residue; the dated verdict and the resulting delete or Experimental commits recorded here.
