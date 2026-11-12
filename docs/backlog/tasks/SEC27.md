---
id: SEC27
title: The local mlx_lm.server loads and executes whatever model a request names, floats Hugging Face `main` on every start, and is reused when anything else holds its port
category: Security
status: new
priority: P1
comment: Filed 2026-11-12 ([security review](../../audits/2026-11-12-security-review.md) findings 1, 2, 7): unauthenticated server on 127.0.0.1:8765 with CORS * loads the body's model/draft_model/adapters and exec_module's a config.json model_file, so a sandboxed app, another account or a browser page gets code execution while it runs; every online start re-resolves HF main; a non-mlx listener is reused. Serve a pinned local snapshot offline, pin the three fields behind a per-spawn token, fail closed on a foreign listener. P1 as a broken local-first safety promise; owner may re-band. [Spec](./SEC27.md)
---

# SEC27: the local mlx_lm.server loads and executes whatever model a request names, floats Hugging Face `main` on every start, and is reused when anything else holds its port

Band origin: filed 2026-11-12 from the [2026-11-12 security review](../../audits/2026-11-12-security-review.md), findings 1, 2 and 7, merged because they share one fix. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

All three were confirmed by reading the installed mlx-lm 0.31.3 (pinned in `uv.lock`) and huggingface_hub 1.12.0 in `pipeline/.venv`, and one leg by a throwaway offline probe on a spare port on 2026-11-12.

**1. Request-chosen model, executed.** `summarize_local.build_server_command` launches `mlx_lm.server` with `--prompt-cache-size`, `--model`, `--host`, `--port` and optionally `--adapter-path`, nothing else. In mlx_lm's `server.py`:

- `--allowed-origins` defaults to `"*"`, so every response carries `Access-Control-Allow-Origin: *`. There is no auth and no Host-header check (DNS rebinding applies).
- `do_POST` calls `json.loads(raw_body)` without looking at Content-Type, so a browser `text/plain` POST is a simple request with no preflight.
- `self.requested_model = self.body.get("model", "default_model")`, plus `draft_model` and `adapters` from the body, reach `ModelProvider.load`. Only the literal `"default_model"` maps to the CLI `--model`; any other string goes to `utils.load`.
- `utils._download` uses a path as-is if it exists, else `snapshot_download(..., allow_patterns=[..., "*.py", ...])`.
- `utils.load_model` runs `if (model_file := config.get("model_file")) is not None: ... spec.loader.exec_module(arch)`. `trust_remote_code` does not gate this path. The only precondition is one valid `model*.safetensors`.

The probe (`HF_HUB_OFFLINE=1`, port 18765, `Content-Type: text/plain`, `Origin: https://evil.example`, `"model":"nonexistent-org-zz/probe-repo-zz"`) returned `Access-Control-Allow-Origin: *` and the Hub's "Cannot find an appropriate cached snapshot folder" error, proving the body's model id reaches the downloader.

Who gains what: an unsandboxed same-user process gains nothing new (it can already read the Keychain items through `/usr/bin/security`). A sandboxed app with the network-client entitlement, another local account (via `/Users/Shared`), or a web page in a browser without a local-network prompt gets code execution as the owner. Chrome 142+ prompts for local network access; Safari and Firefox were not tested. Outside an armed run the lazily spawned server carries all managed tokens (`egress_guard.child_env` passes the full environment when unarmed); the warm `serve-local` still carries `OPENAI_API_KEY`.

Exposure window: the lazy spawn idles 300 s (`DEFAULT_IDLE_TIMEOUT_SEC`) after any on-device call (local backend, `auto` fallback, NDA and regulated runs, diarization cleanup, Ask on local); the warm server runs for the daemon's lifetime when "preload local model at launch" is on. Armed runs set `HF_HUB_OFFLINE`, which blocks the repo-id variant but not the local-path one.

**2. Floating `main` at serve time.** `build_server_command` passes the bare repo id (default `mlx-community/Qwen2.5-7B-Instruct-4bit`, `config.py` `local_model`). mlx_lm calls `_download(path_or_hf_repo, revision=None)`, and huggingface_hub's `snapshot_download` makes a `repo_info` call whenever not offline, writes `refs/main` and fetches missing files including `*.py`. SEC11 (done, record in `q5-final.md`) pinned only `prefetch_model`, so any commit to the configured repo (an open community org) runs on the next unarmed server start. Related functional bug: a sha-pinned prefetch writes no `refs/main`, so a machine that only ever ran `mp prefetch-model` can fail an offline (armed) load while `model_is_cached` reports True. The owner's cache already holds a `refs/main` for the 3B model, meaning an unpinned online resolve has happened here.

