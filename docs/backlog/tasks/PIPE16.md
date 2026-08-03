# PIPE16: `require_env`'s `sys.exit(2)` escapes run-all's handlers, so a publish-stage secret failure leaves the row reading "Ready"

Filed 2026-08-03 by the audit band. Proposed high, downgraded to medium by an independent skeptic on the recovery available to the user.

## What is wrong

`require_env` calls `sys.exit(2)` from inside `publish_router._build_one`. `SystemExit` derives from `BaseException`, not `Exception`, so it passes straight through both of orchestrate's handlers, skipping the `run_failed` event, the exit-3 mapping and the `<stem>.publish.json` write. The daemon then sees exit 2 over a meeting whose summary is already on disk.

- `pipeline/src/mp/config.py:458` is `sys.exit(2)` inside `require_env`, called as library code rather than from a CLI main.
- `pipeline/src/mp/publish_router.py:82` is `token = require_env("NOTION_TOKEN")`, reached from `build_publishers`, which `fanout` calls at `publish_router.py:135` before any publisher runs and before `_write_publish_sidecar`.
- `pipeline/src/mp/orchestrate.py:275` and `:766` are both `except Exception`, so the `run_failed` emit at `:276` and the `return EXIT_PUBLISH_FAILED` at `:774` are both unreachable on this path. Verified by running the same try/except/finally shape under uv: `SystemExit escaped main with code: 2`.
- `daemon/Sources/MeetingPipe/Coordination/SinkDispatcher.swift:469` maps only exit 3 to `.publish`; exit 2 falls to `.pipeline`, whose retry re-runs the summarizer instead of republishing the summary already on disk.
- `daemon/Sources/MeetingPipe/MeetingStore.swift:578` makes a row `.done` when a summary is present, and `:553` suppresses the failure sidecar entirely in that case, so the durable row settles on **"Ready"** for a meeting that published nowhere.

This also contradicts the module's own stated contract at `publish_router.py:5`, that one sink's failure must not abort the rest: a missing `NOTION_TOKEN` kills the Obsidian and filesystem sinks configured alongside it.

## The skeptic's narrowing, recorded

The user is not left entirely in the dark at the time: the notification body carries the full "$NOTION_TOKEN is not set" stderr tail, and both the row context menu and the detail toolbar offer a summary-only Republish, so recovery is cheap. The surviving harm is a wrong **durable** row plus a lost publish sidecar, not a silent failure with only an expensive retry. Note the repo already pins this behaviour as intended for the summarize path at `pipeline/tests/test_summarize_backend.py:51-59` ("require_env raises SystemExit(2) by design, fail-fast for missing secrets"), so the fix must not break that intent at the CLI boundary.

## Scope

Make `require_env` raise a named exception (`MissingSecretError`) instead of calling `sys.exit`, and let each `main` translate it to the exit code that command owes: 2 at the CLI boundary, preserving the fail-fast intent the existing test pins, and `EXIT_PUBLISH_FAILED` from the publish stage in `orchestrate`, `publish_cmd`, `publish_from_paste` and `merge_meetings` after recording the outcome, so the row gets the publish-only retry it deserves.

The alternative, and it is worth considering as the smaller change: have `build_publishers` treat an unreadable required token the way it already treats an empty `obsidian.vault_path`, warn and skip that sink, so the others still run. That honours `publish_router.py:5`'s stated contract directly.

## Acceptance

Suite green with new tests. A test drives a publish stage with a required secret missing and asserts the process exits 3, emits `run_failed`, writes `<stem>.publish.json`, and that the other configured sinks still ran. The existing `test_summarize_backend.py` fail-fast expectation still passes.
