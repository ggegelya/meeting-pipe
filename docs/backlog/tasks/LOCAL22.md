# LOCAL22: mlx_lm.server runs with its default prompt cache of ten full KV caches and no byte cap, so a warm server keeps gigabytes of finished requests resident for the daemon's lifetime

Band origin: filed 2026-10-25 from the performance review (eight subsystem finders over HEAD 01e904a, every finding adversarially re-verified). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Review finding PYTHON-1 (finder high, verifier confirmed high). Re-checked against `main` on 2026-10-25.

**What the server is started with.** `summarize_local.build_server_command` is the one argv builder for both the per-run spawn (`LocalSummaryClient._spawn`) and the daemon's warm server (`summarize_local.main`, which is `mp serve-local`), and it emits only `cmd + ["--model", model, "--host", host, "--port", str(port)]`, plus `--adapter-path` when an adapter is configured ([summarize_local.py](../../../pipeline/src/mp/summarize_local.py)).

**What mlx-lm does with no flags.** In the locked mlx-lm 0.31.3 (`mlx_lm/server.py` in the pipeline venv): `--prompt-cache-size` defaults to 10 ("Maximum number of distinct KV caches to hold in the prompt cache"), `--prompt-cache-bytes` has no default, and the server builds `LRUPromptCache(model_provider.cli_args.prompt_cache_size)`, whose constructor (`mlx_lm/models/cache.py`, `LRUPromptCache.__init__`) defaults `max_bytes: int = 1 << 63`. After every completion it calls `self.prompt_cache.insert_cache(self.model_provider.model_key, cache_key, cache)`, storing a full KV copy of prompt plus generation; eviction is by entry count, and by bytes only when `--prompt-cache-bytes` is set. At startup it calls `mx.set_wired_limit(mx.device_info()["max_recommended_working_set_size"])`, so those buffers may stay wired rather than paged. Prefix popping does not merge map-reduce windows, because each window's prompt diverges from the next right after the shared system prompt, so every window becomes its own entry.

**Sizes.** KV bytes per token (layers x KV heads x head dim x 2 tensors x 2 bytes): Qwen2.5-3B 36,864 B (computed from the cached `config.json` on 2026-10-25), 7B about 56 KB, 14B about 192 KB. One map-window request is the schema-augmented system prompt (`augment_with_schema(_load_system_prompt(""))` measured at 15,857 chars at HEAD, roughly 4,000 to 5,000 tokens) plus a 1,500-char window plus up to `max_tokens` 4000 of output, so about 5,000 to 9,500 tokens: 0.3 to 0.5 GB per entry on the 7B and 1.0 to 1.8 GB on the 14B. Ten entries is about 3 to 5 GB (7B) or 10 to 18 GB (14B) on top of the weights (4.3 GB and about 8.7 GB). A single-pass 80,000-char Ukrainian meeting is about 39,000 transcript tokens at LOCAL13's measured 0.49 tokens per char, so that one entry alone is about 2.5 GB on the 7B and 8.5 GB on the 14B.

**Who holds it, and for how long.** The per-run spawn is killed by `close()` after each run, so growth is bounded to one run, but one long map-reduce (85 windows for a two-hour meeting; see the sibling task filed from this review for request sizing, findings PYTHON-2 ([LOCAL23](./LOCAL23.md)) and PYTHON-8 ([LOCAL23](./LOCAL23.md))) reaches the 10-entry plateau inside that run. The opt-in warm server (`LocalModelPreloader`, `UISettings.preloadLocalModelAtLaunch`, default off) lives for the daemon's lifetime, and the installed daemon had been up 7 days 8 hours on 2026-10-25, so the plateau would be held between meetings for that long. Under memory pressure the result is swap, or LOCAL16's watchdog aborting later runs with "Not enough memory" over memory no request is using.

