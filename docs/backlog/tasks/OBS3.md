---
id: OBS3
title: Failure events carry only a caption, a signal death is read as an exit code, and three pipeline commands fail with no event at all
category: Observability
status: partial
priority: P2
comment: Shipped 2026-11-19 (structured daemon failure rows, signal vs exit, command_failed from every subcommand, run-all missing secret exits 2, emit never raises, typed transcript reads, SW-19) and 2026-11-26 (the second fix review's amendment - command_failed, both run_failed rows, stage_failed, finalize_failed and sink_failed carry the error class and typed cause, never the exception text). Owed - the owner reads one real failure row in events.jsonl after the next pipeline failure. [Spec](./OBS3.md)
---

# OBS3: failure events carry only a caption, a signal death is read as an exit code, and three pipeline commands fail with no event at all

Band origin: filed 2026-10-25 from the 2026-10-25 observability audit band ([audit](../../audits/2026-10-25-observability-audit.md) row O9; finders FB-7, PY-8, PY-9 run-all half, PY-10, PY-11, SW-19). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Verified in code on 2026-10-25 (base `01e904a`).

**Daemon failure rows are a caption.** `SinkDispatcher`'s run completion emits `coordinator` / `pipeline_failed` with `"file"` and `"error": err.localizedDescription` and nothing else; `retranscribe_failed` (same file), `regenerate_failed` and `republish_failed` (`MeetingLibraryService`) have the same two-field shape. The owner's log has 4 real `pipeline_failed` rows (3 Apple unsupported-language failures and the 2026-10-16T09:46:34.829Z `pipeline exited 1: ... $ANTHROPIC_API_KEY is not set`), and none says which stage, which exit status or which cause. The structured cause exists: `PipelineFailureSidecar.write` gets `stage:` and `metadata: FailureMetadata.from(err)`, but `<stem>.error.json` is overwritten or cleared on the next run, so `events.jsonl` cannot answer "how many runs died of memory this month".

**A signal is read as an exit code.** `grep terminationReason daemon/Sources` finds nothing. `runMP`'s termination handler passes `proc.terminationStatus` to `PipelineLauncher.outcome(status:cancelled:stderr:metadata:)`, which returns `LaunchError.nonZeroExit(status, stderr)`. For a process killed by a signal `terminationStatus` is the signal number, so a jetsam SIGKILL is `nonZeroExit(9)` and a SIGQUIT is `nonZeroExit(3)`, which `SinkDispatcher.stage(for:)` matches as `nonZeroExit(PipelineLauncher.publishFailedExitCode, _)` and labels `.publish`, offering a republish of a summary that may not exist. The app's own Cancel and watchdog are already distinct (`.cancelled`, `.timeout`); only foreign signals collide.

**Three commands fail without an event.** Only `run-all` writes `run_failed` to `pipeline_events.jsonl`. Each of these catches and returns 1, so `__main__`'s boundary `except Exception` (which calls `emit_failure`) never runs:

- `merge_meetings.main`: `except MergeError as e: print(f"merge failed: {e}", ...)` and `except Exception as e: log.exception(...)`, no `emit_failure`, no event.
- `publish_from_paste.main`: `log.error("publish-from-paste failed: %s", e)`, no traceback, no `emit_failure`, no event.
- `finalize.main`: `log.error("finalize failed: %s", e)`, the same.
- `summarize.main` calls `emit_failure` but emits no event.

A failed merge, paste-publish or Library re-summarize therefore shows the generic `unknown` cause with a plain Retry, and the only record is whatever stderr tail the daemon kept.

**run-all exits 1 on a missing secret.** CONVENTIONS.md says the vocabulary is "1 (any other failure), 2 (usage, and a missing managed secret)". `orchestrate.main` wraps `run_all` in `except Exception as e: log.exception(...); emit_failure(...); return 1`, and `config.MissingSecretError` is an `Exception`, so the boundary's exit-2 handler is unreachable for the command that runs every meeting. `summarize.main` already re-raises it ("The CLI boundary retains PIPE16's exit-2 contract"). Harmless today because only 3 is branched on, but the doc is wrong for the most common case. (The Keychain half of PY-9 is a [SEC23](./SEC23.md) amendment, not this task.)

**`events.emit` can raise.** `path = _events_path()` (which `mkdir`s the logs dir) sits before the `try:` that wraps the write. An unwritable logs dir raises out of `emit`, and `run_all`'s handler calls `events.emit("pipeline", "run_failed", ...)` before `raise`, so the logging call replaces the run's real exception. Latent; the dir is writable here.

**A corrupt transcript is reported as missing, twice.** `existing_daemon_transcript` returns `None` both when `<stem>.json` is absent and when `json.loads` raises (`except Exception: return None`). `_run_all_inner` then emits `run_failed` with `error="no daemon transcript"`, `error_type="MissingSidecar"` and raises, and `run_all`'s wrapper emits `run_failed` a second time. An iCloud-evicted transcript reads as a recorder fault, and failure counts double.

**Daemon paths that swap the error for a guess (SW-19).** `AppleIntelligenceSummarizer` throws `.emptyTranscript` when `try? String(contentsOf: transcriptMD, ...)` fails, so a permission error reads "Transcript is empty". `MeetingRecorder.noteWriteOutcome`'s escalation line says "disk full or the 4 GiB WAV cap" without the OS error. `LocalServerReaper.loadMarker` and `parseMarker` return `nil` on a malformed marker and `reapIfOrphaned` returns with no log. `LibraryMover.inFlightReason` returns `nil` ("not busy") when `contentsOfDirectory` fails, so an unreadable library reads as safe to move.

## Scope

1. **Structured daemon failure rows.** One builder, `PipelineFailureEvent.attributes(for:stage:)`, used by `pipeline_failed`, `retranscribe_failed`, `regenerate_failed` and `republish_failed`: `exit_status`, `termination_reason` (`exit` or `signal`), `signal` when it applies, `stage` (the `PipelineFailureSidecar.Stage` raw value), and `cause`, `operation` and `provider` from `FailureMetadata` when present. The rows go through OBS1's `Log.failure`, so they also carry `error_domain` and `error_code` and get a `daemon.log` sentence; the existing `error` caption stays.
2. **Read `terminationReason`.** `outcome` takes the reason; `.uncaughtSignal` becomes `LaunchError.uncaughtSignal(Int32, String)`, whose caption names the signal. `SinkDispatcher.stage(for:)` maps it to `.pipeline` and never to `.publish`. A SIGKILL is not labelled memory: nothing distinguishes jetsam from another SIGKILL, and LOCAL16's marker rule stays the only memory route.
3. **One Python command-failure helper.** `failure_details.fail_command(command, error, *, operation)` runs `emit_failure`, emits `pipeline` / `command_failed` (`command`, `error_type`, `cause` from `describe`, `message` capped at 300 characters), and logs with the traceback. Call it from both `merge_meetings` handlers, `publish_from_paste`, `finalize`, `summarize`, and `__main__`'s generic `except Exception`, so any subcommand that lets an exception escape is covered. `run-all` keeps `run_failed`.
4. **run-all's missing secret exits 2.** Re-raise `MissingSecretError` from `orchestrate.main` as `summarize.main` does.
5. **`emit` never raises.** Move `_events_path()` inside the `try`.
6. **Typed transcript read.** `existing_daemon_transcript` distinguishes absent, unreadable (with errno or the decode error) and wrong backend; `_run_all_inner` raises a typed exception per case and does not emit, so `run_all`'s wrapper emits exactly one `run_failed` with that type as `error_type`.
7. **Carry the real error (SW-19).** A distinct `AppleIntelligenceError.transcriptUnreadable` carrying the underlying error; the last OS error appended to the escalation line and its `recording_error` event; a `Log.failure` on a present-but-unparseable reaper marker (skip if [LOCAL21](./LOCAL21.md) has deleted the reaper); `LibraryMover.inFlightReason` returns a reason naming the unreadable folder, so the move is refused.

## Explicitly not / out of scope

- User-facing titles and copy for these failures: UX93 (titles per operation), [UX86](./UX86.md) (plain-language strings). This task changes data, not wording, except the new signal caption.
- The escalation copy itself and the 4 GiB ceiling: [REC19](./REC19.md). Counting short write failures: REC22.
- Degraded successes (fallbacks, failed language repair): OBS2. Run id and stem on every row: OBS4.
- `_keychain_get` collapsing every `security` failure into absent: the SEC23 amendment.
- Branching on exit 2 in the daemon. It stays a generic failure; only the doc is made true.

## Acceptance

- Swift: `outcome` with `.uncaughtSignal` and status 3 yields `uncaughtSignal`, and `stage(for:)` maps it to `.pipeline` (the SIGQUIT collision pinned); with `.exit` and 3 it still maps to `.publish`. `PipelineFailureEvent.attributes` tests for a `reportedFailure` with metadata and a bare `nonZeroExit`. `transcriptUnreadable` on an unreadable file versus `emptyTranscript` on a blank one. `inFlightReason` on an unreadable directory returns non-nil.
- Python: `command_failed` emitted once for a failing `merge-meetings`, `publish-from-paste`, `finalize` and `summarize`, each with a `cause`; `mp run-all` with a missing managed secret exits 2 and still emits one `run_failed`; `events.emit` with an unwritable logs dir returns without raising; a corrupt `<stem>.json` fails with an unreadable type and exactly one `run_failed`.
- CONVENTIONS.md "Event log schema" documents `command_failed` and the new `pipeline_failed` attributes in the same commit.
- `cd pipeline && uv run --extra dev pytest -q`, ruff and pyright green; `cd daemon && swift test` green; `bash scripts/ci-local.sh` green. N new tests in the commit body.

## Amendment 2026-11-13 (audit band)

Added from the [field evidence](../../audits/2026-11-13-field-evidence.md) (work laptop, 2026-09-29 to 2026-11-13), "Pipeline and publishing" section, finding "The daemon event log cannot tell a published meeting from an empty skip, and names a failure by title only" (medium, observability gap; class key pipeline-and-publishing#6). Re-verified in code at HEAD (`3a2da4fc`) on 2026-11-13.

**Field evidence.** The single `pipeline_failed` row in the window (stem 20261022-103101, a 120 s Anthropic read timeout) carries a 27-character caption and no error class, stage or exit code; the class exists only in `pipeline_events.jsonl`. `daemon.log` named an exit code on 8 failure lines, all before 2026-09-14 (exit 1 seven times, exit 15 once), and on 0 since. `held_end_excluded` does not say how many segments the trim removed.

**When the exit code was lost.** Commit `06f646d8` (UX80, 2026-09-14) moved `LaunchError.nonZeroExit`'s `errorDescription` to `PipelineLauncher.failureCaption(stderr:)`, which is `FailurePresentation(diagnostics: stderr).title + "."`, and `.reportedFailure` to `FailurePresentation(...).title`. `SinkDispatcher`'s completion still emits `pipeline_failed` with only `"file"` and `"error": err.localizedDescription`, and its `daemon.log` line `"pipeline FAIL -> \(err.localizedDescription)"` lost the number at the same moment. The status is still in the error (`nonZeroExit(Int32, String)`, `reportedFailure(Int32, ...)`); it is just never written. So this is a regression of 2026-09-14, not a gap since filing.

**Held-end trim.** `SinkDispatcher` emits `transcription` / `held_end_excluded` with `file`, `trim_sec` and `audio_seconds` after `HeldEndTrim.apply(sidecar, at: trimAt)`; the following `engine_succeeded` carries only the post-trim `segments`, so the count removed is unrecoverable.

Correction at filing: item 1 above already specifies `exit_status`, `termination_reason`, `stage` and `cause`, so what this amendment adds is `error_type`, the `daemon.log` line, the trim counts and the regression date. The class also listed SEC38 to "drop the title from the row": the `error` value is a failure caption from `FailurePresentation`, not a meeting or window title, so [SEC38](./SEC38.md) does not cover it and the caption stays, as item 1 already says.

**Scope additions.**

1. Item 1's `PipelineFailureEvent.attributes` also writes `error_type`: the `LaunchError` case name (`nonZeroExit`, `reportedFailure`, `uncaughtSignal`, `timeout`, `mpNotFound`), or the Swift type name for an error that is not a launch error (the daemon's own transcription pass). The Python exception class stays in `pipeline_events.jsonl`'s `run_failed`; joining the two is [OBS4](./OBS4.md)'s run id.
2. The `daemon.log` `pipeline FAIL` line carries `exit=<status>` (or `signal=<n>`) and `stage=<stage>` again.
3. `held_end_excluded` adds `segments_before` and `segments_after`, the segment counts either side of `HeldEndTrim.apply`.

**Explicitly not (added).** An outcome on `pipeline_succeeded` (3 of 73 rows have a null `page_url` and are the no-speech and suspect-transcript skips): that is [UX90](./UX90.md)'s `publish_state`. A row at the mp spawn (`pipeline_started` precedes mp's `run_started` by a median 22.4 s and up to 408.2 s): [OBS4](./OBS4.md).

