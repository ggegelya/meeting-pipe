# LOCAL21: `mlx_lm.server` has two owners, the short-lived `mp` and the daemon, and about 900 lines of lifecycle and `lsof`/`ps` identity probing exist to reconcile them

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) A11). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Re-verified against `main` at `45b8c6a` on 2026-10-24.

**Owner one, Python.** Every `LocalSummaryClient` (summarize, cleanup, ask and digest through `engine._complete_local`, dogfood, the staged summarizer) calls `_ensure_running`, which health-checks the port and otherwise runs `_spawn`: `subprocess.Popen(build_server_command(...), preexec_fn=os.setsid, env=egress_guard.child_env())`, then writes the LOCAL10 marker. An idle `threading.Timer` and `close()` kill it. Because `mp` is short-lived and the server is detached, every abnormal exit of `mp` leaks it (PIPE22 is the SIGTERM case; SIGKILL from the watchdog is LOCAL10's).

**Owner two, the daemon.** `LocalModelPreloader` (180 lines) spawns `mp serve-local` when the user opts in, restarts it on a model or adapter change (`decide(running:desired:)`, LOCAL11), and stops it on quit. `LocalServerReaper` (146 lines) reaps a server whose marker names a dead owner, probing liveness through a `Process` running `/bin/ps`.

**Reconciliation between them.** `pipeline/src/mp/local_server.py` (379 lines) exists so each owner can tell whose server is on the port and what it serves: `listening_pid` runs `lsof -nP -iTCP:<port> -sTCP:LISTEN -t`, `pid_command` and `parse_identity` read the server's argv through `ps`, `served_identity` falls back to the marker, `terminate_server` and `orphaned_server` act on it. `LocalSummaryClient._reuse_is_safe` and `_owns` (summarize_local.py) then decide whether a mismatched warm server may be killed ("it is not ours to restart"). With the preloader, reaper, `local_server.py` and the client's lifecycle methods, this is roughly 900 lines whose only job is that two processes share one resource without a long-lived owner.

**Constraints a new owner must keep.**

- Off by default: `LocalModelPreloader` warms a model only on opt-in, because a warm model stays resident in RAM. On-demand ownership needs an idle stop of its own.
- Zero egress: the server's env comes from `egress_guard.child_env()` (no cloud tokens, `HF_HUB_OFFLINE=1` under a zero-egress run), and `_spawn` refuses an uncached model under an armed guard with the "not in the local HuggingFace cache" phrase Swift's `Meeting.failureSuggestsModelDownload` matches. The per-call spawn arms per meeting, so an NDA meeting's server is pinned offline. `mp serve-local` arms with no meeting anchor (`entry.prepare(secrets=False)`), so a library-wide server is pinned only under global regulated mode. A single long-lived owner serving an NDA meeting must keep that property: pin offline whenever the model is already cached, or restart into a pinned server for a zero-egress job.
- RAM: `resource_guard.require_model_fits` refuses a model this Mac cannot hold, before the load.
- Two lanes: a run-all and an `mp ask` can overlap, and `mp ask --model` can request a model other than the summary's.
- Owner benches: LOCAL13's and LOCAL14's walkthroughs in `owner-verification.md` run `mp dogfood` across several models from a terminal with no daemon involved. Neither has been run yet.

## Scope

1. **The daemon is the only owner.** A daemon-side server supervisor (growing out of `LocalModelPreloader`) starts the server on demand before spawning an `mp` that needs it, restarts it on a model or adapter change, stops it after an idle period and on quit, and keeps the RAM refusal, the cache refusal and the zero-egress env (most simply by spawning `mp serve-local`, which already carries the first two, with the per-meeting pinning from the constraints above added). It knows what it started, so it hands the served identity to each `mp` spawn in the environment; no `lsof` or `ps` is needed to learn it.
2. **Python only connects.** `LocalSummaryClient` runs with the existing `manage_subprocess=False` mode when spawned by the daemon: no spawn, no marker, no idle timer, no kill. With no server reachable it fails with a typed "local model server not running" error that the daemon handles by starting the server and retrying the spawn once.
3. **A CLI path for development.** Outside the daemon (no identity in the env), `mp` keeps working for the owner's benches: either `mp serve-local` in a second terminal plus connect-only clients, or a dev-only spawn path. Whichever is chosen, the LOCAL13 and LOCAL14 walkthroughs and `docs/spikes/local13-local-model-refresh-bench.md` are updated in the same commit, or this task waits until both benches have run.
4. **Delete what the single owner makes dead.** The marker, `LocalServerReaper`, `local_server.listening_pid` / `pid_command` / `parse_identity` / `orphaned_server`, `_reuse_is_safe`, `_owns` and the Python idle timer, as each becomes unreachable. `mp doctor`'s orphan report goes with the marker.

## Explicitly not

- PIPE22's SIGTERM handler. It lands first and stays useful; after this task it no longer has a server to clean up, but every other `finally` still benefits.
- Splitting `summarize_local.py` (PIPE21). Do this first; PIPE21's lifecycle split then shrinks to almost nothing.
- MLX in-process in Swift (I7 and LOCAL12's NO-GO). Python keeps serving the model.
- Concurrency of two models at once. If an ask needs a different model while a summary is running, it queues behind it or fails with a clear message; serving two models is a separate decision.

## Acceptance

- Swift tests for the supervisor's pure decision (start, restart, idle stop, no-op) on injected clocks and identities, extending `LocalModelPreloaderTests`, including: opted-out user with a local job starts the server for the job and stops it after the idle period; a model change while idle restarts nothing until the next job.
- Python tests: a daemon-spawned client (identity in env) never calls `_spawn` and raises the typed error when the port is closed; the CLI path in item 3 still summarizes against the fake `mlx_lm.server`.
- A daemon test that the typed "not running" failure triggers exactly one start-and-retry, and a second failure surfaces as a normal failure row.
- A test that a zero-egress job (regulated, or an NDA workflow) runs against a server whose env has `HF_HUB_OFFLINE=1` and no cloud tokens, whichever way item 1 achieves it.
- A Cancel and a watchdog kill of `mp` during a local summary leave the server owned and either idle-stopped or reused, never orphaned (the PIPE22 scenario, now structurally impossible).
- `cd daemon && swift test` and `cd pipeline && uv run --extra dev pytest -q`, ruff and pyright green, new test counts in the commit body; `bash scripts/ci-local.sh` green. `ARCHITECTURE.md`, `CONVENTIONS.md` (the marker schema leaves) and the README's local-model section updated in the same commit.
- Owner walkthrough after install (confirms, not a gate): with the local backend and preload off, record a short meeting; `ps` shows one `mlx_lm.server` during the summary and none a few minutes after.

## Amended 2026-10-25 (performance review)

Review finding PYTHON-13 (confirmed, low) adds a leg the single owner inherits. Re-checked against `main` at `01e904a` on 2026-10-25.

`mp serve-local` opens `mlx-server.log` through `local_server.open_server_log`, which calls `events.rotate_if_needed(path)` once, before `path.open("ab")`; `serve-local` then `os.dup2`s that descriptor onto stdout and stderr and `os.execvpe`s `mlx_lm.server`, which holds it for as long as it runs. Rotation happens only when some process opens the file, so today the 5 MiB cap is enforced only by the per-run spawns in `LocalSummaryClient._spawn`, and when one of them rotates, the warm server keeps writing into the renamed generation (and, once that generation is rotated out and unlinked, into space that is not reclaimed until the server exits). Scope item 2 stops daemon-spawned `mp` from spawning at all, so after this task nothing rotates the file while the supervisor's server runs for the daemon's lifetime. The volume is modest: `build_server_command` passes no log level, and `mlx_lm.server` 0.31.3 (the `uv.lock` pin) defaults `--log-level` to `INFO`, which logs prompt-processing progress and prompt-cache stats per completion, plus `BaseHTTPRequestHandler`'s access lines (it does not override `log_message`); the verifier put it at KB per meeting. Latent on the owner's Mac on 2026-10-25: the backend is `anthropic` and there is no `mlx-server.log`.

Added scope:

- `build_server_command` passes `--log-level WARNING`, so exceptions and Metal OOM tracebacks (LOCAL16's postmortem value) still reach the log while the per-request INFO lines do not; the access lines remain and are small. This applies to every spawn path, before or after the ownership change.
- The supervisor's every start and restart goes through `mp serve-local` (or another path that calls `open_server_log`), so each one rotates the log at open. Say so where the supervisor spawns, so a later change that execs `mlx_lm.server` directly does not silently drop the bound.

Added acceptance:

- pytest: `build_server_command` includes `--log-level WARNING`, and the fake `mlx_lm.server` tests accept it.
