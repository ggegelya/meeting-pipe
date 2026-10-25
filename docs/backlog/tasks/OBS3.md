# OBS3: failure events carry only a caption, a signal death is read as an exit code, and three pipeline commands fail with no event at all

Band origin: filed 2026-10-25 from the 2026-10-25 observability audit band ([audit](../../audits/2026-10-25-observability-audit.md) row O9; finders FB-7, PY-8, PY-9 run-all half, PY-10, PY-11, SW-19). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

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
