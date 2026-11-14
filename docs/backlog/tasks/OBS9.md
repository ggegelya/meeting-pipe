---
id: OBS9
title: The event log's retention is set by noise: four 5 MiB files kept 45.9 days, and everything before 2026-09-29 is gone, including two crash days
category: Observability
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). Log rotates events.jsonl at four files of 5 MiB, and three chatter families are 79.5 percent of its bytes, so the work laptop kept 45.9 days and lost every event from 2026-05-18 to 2026-09-29 (two crash days, 40 of 113 meetings); the rest is about 34.4 KB a day, roughly 600 days in the same files. Scope: high-volume diagnostic rows to their own rotating family so lifecycle, recorder and pipeline rows keep a long history, a bound on launchd.err.log, a locked Python rotation (F212), and verdict_changed logged only when the audio-passing or mute side changes.
---

# OBS9: The event log's retention is set by noise: four 5 MiB files kept 45.9 days, and everything before 2026-09-29 is gone, including two crash days

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Sources: the field finding "Rotation is driven by noise: 45.9 days kept, everything earlier lost" (Daemon health, finding 7) and "Verdict log is dominated by changes that change nothing; RMS chatter would matter under the regulated gate" (Mic, mute and capture, finding 11) in [2026-11-13-field-evidence.md](../../audits/2026-11-13-field-evidence.md); F212 in [2026-11-12-independent-audit.md](../../audits/2026-11-12-independent-audit.md) (summary item 9 of that audit is the same retention point). Code re-read at HEAD `3a2da4fc` on 2026-11-13.

**What was lost.** On the work laptop `events.jsonl` covered 2026-09-29T09:45Z to 2026-11-13T07:44Z, 45.9 days. `daemon.log` starts on 2026-05-18, so every event from then to 2026-09-29 is gone, including the 2026-08-13 and 2026-08-14 crash days and the events for 40 of the 113 meetings in the pack. Three families (HAL subscribe, subscribed and unsubscribed; `call_teardown_source_missing`; `process_audio_object` resolved and unresolved) are 79.5 percent of the bytes, 56 single minutes hold 54.7 percent of all rows, and `events.2` lasted 4.2 days because of the 2026-10-09 and 2026-10-12 HAL storms. Rows outside the five noise groups are 9.1 percent of bytes, about 34.4 KB a day; at that rate the same four files would span roughly 600 days.

**Why.** `Log.append` runs `rotateLocked(url)` before every write, and `rotateLocked` renames at `maxLogBytes` (5 MiB, `MEETINGPIPE_LOG_MAX_BYTES` overrides) with `maxLogGenerations = 3`, so a family is at most four files whatever is in them. The retention of a lifecycle row is set by how much HAL chatter shares its file.

**The never-rotated logs, narrower than reported.** The field finding lists `daemon.log`, `recorder.log`, `pipeline.log`, `launchd.err.log` and `pipeline_events.jsonl` as never rotated. Correction at filing: at HEAD the first four of those that the app writes are under the same cap. `Log.writeLine` goes through `Log.append`, so `daemon.log` and `recorder.log` rotate exactly as `events.jsonl` does, and so does the daemon-owned `pipeline.log` (`PipelineLauncher.runMP` appends each chunk through `Log.append`); Python rotates `pipeline.log` in `orchestrate._configure_logging` (`events.rotate_if_needed(log_file)`) and `pipeline_events.jsonl` in `events.emit`, all since PERF7 (2026-07-11). They have simply never reached 5 MiB. The one log with no bound at all is `launchd.err.log`, written by launchd from the plist's `StandardErrorPath`, which nothing rotates.

**F212, folded in (low, verified).** Python's `events.rotate_if_needed` is an unlocked stat-then-rename: `if path.stat().st_size < _max_log_bytes(): return`, then unlink generation 3, shift 2 to 3 and 1 to 2, then `path.replace(...)`. It is reached from `events.emit` on the main thread, from the `mp-progress` heartbeat thread (`_ProgressHeartbeat._run` calls `events.emit_progress`, which calls `emit`), and from every concurrent `mp` process. Two callers that both pass the size check rotate twice: the second shifts the first's fresh generation 1 up and drops the oldest generation, and if the base file has not been recreated yet its `path.replace` raises `FileNotFoundError`, which `emit`'s `except Exception` swallows, so that event row is lost too. Swift's side is one locked `O_APPEND` writer per process (PERF13), which `Log.rotateIfNeeded`'s own doc says does not cover a second process.

**`verdict_changed`, folded in (field Mic finding 11, low, verified).** `MicGate.publish` emits `micgate`/`verdict_changed` whenever `verdict != self.lastVerdict`, and a verdict carries its reason, so a change of reason with no change of effect is a row. Field: 5,949 in-recording rows, 4,354 of them swapping between `rms_above_open_threshold` and `confidently_unmuted` (both pass audio), 155 repeating the same class with a new label; RMS drives 5,236 of the 5,794 class changes and 1,973 A-B-A flaps under 2 s. Median 128 class changes per recorded hour, max 738. `scripts/dogfood_report.py` counts `verdict_changed` transitions, so it is a reader to keep working.

