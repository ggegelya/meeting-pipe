---
id: DET16
title: Shrink sensing to what the event log has seen: delete detector paths, title matchers and mute adapters with zero real firings, so one app is detected automatically and everything else uses the hotkey
category: Detection
status: new
priority: P2
comment: Filed 2026-11-13 (product-direction band, idea I47, 14.34 of 20): breadth is carried (browser detection, seeded guesses, catalogue entries never recorded) while six END fixes for the one real app do not hold. A one-day owner-run count of recording_started rows by bundle and browser_tab_rejected rows pre-registers PASS (delete browser detection and every zero-row entry; DET6 and MIC7 close as moot) or FAIL (keep the second source, delete only zero-row entries). Child of [EPIC4](./EPIC4.md).
---

# DET16: shrink sensing to what the log has seen

Band origin: filed 2026-11-13 from the product-direction band ([report](../../research/2026-11-12-product-direction.md), idea I47, "Shrink sensing to what the log has seen: Teams starts by itself, everything else is a hotkey"). Child of epic [EPIC4](./EPIC4.md). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context and what changed

[DET6](./DET6.md) (browser probe shipped 2026-08-18, measurement owner-owed), [MIC7](./MIC7.md) (browser mute oracle: feasibility GO, build deferred because the owner has zero recorded browser meetings) and [DET15](./DET15.md) (English-only matchers) all defer building; none proposes deleting the paths. What changed: the 2026-11-12 [audit](../../audits/2026-11-12-independent-audit.md) found the fixture behind them, `window_titles.json`, holds 21 seeded guesses and 0 captured rows (with one allow-listed skipped test), found six END fixes not holding, and F038 (idle discovery cost) partly sits in the extra paths. MeetingPipeCore's observer bus, promotion engine and event log stay; only unmeasured catalogue entries in `daemon/Sources/MeetingPipe/Resources/meeting_apps.toml` and the code paths around them go. ADR [0017](../../decisions/0017-hold-long-trim-later-end-detection.md)'s tier table is the reference for what a detector entry carries.

## Pre-registered probe (copied from the report; owner-run, counts only, one day)

Group real `recording_started` rows by bundle id across all retained `events.jsonl` generations (CONVENTIONS records no test residue on that action; print the earliest row's date beside the totals, since the log rotates at about 5 MiB with 3 backups and "never seen" only means "not in the retained window") and count `browser_tab_rejected` rows by bundle.

| Verdict | Measured | Next |
|---|---|---|
| **PASS** | One bundle holds at least 90% of recordings AND browser recordings are 0 | Delete browser detection and every catalogue entry with zero rows; close DET6 and MIC7 as moot with a pointer here |
| **FAIL** | Any second source holds at least 10%, OR at least 1 browser recording | Keep that source; delete only the zero-row entries |

## Scope

- One delete commit after the verdict: the browser admission path (`MeetingSourceScanner.decideBrowserAdmission` and its callers) on PASS, zero-row catalogue entries and their special cases in either case, the seeded-guess fixture and its skipped test.
- README, [docs/GUIDE.md](../../GUIDE.md) and the Preferences copy say plainly which app is detected and ended automatically and that anything else is recorded with the hotkey.

## Explicitly not

- Touching the END band's teardown logic for the app that stays.
- Re-adding detection later from guesses: a job change re-adds an app from captured titles only.
- Changing MeetingPipeCore's public structure (its fusion and decide functions stay).

## Owner walkthrough

One command over the real event log (written into the progress note); the READ line prints PASS or FAIL with the per-bundle counts and the earliest retained date.

## Acceptance

- The count script (read-only, counts only) and a dated verdict here.
- The delete commit with `swift build`, `swift test` and `bash scripts/ci-local.sh` green; replay corpus tests for the kept app unchanged; truth fences green (config keys, dead links); the GUIDE and README sentences changed in the same commit.
