# OBS4: one meeting cannot be followed from recording to summary in the logs, because no run id crosses the daemon/mp boundary, most rows carry no stem, and pipeline.log is local time with no zone

Band origin: filed 2026-10-25 from the 2026-10-25 observability audit band ([audit](../../audits/2026-10-25-observability-audit.md) row O10; finder LG-8). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Verified in code on 2026-10-25 (base `01e904a`); counts measured by the finder on the owner's `events.jsonl` and `pipeline_events.jsonl` on this Mac.

**No run id.** `PipelineLauncher.runMP` builds the child's environment and exports `MP_FAILURE_PATH` and nothing that names the run. `SinkDispatcher` logs `pipeline_started` with `"file"` and `"kind"`; Python logs `run_started` with `wav=str(wav)` (an absolute path). Joining the two needs a time window. A Library re-summarize, an `mp ask` index build or a backup started while a run is going interleave in `pipeline.log` with nothing separating them.

**Rows that name no meeting.** Of the owner's rows: 0 of 3 `recorder` / `intermediate_durations`, 0 of 4 `recorder` / `configuration_change_recovered` (its attributes are `live_sample_rate`, `used_converter`, `gap_frames`), 0 of 1 `mic_tap_stall_detected`, 0 of 8 `lifecycle` / `starting`, 0 of 1 `lifecycle` / `ended`, and 0 of 6 pipeline `stage_started` (`events.emit("pipeline", "stage_started", stage="finalize", source=source)`).

**Four spellings of the key.** `file` (`"20261016-122748.wav"`, on `recording_stopped` and `pipeline_failed`), `wav` (absolute path, Python `run_started` and `run_failed`), `stem` (`retry_requested`, `pipeline_stalled`), and `md` (path, `stage_completed`). CONVENTIONS.md documents none of them as canonical.

**Two clocks.** `orchestrate._configure_logging` formats `pipeline.log` with `"%(asctime)s %(levelname)s %(name)s: %(message)s"`, which writes `2026-10-16 12:46:34,784` in local time (EEST that day) with no zone, while both JSONL files write `2026-10-16T09:46:34.829Z`. A join across a DST change is wrong by an hour. Other subcommands call `logging.basicConfig` with their own formats, and several have no timestamp at all: `merge_meetings`, `ask` and `digest` use `"%(levelname)s %(name)s: %(message)s"`, and their stderr is what the daemon copies into `pipeline.log`.

**Python has one choke point.** Every pipeline event goes through `mp.events.emit`, so a run id and stem can be stamped once there rather than at each call site.

## Scope

1. **Mint and export a run id.** `SinkDispatcher` mints a `run_id` (a UUID string) when it starts a job and passes it through `runAll` and the regenerate, republish and merge spawns to `runMP`, which exports `MP_RUN_ID` and, when `meeting` is set, `MP_STEM`. Spawns with no job (ask, digest, backup, doctor) get a fresh id from `runMP` itself.
2. **Stamp it on every row on both sides.** `mp.events.emit` adds `run_id` and `stem` from the environment when present and not already passed. Daemon rows tied to a job (`pipeline_started`, `pipeline_succeeded`, `pipeline_failed`, `pipeline_stalled`, `retry_requested`, and OBS3's structured failure rows written through OBS1's `Log.failure`) carry `run_id` and `stem`.
3. **Stem on in-recording rows.** `intermediate_durations`, `configuration_change_recovered`, `mic_tap_stall_detected`, `input_device_resolved`, `recording_error` and `recording_stopped` carry `stem`. Lifecycle rows after `MeetingLifecycleCoordinator.confirmRecording` carry it too, passed as `confirmRecording(stem:)` so the Core island learns a string and nothing else. `lifecycle` / `starting` precedes any recording and stays stem-less; the `recording_started` row joins it.
4. **One format for every Python log line.** A shared formatter in `mp.events` (`2026-10-16T09:46:34.784Z LEVEL name [run_id]: message`, UTC via `time.gmtime`) used by `_configure_logging` and by every `basicConfig` call (`summarize`, `merge_meetings`, `publish_from_paste`, `publish_cmd`, `ask`, `digest`, `diarize_cleanup`, `summarize_local`, `dogfood`, `prefetch_model`). The run id is added by a `logging.Filter` reading `MP_RUN_ID`, and is empty for a hand-run command.
5. **A spawn header in pipeline.log.** `runMP` writes one line before the child's output: `--- mp <subcommand> run_id=<id> stem=<stem> invocation=<tier>`, through whichever `pipeline.log` design [PERF13](./PERF13.md) item 3 lands. The tier name is the one [DIST6](./DIST6.md)'s amendment records.
6. **Name the canonical key.** CONVENTIONS.md "Event log schema" says `stem` is the meeting key on new rows and `run_id` the run key, lists `file`, `wav` and `md` as legacy spellings readers must keep accepting, and documents `MP_RUN_ID` and `MP_STEM`. `mp logs` gains `--run <id>` and `--stem <stem>` filters.

## Explicitly not / out of scope

- Renaming or removing `file`, `wav` or `md` on existing rows. `mp analyze-detection` pairs `recording_started` and `recording_stopped` by `file`, and rotated generations keep the old shape forever; this is additive.
- Per-run log files and the torn-write fix: PERF13 item 3 decides `pipeline.log`'s shape; this task only needs one header line in whatever it picks.
- Which build and executable ran: DIST6 and its amendment. This task reuses the tier name in the header.
- A distributed-tracing library or span model. One opaque id per spawn is the whole need.

## Acceptance

- Swift: `runMP`'s environment (through the existing environment-building seam) carries `MP_RUN_ID`, and `MP_STEM` exactly when a meeting is given; `pipeline_started` and `pipeline_failed` for one job carry the same `run_id`; `configuration_change_recovered` and `recording_stopped` carry `stem`; `confirmRecording(stem:)` makes the next lifecycle row carry it.
- Python: with `MP_RUN_ID` and `MP_STEM` set, every `events.emit` row carries both; an explicit `stem=` wins; with neither set the row is unchanged. The shared formatter renders a fixed `LogRecord` as UTC with `Z` and the run id, and every module listed in item 4 uses it (a test greps `pipeline/src` for `basicConfig(` calls that do not pass it).
- `mp logs --run <id>` returns both trees' rows for one run from a fixture log.
- CONVENTIONS.md updated in the same commit; `python3 scripts/truth_fences.py` green.
- `cd daemon && swift test` and `cd pipeline && uv run --extra dev pytest -q` green, ruff and pyright clean, `bash scripts/ci-local.sh` green. N new tests in the commit body.