**Noise at source is filed elsewhere.** The HAL listener leak and re-resolve storms are [DET21](./DET21.md); `call_teardown_source_missing` is [END16](./END16.md) (amended by this band); `ax_mute_button_state_kept`, the newest build's chatter (39 percent of era C rows), is [MIC20](./MIC20.md). Cutting those shrinks the noise; this task makes retention independent of whether they stay cut.

## Scope

1. **A diagnostic family.** Add a `Log.diagnostic(category:action:attributes:)` (same envelope as `Log.event`) that appends to `diagnostics.jsonl` under the same `Log.append` lock and rotation. Move the HAL bus subscribe, subscribed and unsubscribed rows, `process_audio_object` resolved and unresolved, and `call_teardown_source_missing` to it at their emit sites (and their `MeetingPipeCore` `EventLog` equivalents, through a diagnostic sink on the protocol). `events.jsonl` keeps everything else at today's cap, so its history grows from about 46 days to the order of the 600-day figure. Give the diagnostic family its own generation count; it is allowed to be short.
2. **Readers follow.** Every reader that consumes a moved row reads both families through `log_generations` (Python) or `Log`'s generation list (Swift): at least `scripts/extract_detection_trace.py` (reads `call_teardown_source_missing`), `mp logs`, `mp analyze-detection`, `scripts/dogfood_report.py`, the Diagnostics window (`DiagnosticsLog`), and every other reader a grep for `events.jsonl` and `log_generations` finds. A reader that does not need diagnostics stays on `events.jsonl` only.
3. **Bound `launchd.err.log`.** Rotate it from the daemon at launch through `Log.rotateIfNeeded`. launchd opened the file before the process started, so the running daemon keeps writing to the renamed generation and the next spawn gets a fresh base; a size check at each launch is enough for a file that only grows on a crash or a stray stderr write.
4. **Lock Python's rotation (F212).** In `events.rotate_if_needed`, take an exclusive `fcntl.flock` on a sibling lock file (`<name>.lock`) around the check and the renames, re-stat inside the lock, and treat a missing base as nothing to rotate. `emit`'s write stays outside the lock (it is `O_APPEND`).
5. **`verdict_changed` on effect only (field Mic finding 11).** In `MicGate.publish`, keep `lastVerdict` dedupe for the verdict stream, but emit `verdict_changed` only when the verdict's audio-passing side or its mute-indicating side differs from the last logged one; count the suppressed reason swaps and RMS open and close transitions and emit them as one `verdict_churn` aggregate row per minute with activity (counts only) and once at gate stop. `dogfood_report.py` reads both.

## Explicitly not

- Fixing the noise sources themselves: [DET21](./DET21.md), [END16](./END16.md), [MIC20](./MIC20.md).
- Raising `maxLogBytes` or the generation count for `events.jsonl`. Without item 1 that buys days, not months, and the next storm takes them back.
- Shipping logs anywhere or compressing old generations.
- Test-suite pollution of `pipeline.log` (85 percent of its lines on the laptop): the Python `logs_dir` guard and TECH-END4 already stop new residue, and `is_test_residue` filters the old.
- A start, stop or heartbeat row for uptime: [OBS5](./OBS5.md)'s amendment.

## Acceptance

- Swift `LoggerTests`: a burst of diagnostic rows past the cap with `MEETINGPIPE_LOG_MAX_BYTES` set small rotates `diagnostics.jsonl` and leaves `events.jsonl` at its single base file; a `Log.event` row is unaffected by any number of diagnostic rows.
- An emit-site test per moved family (HAL bus, process audio, teardown watcher) asserting the row lands in `diagnostics.jsonl` and not in `events.jsonl`.
- `test_events.py`: two processes (or threads through `multiprocessing`) calling `rotate_if_needed` on a file over the cap at once leave exactly generations 1 to 3 with no generation dropped; `emit` on a base removed between check and rename writes its row.
- `MicGateTests`: a sequence alternating `rms_above_open_threshold` and `confidently_unmuted` emits no `verdict_changed` after the first and one `verdict_churn` with the swap count; a hot to muted change still emits `verdict_changed` at once.
- `extract_detection_trace.py` and `dogfood_report.py` tests over a fixture split across both families produce the same output as the single-file fixture; `test_dogfood_report.py` green.
- `diagnostics.jsonl`, `verdict_churn` and the moved rows' new home documented in `CONVENTIONS.md` (event-log section and table) and `ARCHITECTURE.md`'s "Where files live on disk"; `python3 scripts/truth_fences.py` green.
- `cd daemon && swift build` and `swift test` green, `cd pipeline && uv run --extra dev pytest -q` green, N new tests named in the commit body; `bash scripts/ci-local.sh` green.

## Owner walkthrough

1. [session] After two weeks on the landing build, report the first timestamp of the oldest `events.*.jsonl` generation and the daily byte rate of `events.jsonl` against the 34.4 KB a day above.
