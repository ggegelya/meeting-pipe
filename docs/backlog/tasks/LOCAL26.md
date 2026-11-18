---
id: LOCAL26
title: Run and correction sidecars carry absolute paths that a library move or a cross-path restore leaves stale, so earlier meetings drop out of train-adapter and corrections-stats
category: Local models
status: partial
priority: P2
comment: Shipped 2026-11-18 (all four scope items, plus the daemon leg the batch brief asked for). corrections.resolve_meeting_file resolves <library>/<stem><suffix> first and the stored path as a hint; corrections-stats (new --library, else recording.output_dir), gate_ready, build_pairs and build_run_pairs all use it; the daemon's new correction records take the current library's path. Owner: nothing to run unless the library moves; then mp corrections-stats should report the same transcript chars as before.
---

# LOCAL26: Run and correction sidecars carry absolute paths that a library move or a cross-path restore leaves stale, so earlier meetings drop out of train-adapter and corrections-stats

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: finding F139 of the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md) (lens data, outcome partially confirmed, backlog New). Re-verified by code reading against HEAD `3a2da4fc` on 2026-11-13.

**The writers store absolute paths.** `corrections.write_run_sidecar`, called from `orchestrate` with `transcript_path=t["md"]` and `summary_json_path=s["json"]`, writes `"transcript_path": str(transcript_path)` and `"summary_json_path": str(summary_json_path)` into `<stem>.run.json`; `PipelineLauncher.writeAppleRunSidecar` does the same with `transcriptMD.path`. The daemon's correction record (`CorrectionStore.write`, in `~/Library/Application Support/MeetingPipe/corrections/<stem>.json`, outside the library) stores `transcript_path` and `summary_json_path` and no `stem` key; both callers take the path from the run sidecar: `CorrectionViewModel.transcriptPath` is `(runMeta["transcript_path"] as? String) ?? recordingsDir.appendingPathComponent("\(stem).md").path`, and the "Looks good" path in `Coordinator+Delegates` copies `run["transcript_path"]` verbatim. So a correction made after a move inherits the pre-move path from a sidecar that now sits in the new library.

**Nothing rewrites them.** `LibraryMover.execute` (SEC12) is `fm.moveItem(at: plan.source, to: plan.destination)`, so the old files are gone, not copied. `mp restore` strips the archive prefix so `library/a.wav` lands under this Mac's `recording.output_dir` and never repoints the library at the old Mac's paths, but it copies sidecar bytes unchanged. A typed change of Recording > Output directory ([UX89](./UX89.md)) followed by a manual move has the same effect.

**The readers open them verbatim.**
- `corrections._resolve_transcript_chars(data, transcript_path)` looks for the run sidecar beside the stored transcript path (`p.with_suffix(".run.json")`), then stats the stored path, and returns 0 when neither exists. Its `data` parameter is never used. `mp corrections-stats` (`corrections.main`) loads no config, so it has no library root to fall back to.
- `train_adapter.build_pairs` (corrections source) reads `data.get("transcript_path")` and skips the record when that is unreadable; it receives no recordings dir.
- `train_adapter.build_run_pairs` globs `*.run.json` in the current recordings dir, so it finds every sidecar, then reads `data.get("summary_json_path")` and `data.get("transcript_path")` verbatim and skips the meeting when either fails.

**Effect after a move.** Every pre-move meeting drops out of `--source runs` and `--source corrections`, and contributes 0 to `corrections-stats`' `transcript_chars`, which `train_adapter.gate_ready` uses as the corrections-source readiness bar (`READINESS_MIN_TRANSCRIPT_CHARS = 200_000`). The gate is depressed, not permanently blocked: meetings summarized or re-summarized after the move carry fresh paths, and `--force` bypasses the gate. Impact is limited to the opt-in, hand-run training commands. The stem itself survives everywhere: it is the correction file's name, the run sidecar's name, and the basename of the stale path (`_stem_from_transcript`).

**Field.** [2026-11-13 field evidence](../../audits/2026-11-13-field-evidence.md): "Precondition present, harm not shown", 110 of 110 `run.json` hold absolute paths; there are no library move rows in the window (F057, F058, F074, F141 under "Cannot tell"), so no move is on record. LOCAL9's commit `39d0357c` (2026-07-23) recorded the corrections corpus as empty for two months, so the runs source is the one with a corpus to lose.

## Scope

