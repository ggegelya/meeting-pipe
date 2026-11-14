---
id: HYG21
title: Committed pipeline tests and docs name the people in meetings they describe as real, and nothing stops the next one
category: Hygiene
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). test_valid1_check.py fixtures carry four participant first names beside a stem the docstring calls "the real ... failure", plus the owner's first name in three pipeline tests and three names with measured voice similarities in pipeline/docs/gotchas.md (G052; the same names reach 43 tracked files repo-wide). Synthetic names and stems under pipeline/ and scripts/, and an owner-machine truth fence that reads the names from the roster and config, never from the repo. [Spec](./HYG21.md)
---

# HYG21: Committed pipeline tests and docs name the people in meetings they describe as real, and nothing stops the next one

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md) G052 (low findings table, "A committed test names the people in a meeting it describes as real"). Re-verified at HEAD (`3a2da4fc`) on 2026-11-13.

**The cited test.** In [`pipeline/tests/test_valid1_check.py`](../../../pipeline/tests/test_valid1_check.py), `test_der_reports_a_cluster_the_diarizer_merged_several_people_into` opens with the docstring `"""The real 20260716-103024 failure: THEM-A held <name> + 4 others ...` and builds its fixture from four participant first names (`labels={"THEM-A": ...}`, `segments={"1": ..., "2": ..., "3": ...}`), asserting the same names back. `test_der_ignores_a_no_op_override_to_the_same_person` carries the comment `# The real data had these: raw '<owner>' overridden to "<owner>".` with the owner's first name, and eight more tests in the file use the same names as fixture values. [`scripts/valid1_check.py`](../../../scripts/valid1_check.py)'s module docstring gives `--der --reviewed 20260716-113206 ...   # a real DER over meetings you reviewed fully` as its usage example.

**Correction at filing: the class is wider than the one test file.** Under `pipeline/` and `scripts/` alone the same first names appear in 4 test files (24 lines: `test_valid1_check.py`, `test_feat17_probe.py`, and the owner's first name as `user_label` in `test_orchestrate.py` and `test_diarize.py`) and in [`pipeline/docs/gotchas.md`](../../../pipeline/docs/gotchas.md), whose diarize-cleanup paragraph ties three participant names to the real stems `20260804-103026` and `20260806-113032` and to measured voice similarities. Repo-wide the same names are in 43 tracked files: `daemon/Sources` 5 files (17 lines, including `WorkflowContextHint.swift`'s user-visible placeholder, which names three people and their roles), `daemon/Tests` 19 files (212 lines), `daemon/docs` and `daemon/scripts` 1 each, `CONVENTIONS.md`'s diarize-cleanup audit example, `README.md`, `docs/engine-comparison.md`, the VALID1 runbook, one spike, six backlog files and the audit itself. Which of the daemon fixtures are real people cannot be told from the repo; the pipeline ones are tied to real stems in the text, so they are.

**The rule this breaks.** The root `CLAUDE.md`: "Do not hardcode a personal name or email in commits, code, or docs." That rule is about the owner's identity; third-party participants are the stronger case, since they never agreed to be in a public-ready repo (GitHub presence is in scope per the root `CLAUDE.md`). [HYG20](./HYG20.md) already names "a mechanical scan of history for emails, URLs and a names list returning 0 hits outside an allowlist" as the precondition for any publishing decision.

Related: [HYG18](./HYG18.md) (fences and written rules weaker than they read), [HYG20](./HYG20.md).

**Why a plain regex fence does not work.** Stem-shaped tokens (`20[0-9]{6}-[0-9]{6}`) appear in 85 files across `pipeline/`, `scripts/` and `daemon/Tests`, 151 distinct values in the two test trees, almost all synthetic (`20260101-120000` alone 23 times). A committed denylist of names would commit the names. The only list that knows who is real is the owner's own data: the roster at `~/.config/meeting-pipe/roster.json` (`RosterStore.names()`), `summarization.user_label` in `~/.config/meeting-pipe/config.toml`, and the stems in the recordings directory (`recording.output_dir`, default `~/Documents/Meetings/raw`).

## Scope

1. **Rewrite under `pipeline/` and `scripts/`.** Replace every participant and owner first name in `pipeline/tests` with neutral synthetic names (one fixed set, for example `Avery`, `Blake`, `Casey`, `Drew`, chosen so none is in the owner's roster) and every stem a comment calls real with a synthetic one. Drop the "the real ... failure" and "the real data had these" wording; the scenario stays, described by shape. `valid1_check.py`'s usage example takes a synthetic stem. In `pipeline/docs/gotchas.md` the paragraph keeps its measurements and stems and names the clusters by role (`THEM-A into a roster speaker at 0.524`).
2. **An owner-machine fence.** A `personal` check in [`scripts/truth_fences.py`](../../../scripts/truth_fences.py), run by `both`, stdlib only. It reads names from the roster file and `summarization.user_label`, and stems from the configured recordings directory, each path overridable (`--roster`, `--config`, `--library`) so a test can inject them. It greps tracked files under `pipeline/` and `scripts/` for any name as a whole word and, under `pipeline/tests` and `scripts/` only, for any library stem. On a hit it prints `file:line` and `roster name #k` or `library stem`, never the matched text, so the fence's own output carries no name. When none of the three sources exists (the CI runner, a clean Mac) it prints one line saying it skipped and passes. The scanned path list is one constant, so widening it is a one-line change.
3. **Docs.** The root `CLAUDE.md` truth-fences row lists `personal` and says it is an owner-machine check by design, within CI5's 800 B per-entry budget. CONVENTIONS.md "Test discipline" gets one line: fixtures use synthetic names and stems, never a roster name or a library stem.

## Explicitly not

- **The rest of the repo, observed and not filed.** `daemon/Sources` (5 files, including the shipped `WorkflowContextHint` placeholder), `daemon/Tests` (19 files, 212 lines), `daemon/docs/gotchas.md`, the `daemon/scripts` DIAR4 probe, `CONVENTIONS.md`'s cleanup-audit example, `README.md`, `docs/engine-comparison.md`, the VALID1 runbook and the DIAR4 spike. Widening this task to them, or filing a sibling, is the owner's call; the fence's path constant is the seam either way. The user-visible placeholder is the one that ships in the app.
- **History.** `docs/backlog/` (including open DIAR3, DIAR5 and PERF8 and the generated `INDEX.md` line DIAR5's comment produces), `docs/audits/` and the `q*-final.md` archives are not rewritten here, and git history keeps every name regardless. HYG20 owns any history scan before publishing.
- A regex fence for stem-shaped tokens: 151 synthetic values share the shape.
- Meeting titles persisting into the event log: F163 in the same audit, filed separately in this band.

## Acceptance

- On the owner's Mac, with the real roster, config and library, `python3 scripts/truth_fences.py personal` passes, and fails on a planted roster name in a scratch test file (tried and reverted, said in the commit body).
- New `pipeline/tests/test_personal_fence.py`, loading the script by path as `test_link_fence.py` does, on a temp tree with an injected roster, config and library: fails on a planted roster name in a test file; fails on a planted library stem under `tests/`; passes on the same stem in a doc outside `tests/` and `scripts/`; passes on a near miss (the name as a substring of a longer word); skips and passes when all three sources are absent; its printed output never contains the planted name. About 6 new tests.
- The rewritten valid1 tests still assert the same report shapes (`merged_clusters`, `der_lower_bound`) with the synthetic names.
- `cd pipeline && uv run --extra dev pytest -q` green, `uv run --extra dev ruff check src tests` green, `bash scripts/ci-local.sh fences` green.
