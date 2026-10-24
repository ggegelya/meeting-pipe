# SEC19: the pipeline's egress guard is a monkeypatch on httpx's transport classes, so any network path that is not httpx bypasses regulated and NDA mode

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) S3, structural half of [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) PP-1). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

`egress_guard.arm` (SEC3, hardened by SEC13) replaces `httpx.HTTPTransport.handle_request` and `httpx.AsyncHTTPTransport.handle_async_request` with wrappers that raise `EgressBlocked` for a non-loopback host. Its module docstring states the premise: "httpx is the single in-process chokepoint: the Anthropic SDK, the Notion publisher, and the local-model client all route through httpx's default transport classes". That premise holds only as long as every network client in the process is httpx, and the repo already pays to keep it true:

- `pipeline/pyproject.toml` caps `"anthropic>=0.40.0,<1"` and `"httpx>=0.27.0,<1"`, with the CI8 comment that anthropic 1.0.0 (2026-08-20) "swapped httpx for httpx2, and `egress_guard` patches httpx's transports and nothing else, so an SDK on httpx2 sends around the regulated-mode firewall". `uv.lock` resolves anthropic 0.97.0 and httpx 0.28.1 on 2026-10-24.
- The Hugging Face stack (mlx_embeddings, `mlx_lm.server`'s model load) speaks `requests`, which the patch never sees; the guard reaches it only through `HF_HUB_OFFLINE` in the environment (point 3 of the docstring).

So CI8 closed the immediate hole (the go-live PP-1 caps half) by pinning, and the control is still at the wrong layer: a new dependency, a transitive one switching clients, or a stdlib `urllib`/`http.client` call in a future module egresses under regulated mode with no error. On 2026-10-24 `pipeline/src/mp` imports no `urllib.request`, `requests`, `socket` or `http.client` itself (`markdown.py` imports only `urllib.parse.quote`), so nothing bypasses today; the gap is that nothing would stop it.

## Scope

1. In `egress_guard.arm`, add a second, library-agnostic layer: patch `socket.socket.connect` and `socket.socket.connect_ex` (which `socket.create_connection`, `http.client`, `urllib`, `requests`/urllib3 and httpcore all reach) so that, while `_armed`, an `AF_INET`/`AF_INET6` connect to an address that is not loopback raises `EgressBlocked`. `AF_UNIX` passes untouched. A hostname in the address tuple is resolved with `getaddrinfo` and allowed only when every result is loopback, so `localhost` keeps working for `mlx_lm.server` on 127.0.0.1. Roughly 30 lines; installed once like the httpx patch, inert after `disarm()`.
2. Keep the httpx patch: it raises before a connection opens and names the host in the message, which is the error the user sees. The socket layer is the backstop for everything else.
3. Fix the module docstring so it describes two layers and stops calling httpx "the single in-process chokepoint".
4. The cap comment in `pyproject.toml` is updated to say the guard no longer depends on it; lifting the caps is a separate lock bump (below).

## Explicitly not

- Lifting the `anthropic<1` / `httpx<1` caps. That is a lock bump with its own SDK-migration risk (CI8's history), done in its own commit after this lands, and only then.
- Subprocesses. A socket patch cannot reach a child; children are covered by `child_env()`'s token scrub plus `HF_HUB_OFFLINE`, and the CLI-spawning backend refuses to run when armed (SEC20 covers that spawn).
- File-based egress (synced folders, BYO, backups): SEC18. The MCP surface: AUTO6.
- DNS lookups themselves. Resolving a name sends no meeting content; the connect is what is gated.

## Acceptance

- `tests/test_egress_guard.py` gains, with the guard armed:
  - a `urllib.request.urlopen("http://example.invalid/")` (with `getaddrinfo` stubbed to a public address) raises `EgressBlocked` before any packet leaves;
  - a raw `socket.create_connection(("93.184.216.34", 80))` raises `EgressBlocked`;
  - a connect to `127.0.0.1` and to `localhost` on a listening test socket succeeds;
  - an `AF_UNIX` socket pair connects;
  - after `disarm()`, the raw connect to a public address is attempted (stubbed downstream), proving the patch is inert.
- The existing httpx tests stay green unchanged, and the existing fence that fails when a resolve crosses the caps stays in place until the separate bump.
- `cd pipeline && uv run --extra dev ruff check src tests`, `uv run --extra dev --extra mcp pyright`, `uv run --extra dev pytest -q` green, new test count in the commit body; `bash scripts/ci-local.sh pipeline` green.
