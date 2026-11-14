---
id: LOCAL26
title: Run and correction sidecars carry absolute paths that a library move or a cross-path restore leaves stale, so earlier meetings drop out of train-adapter and corrections-stats
category: Local models
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). `<stem>.run.json` and every correction record store absolute `transcript_path` and `summary_json_path` that nothing rewrites (110 of 110 run sidecars in the field hold one), and both Python readers open them verbatim, so after SEC12's library move or a restore onto another root every earlier meeting drops out of `mp train-adapter` and counts 0 transcript chars in `mp corrections-stats`; the daemon copies the stale path into new corrections too. Resolve by stem against the current library in `corrections` and `train_adapter`, stored paths as fallback only. [Spec](./LOCAL26.md)
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