**Anticipated, then never picked up.** LOCAL16's out-of-scope list (archived in [q6-final.md](../q6-final.md)) says "a server-side cache lever, if mlx-lm grows one, is a future amendment". 0.31.3 has one. LOCAL13's ship bar M1 ("Peak server RSS <= 12 GB", [owner-verification.md](../owner-verification.md), bench not yet run) samples a server whose retained caches are resident, so landing this first makes M1 measure the model rather than the cache.

**Reachability.** A `local` backend, keyless `auto`, and every NDA or regulated meeting, which `effective_backend` forces on-device. The owner's `config.toml` on 2026-10-25 has `backend = "anthropic"` and `local_model = "mlx-community/Qwen2.5-3B-Instruct-4bit"`.

## Scope

1. In `summarize_local.build_server_command`, pass `--prompt-cache-size` with a named module constant of 2, its comment giving the reason: one entry is what lets each map window reuse the shared system-prompt prefix of the previous call, and the second absorbs an overlapping lane (an `mp ask` against the same warm server, or a schema retry). Both spawn paths inherit it because both call this builder.
2. `test_serve_local.test_build_server_command_appends_model_host_port` pins `cmd[-6:]` to the model, host and port flags, so the new flag goes before `--model` or that test changes in the same commit; either is fine, and the commit body says which.
3. A warm server started by an older build keeps its argv until it restarts. `local_server.parse_identity` reads only `--model` and `--adapter-path`, so LOCAL11's identity check reuses such a server unchanged. That is acceptable (the daemon relaunch from `install.sh` or `rebuild.sh` restarts the warm server), and the commit body says so rather than adding a restart rule.

## Explicitly not

- `--prompt-cache-bytes`. In 0.31.3 it is enforced only on the batch path (`self.prompt_cache.trim_to(n_bytes=total - active)` inside the batch generator); the sequential path's `LRUPromptCache` is built without `max_bytes`, so the size flag is the one bound that holds on every path. Add a byte cap only if a measurement shows the two-entry plateau is still too large, and derive the value then.
- Turning the cache off (size 0). Every map window would re-prefill the 15,857-char prompt.
- The wired limit. `mx.set_wired_limit` is unconditional in 0.31.3 with no flag; it is not patched here.
- How big each request is (a single pass past the tier's ceiling, 1,500-char windows): the sibling task filed from this review (findings PYTHON-2 and PYTHON-8). This task bounds how many finished requests stay resident; that one bounds the size of each.
- The server's log level and the warm log's rotation (review finding PYTHON-13 ([LOCAL21](./LOCAL21.md)), filed separately). If `--log-level WARNING` lands, the `Prompt Cache: N sequences, X GB` INFO line the evidence step below reads disappears, so take the evidence first or read the stats another way.
- Who owns the server ([LOCAL21](./LOCAL21.md)). Its supervisor spawns through `mp serve-local`, which uses this builder, so the flag carries over.
- Constructor drift across `LocalSummaryClient` sites ([PIPE32](./PIPE32.md)); this is an argv change, not a constructor one.

## Acceptance

- `test_summarize_local.py`: `build_server_command` carries `--prompt-cache-size 2` with and without an adapter (extend `test_build_server_command_appends_adapter_path_only_when_set` or add a case beside it).
- `test_serve_local.py`: the argv `mp serve-local` execs carries the flag, and the model, host and port assertions still hold.
- `test_local_server.py`: `parse_identity` still returns the model and the adapter from an argv carrying the new flag.
- `cd pipeline && uv run --extra dev pytest -q` green with the number of new tests in the commit body; `uv run --extra dev ruff check src tests` and `uv run --extra dev --extra mcp pyright` clean; `bash scripts/ci-local.sh pipeline` green.
- Evidence (confirms, does not gate; a session can run it, no owner needed): start a server from this argv on a spare port with a cached preset (the 3B is the one in the HuggingFace cache on 2026-10-25), send four requests with distinct prompts, and read the last `Prompt Cache:` line in its log. It reports at most 2 sequences, against 4 with the flag removed. Both lines go in the commit body.
