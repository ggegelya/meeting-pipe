# PIPE20: the staged local summarizer sits behind a flag nothing sets with no verdict date, and owner dev tooling ships as product `mp` subcommands

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) B2, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) SA-11 in part). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

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