**Acceptance additions.**

- A `SinkDispatcher` or `PipelineFailureEvent` test: `nonZeroExit(1, ...)` yields a `pipeline_failed` row with `exit_status: 1`, `error_type: nonZeroExit` and a `stage`, and the `daemon.log` line names `exit=1`.
- A held-end trim test: a sidecar with segments past the trim point yields `held_end_excluded` with `segments_before` greater than `segments_after`, and `segments_after` equal to the written sidecar's count.
- CONVENTIONS.md "Event log schema" lists the new attributes in the same commit; `cd daemon && swift test` and `python3 scripts/truth_fences.py` green, new test count in the commit body.

**Progress (2026-11-19):** shipped. Two deliberate deviations from the spec text: the rows extend SEC38's `PipelineOutcomeLog.failureAttributes` rather than add a second builder, so the exit status keeps its existing key `exit_code` (not `exit_status`), and the `error` caption the spec says "stays" is gone from these rows, as SEC38 (which landed later) requires; `regenerate_failed` lost its caption the same way. The rows are written with `Log.event` plus the `pipeline FAIL` line rather than `Log.failure`, whose generic line would hide the exit and stage the amendment asks for. The reaper's malformed-marker report went in because LOCAL21 has not deleted the reaper.

## Amendment 2026-11-21 (second fix review)

