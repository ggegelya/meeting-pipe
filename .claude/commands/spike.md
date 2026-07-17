---
description: Ship a probe-first spike - analysis doc + owner-run read-only probe with pre-registered verdict thresholds
---

You're running a spike for backlog task: $ARGUMENTS

This codifies the template CAL1, MIC7, DET2, and MIC8 each shipped (docs in `docs/spikes/`; read one if the shape is unclear). A spike exists because this harness cannot answer the question (no live meeting, no TCC grant, no real calendar, no clean second Mac): the deliverable is a measuring instrument plus a pre-committed decision rule, never a hunch.

1. Read the task spec (`docs/backlog/tasks/<ID>.md`, or `docs/backlog/q4-final.md` for carried items) and the orientation docs per `/tech-task` step 2.
2. Frame the ONE question the spike must answer, and why it cannot be answered here. If it actually can (documentation, code reading, a runnable experiment), it is not a spike; just answer it and say so.
3. Close what is closeable a priori: work every candidate mechanism against documentation and the existing code first, and close the ones that are settled without measurement, with citations (the MIC8 pattern: two of three signal classes closed from documentation, only the undocumented one went to a probe).
4. Deliverable A, the analysis doc `docs/spikes/<id-lowercase>-<slug>.md`: the question; the candidate-mechanism decision tree; what is already settled and why; the pre-registered verdict thresholds, written BEFORE the owner measures anything (GO / marginal / close, each mapped to a concrete measured value, the CAL1 coverage-percent pattern); and the exact owner-owed remainder as a runnable command.
5. Deliverable B, the probe: owner-run and read-only, under `daemon/scripts/` or `pipeline/` (match the side it measures). It must be safe to run during a real meeting, change no production code, and print a READ line that maps directly onto the thresholds, so the owner needs no interpretation help. Verify it compiles or typechecks: `swiftc -typecheck` for Swift, `uv run --extra dev ruff check` for Python, `node --check` for JS.
6. Hard rules: a spike never changes production behavior (zero regression risk is part of the contract); verdict criteria are pre-registered, never fitted to a measurement after the fact; an honest close is a valid terminal outcome, and a leg closed from documentation is a result, not a failure.
7. Update the backlog: ToC Status `partial`, Comment "Spike shipped: <doc + probe>. Owner-owed: run <exact command>, then GO (<what a GO builds>) or close."; append a `**Progress (<date>): ...**` note to `docs/backlog/tasks/<ID>.md`, matching the existing convention.
8. Docs-sync check per `/tech-task` step 7. Production is untouched, so README and ARCHITECTURE are usually unaffected, but check and say which docs you checked.
9. One commit on `main` with the repository's configured git identity: `<ID>: ship the <topic> spike (probe-first)`. Don't push. No em-dashes; single-line paragraphs.
10. Summarise: the question, what closed a priori, the thresholds, and the exact command the owner runs next.