**7. Fail-open reuse.** `LocalSummaryClient._ensure_running` returns early when `_is_healthy()` (any 200 on `GET /v1/models`) and `_reuse_is_safe()`. `local_server.served_identity` returns `None` ("unknown, reuse") when `lsof` names a pid whose argv lacks `mlx_lm.server`, and `ServedIdentity.matches` returns True when `model is None`. So whatever binds the port while it is idle (the default, preload off) receives every transcript, NDA runs included, and writes the summary, with nothing in the run sidecar to show it. The realistic attacker is a sandboxed same-user app that may listen on loopback but cannot read `~/Documents`.

## Scope

1. **Serve a pinned local snapshot, always offline.** Pin a reviewed commit sha per shipped model preset in code (beside the presets). `prefetch_model` downloads that sha; `build_server_command` passes the resolved `snapshots/<sha>` directory as `--model` (and the adapter as a local path), and the server child always runs with `HF_HUB_OFFLINE=1`. Refuse to start (a typed error naming the snapshot) when the snapshot's `config.json` has a `model_file` key or the snapshot contains any `*.py`. `model_is_cached` checks the pinned snapshot, which fixes the missing-`refs/main` bug. A custom `local_model` the owner types keeps working but is resolved to a sha once at prefetch and recorded in config, never re-resolved at serve time.
2. **Pin what a request can load.** Launch the server through a small `mp` entry (seam: `build_server_command`, a new module beside `local_server.py`) that imports `mlx_lm.server`, wraps `ModelProvider.load` to refuse any `model`, `draft_model` or `adapters` other than the configured ones, requires a per-spawn random bearer token (passed by env, never argv) on every request, rejects any request with an `Origin` header or a Host other than `127.0.0.1:<port>`, and passes `--allowed-origins` with no origins. `LocalSummaryClient`, `mp serve-local` and the daemon's `LocalModelPreloader` send the token. CORS alone is not the fix: a blind POST has its side effect whether or not the response is readable.
3. **Fail closed on a foreign listener.** `served_identity` distinguishes "identified, not mlx_lm.server" from "could not identify"; the first is a mismatch (refuse to reuse, raise a typed error naming the pid's command), always, not only when armed. With item 2 in place, a server that does not accept this spawn's token is never reused.
4. **Strip tokens from the server child.** The server child gets no managed token in any mode (it never needs one), in both the lazy spawn and `LocalModelPreloader`.

## Explicitly not

- Moving to a daemon-owned server: [LOCAL21](./LOCAL21.md). If LOCAL21 lands first, items 2 to 4 move to its single owner and item 3's `_reuse_is_safe` disappears with it; the acceptance below still applies.
- Proxy routing of loopback requests: [SEC19](./SEC19.md)'s 2026-11-12 amendment.
- Upgrading mlx-lm in the hope upstream fixes it: a lock bump is separate, and items 2 and 3 must hold against 0.31.3.
- The embedder (`embed_index.MLXEmbedder`) floating `main`: mlx_embeddings 0.1.0 has no `exec_module` path, so it is weights integrity only, listed in [DIST7](./DIST7.md).

## Acceptance

- `test_summarize_local.py` / `test_local_server.py`: `build_server_command` passes a `snapshots/<sha>` path, never a bare repo id; the spawn env has `HF_HUB_OFFLINE=1` and no managed token, armed or not; a snapshot with `model_file` in `config.json` or a `*.py` file raises the typed refusal; `model_is_cached` is True for a pinned snapshot with no `refs/main`.
- A test of the shim with a fake `ModelProvider`: a request naming another `model`, `draft_model` or `adapters` is refused before `load` is called; a request without the token, with an `Origin` header, or with a foreign Host is refused; the configured model with the token succeeds.
- `served_identity` / `_reuse_is_safe` tests: an `lsof` result naming a non-mlx command refuses reuse; an unidentifiable listener keeps today's behaviour only if item 2's token check also passes.
- `cd pipeline && uv run --extra dev pytest -q`, ruff and pyright green with the new test count in the commit body; `swift test` green if `LocalModelPreloader` changes; `bash scripts/ci-local.sh` green.
- Owner check (confirms): with the warm server up, `curl -s -X POST -H 'Content-Type: text/plain' --data '{"model":"x/y","messages":[{"role":"user","content":"hi"}]}' http://127.0.0.1:8765/v1/chat/completions` is refused without reaching the downloader, and a normal local summary still completes.
