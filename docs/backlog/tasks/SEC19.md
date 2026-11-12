---
id: SEC19
title: The pipeline's egress guard is a monkeypatch on httpx's transport classes, so any network path that is not httpx bypasses regulated and NDA mode
category: Security
status: new
priority: P2
comment: Filed 2026-10-24 (audit band, arch S3, go-live PP-1 structural half): egress_guard patches only httpx transports, kept valid by the anthropic<1 and httpx<1 caps CI8 added; a urllib, requests or httpx2 path would egress under regulated mode silently. Add a socket.connect loopback-only layer in arm(), keep the httpx patch for the error message, fix the docstring; caps lifted later in a separate lock bump. Amended 2026-11-12 ([security review](../../audits/2026-11-12-security-review.md)): the loopback client honours HTTP_PROXY and macOS web proxies and the guard checks only the URL host; trust_env=False on loopback clients, refuse proxied transports. [Spec](./SEC19.md) Amended 2026-11-12 (upgrade review): huggingface-hub 2.x also moves to httpx2 and a plain lock refresh crosses it unflagged (SEC31 holds it below 2 meanwhile); the anthropic 2.x lift also sends API version 2026-10-21, which 400s the temperature PIPE12 sends.
---

# SEC19: the pipeline's egress guard is a monkeypatch on httpx's transport classes, so any network path that is not httpx bypasses regulated and NDA mode

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) S3, structural half of [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) PP-1). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

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

## Amended 2026-11-12 (security review)

From the [security review](../../audits/2026-11-12-security-review.md) finding 8 (verified, Low; confidence 7 for the mechanism, 4 for a real leak). A bypass inside httpx itself, which this task's text treats as covered:

- `summarize_local`'s `httpx.Client(...)` sets no `trust_env=False`, and nothing under `pipeline/src/mp/` mentions `trust_env` or proxies. httpx 0.28.1's `get_environment_proxies` reads `urllib.request.getproxies()` (env vars, else the macOS system web proxy via `_scproxy`) and never excludes 127.0.0.1 or localhost unless `NO_PROXY` names them; the macOS bypass list is dropped.
- With the guard armed, a simulated proxy received the request, because `egress_guard` checks `request.url.host`, not where the transport connects.
- The transcript POST happens only after `GET /v1/models` through the same proxy returns 200; a normal forward proxy answers 502/403 for loopback, so in practice the local backend breaks and only a content-free GET reaches the proxy. PAC/WPAD setups never trigger the routing. The owner's Mac had no proxy on 2026-11-12.

Added scope: `trust_env=False` on every loopback client (`LocalSummaryClient`, the embedder client if any), and the armed guard refuses a request whose transport has a proxy configured. The socket-layer item above would catch the armed case but not the normal-mode routing, so both are needed.

Added acceptance: a test with `HTTP_PROXY` set that the loopback client's transport for `http://127.0.0.1:<port>` is not a proxy transport, and that the armed guard raises when handed a proxied transport.

## Amendment 2026-11-12 (upgrade review)

Two findings from the 2026-11-12 dependency review land here, because both are consequences of the httpx-only guard this task replaces.

**1. huggingface-hub 2.x is a second httpx2 crossing, and the fence does not see it.** A scratch `uv lock --upgrade-package` of the vulnerable transitive packages, with no extra constraint, moved `huggingface-hub` 1.12.0 to 2.4.0. That brought in `httpx2` 2.16.0, `httpcore2` and `truststore`. The CI8 fence, `test_the_anthropic_sdk_still_sends_through_the_patched_httpx`, asserts only that the Anthropic client is an `httpx.Client`, so it stayed green. What still holds is `egress_guard`'s forced `HF_HUB_OFFLINE=1` / `HF_HUB_DISABLE_TELEMETRY=1`, a cooperative flag rather than an enforced block. SEC31 adds `[tool.uv] constraint-dependencies = ["huggingface-hub<2"]` as the stopgap.

Added scope:
- Once the socket-layer item ships, lift that constraint in the same commit that proves the socket layer refuses a non-loopback connect from `huggingface_hub`.
- Until then, extend the fence to assert `huggingface_hub`'s HTTP backend type as well.

**2. The cap lift has two traps beyond the transport.**
- **anthropic 1.x is built on httpx2.** Every `httpx.MockTransport` handed to the SDK in tests must re-base onto `httpx2`, or those tests stop exercising the SDK.
- **anthropic 2.x (2.8.0 on 2026-11-12) sends `anthropic-version: 2026-10-21`.** That version returns a 400 for `temperature`, `top_p` or `top_k` on every model, even at default values. `AnthropicSummaryClient` sends `temperature=SAMPLING_TEMPERATURE` through `anthropic_sampling` (PIPE12's repeatability decision), so a 2.x lift fails every cloud summary unless that decision is revisited in the same change.

Added acceptance: the cap-lift commit carries a test that the summarize request body has no sampling parameters when the SDK sends `2026-10-21`, and no `httpx` object crosses into the SDK.
