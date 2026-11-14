---
id: PIPE20
title: The staged local summarizer sits behind a flag nothing sets with no verdict date, and owner dev tooling ships as product mp subcommands
category: Pipeline
status: new
priority: P2
comment: Filed 2026-10-24 (audit band, arch B2, go-live SA-11 part): summarize_staged.py (1,010 lines) runs only under MP_STAGED_LOCAL, which nothing sets, and waits on LOCAL13 and LOCAL14 benches unrun since July; dogfood, train-adapter and analyze-detection ship in the bundle. Owner picks delete now or a dated verdict; move dev tools behind mp dev, out of the runtime; one language repair on the local path. [Spec](./PIPE20.md) Amended 2026-11-13 by the audit band: the language-repair trigger flags a Latin-dense one-line title it can never repair, and engine_compare_report overwrites hand-entered dogfood grades in the git-ignored runs/ directory.
---

# PIPE20: the staged local summarizer sits behind a flag nothing sets with no verdict date, and owner dev tooling ships as product `mp` subcommands

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) B2, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) SA-11 in part). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Re-verified against `main` at `45b8c6a` on 2026-10-24.

**The staged summarizer.** `pipeline/src/mp/summarize_staged.py` is 1,010 lines, plus 581 in `tests/test_summarize_staged.py`, all from one commit (`58de459f`, 2026-07-28, "LOCAL14: staged local summarization behind a bake-off toggle"). It runs only when `STAGED_ENV = "MP_STAGED_LOCAL"` is set; a repo-wide grep finds that variable only in the module itself, `summarize_local.py`'s docstring, the tests, `ARCHITECTURE.md` ("**not the default**") and the backlog. No script, launcher or test harness outside the unit tests sets it. Its verdict is owed by the owner: [LOCAL14](./LOCAL14.md) sits in `owner-verification.md` as `complex`, with the move approved 2026-08-18, the thresholds deliberately unwritten until immediately before the bench, and the bench itself unable to start until [LOCAL13](./LOCAL13.md)'s model-refresh verdict exists, because the model lever and the pipeline-shape lever must move one at a time. LOCAL13's harness shipped 2026-07-24 and has not been run. So the code has waited about three months on two unrun owner benches, with no date by which "keep" or "delete" is decided.

**Dev tooling as product subcommands.** `mp` dispatches `dogfood` (`dogfood.py`, 469 lines), `train-adapter` (`train_adapter.py`, 526), `analyze-detection` (`analyze_detection.py`, 751) and `corrections-stats` from the same `USAGE` list and `_dispatch` as `run-all` and `publish`, and `scripts/bundle-runtime.sh` installs the whole `pipeline/` package into the app's runtime. No product module imports them (only `__main__` and `dogfood.py`'s own import of `train_adapter`), and no Swift code spawns them. The backlog's de-CLI rule already classes them as owner-dev diagnostics exempt from needing UI; what is missing is the boundary that says so in the code. With the staged summarizer they are about 2,756 of the pipeline's 21,296 source lines (13 percent).

**A duplicated language retry.** The local path can repair the summary language twice: `LocalSummaryClient._retry_on_language_mismatch` (LOCAL7) replays inside the client, and `summarize._verify_and_repair_language` (LANG1) repairs again for every backend. The inner one carries its own "KNOWN WEAK, left as-is deliberately" comment: it appends to the failed conversation, the shape `repair_messages` abandoned because mlx-lm 0.31.3 replays the cached prefix and returned byte-identical replies 6 of 6 times for the schema repair.

## Scope

1. **A dated verdict for the staged summarizer, owner's call at pickup.** Either (a) delete `summarize_staged.py`, its tests, `evidence.segments_from_timestamped_markdown` if nothing else uses it, the `summarize_local` hook and the ARCHITECTURE/CONVENTIONS lines now, and move LOCAL14's row to closed-as-withdrawn with the reason; or (b) keep it, with a verdict date written into LOCAL14's owner-verification row and its spec, and a line in this task's commit saying that on the date with no bench run, (a) happens. The pickup session asks; it does not choose.
2. **Fence the dev tooling.** Move `dogfood`, `train-adapter`, `analyze-detection` and `corrections-stats` behind `mp dev <tool>` (old names kept as aliases that print a one-line deprecation to stderr for one release, then removed), listed under a separate "Developer tools" heading in `USAGE`. Move `dogfood.py`, `train_adapter.py` and `analyze_detection.py` to `mp/dev/` so the boundary is a package, not a convention. `corrections-stats` is the `main` of `corrections.py`, a product module that also owns `write_run_sidecar`, so only its subcommand moves, not the module.
3. **Exclude them from the shipped runtime.** `scripts/bundle-runtime.sh` installs the package without `mp/dev/` (or `mp dev` reports "developer tools are not in the app bundle; run from the clone"). `install.sh`'s in-place venv keeps them, since the owner runs the benches there.
4. **One language repair on the local path.** Drop `_retry_on_language_mismatch` and let LANG1's `_verify_and_repair_language` own the repair for every backend, after checking with a fake local server that LANG1's fresh-conversation repair recovers the drift case LOCAL7's tests pin.

## Explicitly not

