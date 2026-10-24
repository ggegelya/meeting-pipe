# AUTO6: the MCP server ignores global `regulated_mode`, so meetings recorded before regulated mode was switched on stay readable by a cloud MCP client

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) S5). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Latent on the owner's Mac: `config.toml` has no `[mcp]` table (so `mcp.enabled` is its default `false`) and `regulated_mode = false`, checked 2026-10-24.

AUTO3 (shipped, in [owner-verification.md](../owner-verification.md)) made `visibility.withheld_reason` the single gate for "may this meeting be handed to something outside meeting-pipe". It is fail-closed per meeting: it withholds `nda` (`workflow_nda_mode` in the sidecar), `regulated` (`regulated_mode` in the sidecar, stamped at record time by TECH-DSN6) and `no_sidecar`. It never looks at the global flag; it takes only `(root, stem)` and is deliberately config-free.

That is right for `mp ask` and `mp digest`, because their own process is clamped: `entry.prepare` arms the egress guard and `effective_backend` pins the on-device engine whenever global regulated mode is on, so nothing they retrieve leaves. It is wrong for `mp mcp-serve`, because the MCP module docstring's own point is that "here the *client* chooses what to pull, and anything it pulls has reached a cloud provider by definition, outside the in-process guard". So with `regulated_mode = true` and MCP enabled:

- every meeting recorded while regulated mode was off has a sidecar without `regulated_mode`, so `withheld_reason` returns `None` and `Library.allow_stems` (`visibility.visible_stems(self.root)`) serves it;
- `mcp_serve.main` starts normally (`entry.prepare(secrets=False)` arms the guard, which protects only this process), and `status` reports those meetings as visible in Preferences.

A second, smaller gap: `cfg` is loaded once in `main` and held by `Library` for the life of the stdio server, which an MCP client keeps running for its whole session. Switching regulated mode on in Preferences does not reach a server that is already running.

## Scope

1. In `Library.allow_stems` (`mcp_serve.py`), re-read the config on each call (`Config.load()`, a small TOML read) and return an empty set when `config.zero_egress(cfg)` is true. Per call, not per start, so a running server stops serving the moment the flag flips. `visibility` itself stays config-free; the global check sits at the MCP boundary, which is the only caller whose output leaves the process unclamped.
2. `mcp_serve.main` refuses to start while global regulated mode is on, on the same path as the `disabled` refusal: `events.emit("pipeline", "mcp_serve_refused", reason="regulated")` and a stderr line naming the setting. Belt and braces with step 1.
3. `status` reports the regulated state: under regulated mode `visible` is 0 and `withheld_by_reason` carries a new `regulated_global` reason with the full count, and `MCPStatusStore`'s reason text gains a case for it (for example "N hidden while regulated mode is on"). The reason strings are a Swift-facing contract (the `visibility` comment says so), so both sides change in one commit.

## Explicitly not

- Changing `mp ask` and `mp digest`; their process-level clamp already covers them.
- Re-stamping old sidecars with `regulated_mode` when the global flag is switched on. That would also change reprocess behaviour after the flag is turned off again, a different decision; the per-call check gives the same protection without touching meeting files. SEC21 re-stamps for NDA workflows, a separate case.
- Paging, tool shapes, or any other MCP behaviour (AUTO5).

## Acceptance

- `tests/test_mcp_serve.py` gains:
  - with global `regulated_mode = true` and a library of two meetings whose sidecars carry no policy flags, `Library.allow_stems()` is empty and a `get_meeting` dispatch for one of them returns the same not-found payload as a stem that never existed;
  - flipping the config file to regulated mode between two `allow_stems()` calls on one `Library` changes the result from both stems to none;
  - `main([])` under regulated mode with MCP enabled returns non-zero and emits `mcp_serve_refused` with `reason="regulated"`;
  - `status()` under regulated mode reports `visible: 0` and `withheld_by_reason == {"regulated_global": 2}`.
- A Swift test that `MCPStatusStore` renders the new reason.
- The new `regulated_global` reason is named in the `visibility` module beside the other `WITHHELD_*` constants; `python3 scripts/truth_fences.py` (CI5) clean.
- ruff, pyright (with `--extra mcp`), `pytest -q` and `swift test` green, new test counts in the commit body.
