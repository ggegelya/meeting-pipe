# FEAT18: about one tenth of the production code serves secondary surfaces, and the owner has not decided which of them to keep, hide or delete

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) B1, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) SA-11 and its "Maintainability and process" section). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

The core job is record, transcribe, label, summarize, publish. The architecture review counts about 10k LOC (about 11% of production code) on surfaces outside it, and the go-live assessment recommends cutting or hiding several, keeping Ask, search, People and the roster, the Notion, Obsidian and filesystem sinks, workflows, the MCP server and the URL scheme. Every surface below costs on every change: tests to keep green, Preferences rows, GUIDE recipes the same-commit contract maintains, tutorial anchors, and context a session reads.

This task is a decision, not an implementation. It is filed so the owner makes it once, per surface, with the numbers in one place.

## The decision table

LOC is measured 2026-10-24 over each surface's **dedicated files only** (`wc -l`, comments included), so it is the floor a deletion removes. The audit's figures are larger because they also count touch points in shared files (`LibraryWindow`, `LibrarySidebar`, Preferences, config). Production code is 91,456 lines across `daemon/Sources` and `pipeline/src`.

| Surface | Dedicated files | LOC src / tests | Evidence of use | Open tasks it touches | Audit lean | Owner decision |
|---|---|---|---|---|---|---|
| Digests | `DigestsView`, `DigestNarration`, `DigestSchedulerService`, `digest.py` | 1,022 / 707 | Owner read a digest closely enough on 2026-08-04 to file its rendering bug with screenshots ([UX75](./UX75.md)) | UX75 | Experimental | |
| Meeting time (stats) | `MeetingStats`, `StatsView` | 685 / 555 | Owner reported its totals as impossible on 2026-08-04 ([UX74](./UX74.md), P1) | UX74 (durations everywhere, not only here) | Experimental | |
| Tutorial | `Tutorial/` (5 files) | 923 / 502 | Owner approved it on 2026-08-18 as a deliberate scope reversal ([FEAT15](./FEAT15.md)); awaiting owner verification | FEAT15 | Arch review lists it; go-live does not | |
| In-app Guide reader | `GuideDocument`, `GuideView`, `GuideWindow` | 762 / 392 | Shipped 2026-08-04 with DOC11; no usage signal exists | [PERF13](./PERF13.md) (Guide window main-thread cost) | Arch review lists it; cheaper option: open `GUIDE.md` in the default app | |
| Prep card | `PrepCard`, `PrepCardView`, `prep.py` | 822 / 752 | CAL2 shipped at P3; CAL3's follow-up is deferred because the owner has not had enough team calls to measure the premise | [CAL3](./CAL3.md) (P3) | Cut | |
| Facts rail | `Facts`, `FactsView` | 441 / 284 | Owner's 2026-08-04 note: "facts is barely useful ... or remove it"; 16 of 1,374 actions ever resolved (1.2%), measured for DV5 on 2026-08-10 | [DV5](./DV5.md) | Cut | |
| Self-voiceprint | `VoiceprintProfile`, `voiceprint.py` | 135 / 122 | Load-bearing: `match_voiceprint` identifies "me" on mono and merged recordings where the mic-channel trick cannot; this Mac's profile has learned from 2 meetings | [SEC24](./SEC24.md), [SEC22](./SEC22.md), [FEAT19](./FEAT19.md) | Arch review lists it | |
| Native App Intents | `Automation/MeetingPipeAppIntents.swift` | 215 / 72 | Cannot run on any build the owner has: `daemon/CLAUDE.md` says not to make them run ad-hoc-signed, and AUTO1 is deferred until a Developer ID, which the selling rule defers. Zero possible use | [AUTO1](./AUTO1.md) (P3), [AUTO7](./AUTO7.md) | Cut | |
| LAN sink | `publish_lan.py`, the `lan` case of `PublishTarget`, `[lan]` config | 156 / 267 | Not configured on this Mac (`[lan] host = ""`); the owner's work laptop was not inspected. It writes to an already-mounted SMB or NFS share; there is no server | none | Cut | |

Not in the table: Ask/RAG (`ask.py`, `rag.py`, `embed_index.py`, 1,288 lines plus `AskView`) and the MCP server (925 lines), which both audits call used and recommend keeping; the staged summarizer and dev subcommands ([PIPE20](./PIPE20.md)); the Swift Apple Intelligence engine ([ARCH11](./ARCH11.md)).

## What each option costs

- **Keep**: nothing changes. The row stays in the maintenance budget.
- **Experimental**: one `UISettings` switch (Preferences, Advanced) hides the surface's entry points. It saves UI surface and GUIDE prominence only: the code still compiles, its tests still run, and every change still has to keep it green. Choose it for a surface the owner wants to keep trying, not to save maintenance.
- **Delete**: one commit per surface removes its files, tests, Preferences rows, config keys, menu items, GUIDE recipe, README lines and ARCHITECTURE rows. Git keeps it; a revert restores it.

## Scope (after the owner fills the last column)

- One commit per deleted surface, in the order the owner lists them. If any row is Experimental, the switch lands with the first such commit and later surfaces reuse it.
- Self-voiceprint is not a clean delete: removing it changes speaker labelling, so a Delete there needs its own replacement plan and goes back to the owner.
- A deleted surface that the tutorial rings updates the tour in the same commit (the `daemon/CLAUDE.md` tour rule); deleting the Guide reader also updates the root `CLAUDE.md` DOC11 paragraph, `install.sh` and `rebuild.sh`, which copy `GUIDE.md` into the bundle.

## Explicitly not / out of scope

- Deciding for the owner. The "Audit lean" column is the audits' recommendation, not a default.
- Ask/RAG, MCP, the URL scheme, the roster, workflows, the Notion, Obsidian and filesystem sinks.
- Fixing bugs in a surface while it is being decided (UX74, UX75 stay open until their surface's fate is known; a Delete closes them as moot).

## Acceptance

- The owner's decision is recorded in the table for every row before any code changes.
- Per deleted surface: `bash scripts/ci-local.sh` green (`truth_fences.py config` catches a config key left without a reader), a grep for the surface's type and module names returns nothing outside `docs/backlog/` and archives, `TutorialFenceTests` green, and the commit body records the LOC removed (src and tests).
- Per Experimental surface: a test that the switch off hides each entry point, and the GUIDE recipe says where the switch is.
- `docs/GUIDE.md` and `README.md` updated in each surface's commit, per the root same-commit contract.