- Running or scoring the LOCAL13 or LOCAL14 benches. Those are owner work in `owner-verification.md`.
- Changing what the tools do. This is a move and a packaging boundary.
- The surface cut of user-facing secondary features (FEAT18). Dev tooling is not a product surface, so it is decided here.
- `prefetch-model`, `serve-local`, `finalize` and `cleanup-diarization`. The daemon or the docs drive each of them; they stay top-level.

## Acceptance

- Every doc that names an old invocation is updated in the same commit: re-grep at pickup (at filing: `README.md`, `ARCHITECTURE.md`, `CONVENTIONS.md`, `docs/engine-comparison.md`, `docs/spikes/local13-local-model-refresh-bench.md`, `tasks/LOCAL13.md`, `tasks/LOCAL14.md`, `tasks/LOCAL17.md`, `tasks/DET6.md`, `tasks/DET10.md`, `owner-verification.md`, `scripts/dogfood_report.py`, `scripts/engine_compare_report.py`). The LOCAL13 and LOCAL14 walkthroughs must stay runnable as written, since the owner has not run them yet.
- `test_main_dispatch.py`: `mp dev dogfood --help` routes to the tool; `mp dogfood` still routes and prints the deprecation line; `mp` with no args lists the dev tools under their own heading.
- `scripts/test-app-relocation.sh --with-pipeline` green, and a check (in that script or `ci-local.sh`) that the bundled runtime has no `mp/dev/`.
- Item 4: a test with the in-process fake `mlx_lm.server` where the first reply drifts language and the final summary is on target after exactly one repair call.
- Option (a): `pytest` green with the staged tests removed and no reference to `MP_STAGED_LOCAL` left outside archived specs. Option (b): the date is in LOCAL14's row.
- `cd pipeline && uv run --extra dev pytest -q`, `ruff check src tests` and `pyright` green, new test count in the commit body; `bash scripts/ci-local.sh` green; `python3 scripts/truth_fences.py links` green after the doc moves.

## Amendment 2026-11-13 (audit band)

Source: [independent audit](../../audits/2026-11-12-independent-audit.md) F081 (performance, confirmed) and G050 (data, verified at HEAD). Re-verified at HEAD (`3a2da4fc`) on 2026-11-14.

**The trigger leg of item 4 (F081).** Item 4 already removes the doubled local replay (`LocalSummaryClient._retry_on_language_mismatch`, still called from four sites in `summarize_local.py`). The trigger is new. `summary_language.divergent_sections` runs `language_signature` over every section `_summary_sections` returns, the one-line `"title": [summary.title]` included, and `language_signature` stays on the plain majority split LANG2 chose on purpose (`if cyr >= lat:` ... `return "en"`); its docstring records a real Ukrainian title at 49% Latin. A Ukrainian title of two Cyrillic words around four product names, the audit's executed example, has 10 Cyrillic and 28 Latin letters, clears `_LANG_MIN_LETTERS = 12`, and reads `"en"` against a `"uk"` target. `summarize._verify_and_repair_language` then re-asks the same client with the whole transcript plus `language_reinforcement`, and when the repaired title still reads `"en"`, which a title made of product names will, it logs "language repair still diverges" and returns the original. The second call is thrown away. On the cloud path the transcript is sent and billed twice for no change; on the local path it is up to four generations (summary, replay, repair, replay) until item 4 lands. LANG2 accepted "one extra model call that is discarded" per wrong flag; the title is the case where the flag can never succeed, so the call is never worth making.

**Added to scope.** 5. Stop the trigger firing on text a repair cannot change: exclude `title` from the sections `divergent_sections` may flag (or count it only when another section also diverges), or require a clear-majority divergence for short sections. Pick one, write the reason beside it, and keep the LANG1 case (a Russian `actions` block in an English summary) flagging.

**Added to acceptance.**

- In `tests/test_summary_language.py`: a Ukrainian summary whose title is dense with Latin product names and whose other sections read `uk` is not flagged; the LANG1 drifted-actions case still is.
- In `tests/test_summarize.py`: with a fake client, such a summary makes exactly one `summarize` call.

**G050: the comparison report overwrites hand grades.** `scripts/engine_compare_report.py`'s `main` calls `fill_dogfood_scores(f, sc14)` on every `runs/mlx-14b/*.dogfood.md`, and `fill_dogfood_scores` unconditionally rewrites the `actions_capture`, `decisions_capture` and `hallucination_rate` lines and replaces the `notes:` line with `"auto-computed structural capture vs Anthropic baseline (provisional, owner spot-check)"`, then writes the file back. Those are exactly the fields `mp dogfood`'s template in `dogfood.py` creates for the owner to grade by hand. `runs/` is git-ignored (`.gitignore` has `runs/`), so a grade overwritten by one report run has no other copy. Owner dev tooling, so P2 with the rest of this task.

**Added to scope.** 6. With item 2's move of the dev tools: `fill_dogfood_scores` writes only into empty score fields and leaves a non-empty `notes:` alone (or writes its provisional scores to a separate file beside the dogfood file), or the script is retired with the dev tools if the owner deletes them. `scripts/engine_compare_report.py` is already on item 2's doc list.

**Added to acceptance.** A test that a dogfood file with hand-entered scores and notes is byte-identical after the report runs, and that a file with empty fields gets the provisional values. No test covers `engine_compare_report.py` today, so it lands beside the script's new home.
