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

## Amended 2026-10-25 (performance review)

Review finding PYTHON-6 (finder medium, verifier confirmed medium), re-checked against `main` on 2026-10-25 in [mcp_serve.py](../../../pipeline/src/mp/mcp_serve.py) and [mcp_tools.py](../../../pipeline/src/mp/mcp_tools.py). Scope item 1 above makes `Library.allow_stems` return nothing under regulated mode, but that set never reaches `search_meetings`, so this task's acceptance as written would pass while search still serves the withheld text.

**The cache.** `Library.index(allow)` builds only `if self._index is None`, through `embed_index.load_or_build(self.root, self.index_dir, watchdog=watchdog, allow_stems=allow)`, and returns that object for the rest of the stdio session. `dispatch` computes `allow = library.allow_stems()` on every call, but `index()` uses it only for the first build. `mcp_tools.search_meetings` then ranks over that index and "never re-checks, and it must not, because a second check here would suggest the first is optional". The `Library` docstring states the intent the cache breaks: "a long-lived server holding a stale allowlist would keep exposing a meeting whose workflow the owner has since changed".

**What follows, for any session that outlives a change** (an MCP client keeps the server for its whole session):

- a meeting withheld after the first search (a workflow reassigned to NDA through WF8's Change workflow..., SEC21's re-stamp, or this task's global regulated check) keeps returning excerpts from `search_meetings`, while `get_meeting` and `get_transcript` correctly answer not-found;
- a meeting recorded after the first search never becomes searchable;
- `_call_tool` runs `dispatch` on a worker thread through `anyio.to_thread.run_sync`, and the SDK serves messages concurrently, so two first `search_meetings` calls both see `self._index is None`, load two MLX embedders and run two in-place saves into the same `index_dir` (the in-place save is the sibling task filed from this review, finding PYTHON-5 ([AI13](./AI13.md)));
- the e5 embedder is never released, so it stays resident for the session.

**Added scope.**

4. `Library.index` holds a `threading.Lock`. Under it, compare `embed_index.library_stem_fingerprints(self.root, allow_stems=allow)` with the cached index's `stems`, and refresh only when they differ (a stem added, removed, changed or newly withheld). Comparing in memory first matters: `refresh_index` always runs `_load_reusable`, which re-reads and parses the whole on-disk index even when the plan is a no-op.
5. An empty allowlist (this task's regulated case) returns zero results without building or refreshing, so a regulated session never rewrites the index `mp ask` shares in `DEFAULT_INDEX_DIR`.
6. A refresh that raises returns an error payload rather than falling back to the stale index. That keeps `search_meetings`' no-re-check rule true instead of adding a second filter beside it.
7. Release the embedder after each `search_meetings` call (`EmbeddingIndex.release_embedder`; `MLXEmbedder._ensure_loaded` reloads on the next call). If the measured reload is over about 2 s, an idle release is the alternative; the commit body records the figure.

**Added acceptance**, in `tests/test_mcp_serve.py` with the hashing embedder the file already pins:

- after one search, a meeting whose sidecar gains `workflow_nda_mode` returns no excerpt from the next `search_meetings` (fails on the current code);
- after one search, a newly written meeting appears in the next search's results (fails on the current code);
- under global regulated mode, `search_meetings` returns zero results and leaves the files in `index_dir` untouched (mtimes unchanged);
- two concurrent first searches on one `Library` call `load_or_build` once (counting fake);
- a second search with no library change does not call `load_or_build` at all;
- the embedder's `release` runs once per search.

**Owner note.** [AUTO3](./AUTO3.md) sits in [owner-verification.md](../owner-verification.md) as `simple`, and this is a defect in what AUTO3 shipped rather than a regression. Proposal for the owner: do not close AUTO3 on its walkthrough while added scope items 4 to 6 are open.