1. **One resolver, stem first.** In `corrections`, a small function that, given a stem, a suffix and the current library root, returns `<library>/<stem><suffix>` when it exists and otherwise the stored path when that exists, else None (through [PIPE33](./PIPE33.md)'s `meeting_files.path` if it has landed, a local join otherwise). Stored paths become hints only.
2. **corrections-stats.** `_resolve_transcript_chars` takes the stem and the library root: run sidecar at `<library>/<stem>.run.json` first, then the transcript by the resolver. `corrections.main` reads `recording.output_dir` from config (the same config load `train_adapter.main` does through `entry.prepare(secrets=False)`), with a `--library PATH` override for tests beside the existing `--dir`. `train_adapter.gate_ready(source, pairs)` has no root today, so it gains a library parameter and `train_adapter.main` passes the `recordings_dir` it already resolves.
3. **train-adapter.** `collect_pairs` passes `recordings_dir` to `build_pairs` as well as `build_run_pairs`; both resolve the transcript and summary by stem through the resolver.
4. **No migration.** Writers keep writing absolute paths; nothing rewrites existing sidecars.

## Explicitly not

- Rewriting sidecar paths in `LibraryMover.execute` or `mp restore`: it misses every other way a library changes root (a typed Output directory, a Finder move) and leaves the readers as fragile as before.
- Changing the Swift writers (`CorrectionViewModel.transcriptPath`, the "Looks good" path, `writeAppleRunSidecar`) to store relative paths or prefer `recordingsDir`: once both readers resolve by stem the stored value is a hint, and a schema change to a cross-tree sidecar is a contract change ([CONVENTIONS.md](../../../CONVENTIONS.md) sidecar rules) this fix does not need. Worth doing only if a third reader appears.
- The train-adapter pair shape and budget: [LOCAL27](./LOCAL27.md). Whether these commands stay product subcommands: [PIPE20](./PIPE20.md).
- Stem derivation in general: [PIPE33](./PIPE33.md); this task uses its seam if present and does not wait for it.

## Acceptance

- `pipeline/tests/test_corrections.py`: build a scratch library with two meetings (`<stem>.md`, `<stem>.run.json` with absolute paths into it, a correction record per stem), move the library directory to a new root, then `load_records` with the new root counts both meetings' transcript chars (non-zero, equal to the pre-move count), and `corrections.main(["--dir", ..., "--library", ...])` reports the same total.
- Same file: a record whose stored path still exists and whose stem is absent from the library still resolves through the stored path (hint fallback); a record with neither resolves to 0 without raising.
- `pipeline/tests/test_train_adapter.py`: the same moved scratch library yields the same pair count from `collect_pairs("runs", ...)` and `collect_pairs("corrections", ...)` before and after the move, with transcripts and summaries read from the new root.
- `cd pipeline && uv run --extra dev ruff check src tests`, `uv run --extra dev --extra mcp pyright` and `uv run --extra dev pytest -q` green, with the number of new tests in the commit body; `bash scripts/ci-local.sh` green.
- If `corrections-stats` gains `--library`, its usage line and the README's mention of the command agree in the same commit.

**Progress (2026-11-18): all four scope items shipped.**

- Premise check: every premise held. PIPE33's `meeting_files` seam has not landed, so the resolver is a local join, `corrections.resolve_meeting_file(stem, suffix, library, stored)`: `<library>/<stem><suffix>` when it exists, else the stored path when that exists, else None.
- `corrections-stats`: `_resolve_transcript_chars` looks for the run sidecar, then the transcript, by stem first. `load_records` takes `library=`. A record's stem comes from its `stem` key, then the correction file's own name, then the stored path's basename; the daemon's record carries no `stem`, and "Looks good" can store an empty path. `main` gains `--library PATH` and otherwise reads `recording.output_dir` through `entry.prepare(secrets=False)`.
- `train-adapter`: `build_pairs` takes `recordings_dir`, and `collect_pairs` passes it. `build_run_pairs` resolves its summary and transcript by stem. `gate_ready(source, pairs, library)` gets the library `main` already resolves. When the lookup finds nothing, the stored path still goes to the injected reader, so a custom reader keeps working.
- No migration: writers still store absolute paths, and nothing rewrites existing sidecars.
- **Deviation from "Explicitly not", at the batch brief's request.** The brief asked that the daemon stop copying stale paths into new corrections. It now does this in the narrowest form: `CorrectionStore.currentPath` gives `CorrectionViewModel.transcriptPath` / `summaryJsonPath` and the "Looks good" record (`Coordinator+Delegates`) the current library's `<stem>.md` / `<stem>.summary.json` when they exist, and the stored path otherwise. Same keys and still absolute, so the record's schema is unchanged. The run sidecar writers (`write_run_sidecar`, `writeAppleRunSidecar`) are untouched.
- Tests: `test_corrections.py` 2 (a moved library counts every meeting, through `load_records` and `main --library`; a stored path is still a hint, and a missing meeting is 0), `test_train_adapter.py` 2 (a moved library keeps every pair from both sources; `gate_ready` counts a moved library's corrections), `CorrectionPathTests` 1.