Found by the [second fix review](../../audits/2026-11-21-second-fix-review.md) (tests report, M5), confirmed by reading the code at `8426758b`.

`failure_details.fail_command` emits `message=str(error)[:COMMAND_MESSAGE_CAP]` on the `command_failed` row. The daemon side of this task deliberately keeps error text out of its rows (SEC38). For a pydantic `ValidationError`, `str(error)` includes `input_value=` snippets, so a failed summarize, merge, paste-publish or finalize can write a fragment of a summary or transcript into `pipeline_events.jsonl`, which `mp logs` and Diagnostics show and which travels in field packs. `run_failed` already writes `error=str(e)`, so this is not new in kind. Scope: emit the classified cause and error type only, or a message built from a fixed vocabulary; apply the same to `run_failed`. Acceptance: a test that a validation error whose input contains a marker string leaves no marker in the emitted rows. Pipeline suite green, 1 new test.

**Progress (2026-11-26):** the amendment shipped. `fail_command` drops `message` (and `COMMAND_MESSAGE_CAP`); run-all's `run_failed` writes `cause` from `emit_failure`'s payload in place of `error`; the publish-stage `run_failed` drops the joined sink error text for `cause: publish` (the failed sink names were already on the publish `stage_completed`'s `failures`). Beyond the amendment's two sites, the same leak was closed in `stage_failed` (diarize cleanup, whose `message` could quote the model's reply), `finalize_failed` (`error`) and `publisher` / `sink_failed` (`error`, now `cause`). The text still reaches the log lines (stderr, plus `pipeline.log` for run-all) and, for a sink, `<stem>.publish.json`; neither is the event log. `prefetch_model`'s `error` is a stdout sentinel `ModelDownloadSupervisor` reads, not an event row, and was left. One new test (`test_no_failure_row_copies_the_error_text_into_the_event_log`, a `ValidationError` whose input carries a marker through all five row kinds).
