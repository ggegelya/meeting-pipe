---
id: SEC31
title: The pipeline's TLS trust store still trusts the emSign root whose intermediates leaked, and the locked transitive stack carries 120 more advisories a constrained refresh clears
category: Security
status: new
priority: P1
comment: Filed 2026-11-12 (upgrade review, owner approved): certifi 2026.4.22 (PYSEC-2026-4320) is the bundle every Anthropic, Notion and OpenAI call trusts, so an on-path holder of a leaked eMudhra intermediate can read transcripts and API keys; broken promise is that cloud traffic is TLS-private. Bump certifi, then refresh the 12 other flagged packages with huggingface-hub held below 2. P1 for the certifi half; owner may re-band.
---

# SEC31: the pipeline's TLS trust store still trusts the emSign root whose intermediates leaked, and the locked transitive stack carries 120 more advisories a constrained refresh clears

Band origin: filed 2026-11-12 from the dependency, platform and AI-model upgrade review (owner approved "File all proposed"). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

On 2026-11-12, `uv export --frozen --all-extras --no-hashes --no-emit-project` of `pipeline/uv.lock` fed to `uvx pip-audit --no-deps` reported 121 advisory rows across 13 packages.

**The one on a live path is certifi 2026.4.22, PYSEC-2026-4320 / GHSA-6q48-6c7w-9gw2**, fixed in 2026.10.19 (latest 2026.10.23). Before 2026.10.18 the bundle includes `emSign ECC Root CA - G3`, and eight eMudhra intermediates chaining to it have compromised private keys. Every pipeline HTTPS client uses httpx's default `verify`, which is that bundle:
- `summarize.AnthropicSummaryClient` builds `anthropic.Anthropic(...)`;
- `diarize_cleanup` builds `anthropic.Anthropic(api_key=api_key)`;
- `publish_notion` opens `httpx.Client(...)`;
- `provider_openai` opens `httpx.Client(timeout=_TIMEOUT)`.

Nothing in `pipeline/src` sets `verify=`, `SSL_CERT_FILE` or `truststore`. An attacker on path who holds one of the leaked keys can therefore impersonate api.anthropic.com or api.notion.com and read transcripts and API keys.

**The other 120 rows are not reachable today.** Each needs a precondition this app does not meet:

| Package (locked) | Rows | Why unreachable |
|---|---|---|
| pillow 12.2.0 | 53 | Loaded because `mlx_embeddings/utils.py` imports `mlx_vlm` at module level, but no image is ever decoded. |
| pyjwt 2.13.0 | 15 | Pulled by `mcp[crypto]`. `mp mcp-serve` is stdio-only and fenced, with no JWT auth. |
| aiohttp 3.14.1 | 11 | Comes in through `datasets[http]` via mlx-vlm. `datasets` is used only by `mlx_lm`'s tuner, and `train_adapter` feeds `mlx_lm.lora` local JSONL. |
| multidict 6.7.1, fsspec 2026.3.0 | 1 each | Same `datasets[http]` path as aiohttp. |
| filelock 3.29.0 | 9 | Needs a second local user who can link into the HF cache lock path. |
| mcp 1.29.0 | 4 | All four are HTTP/SSE transports, client redirects, bearer audience or client `outputSchema`. None is used. |
| urllib3 2.7.0 | 3 | Comes via `requests`, which our code never imports. |
| transformers 5.8.0 | 2 | `save_pretrained` path traversal and `load_custom_generate`. Neither is called; tokenizer loading only. |
| anyio 4.13.0 | 2 | `connect_tcp` TLS and process-pool stderr. Neither is used. |
| idna 3.13 | 1 | Crafted-hostname ReDoS. Hostnames are config constants. |
| datasets 5.0.0 | 1 | Folder-builder path traversal. Not used. |

**A naive refresh is unsafe.** In a scratch resolve, `uv lock --upgrade-package` on those 13 packages also moved `huggingface-hub` 1.12.0 to 2.4.0, which brings `httpx2`, `httpcore2` and `truststore`. That stack bypasses `egress_guard`'s httpx patch, and the CI8 fence in `tests/test_egress_guard.py` (`test_the_anthropic_sdk_still_sends_through_the_patched_httpx`) checks only the Anthropic client, so nothing fails. SEC19 owns the structural fix.

**The constrained refresh works.** Adding `[tool.uv] constraint-dependencies = ["huggingface-hub<2"]` to the same scratch resolve gives:
- pillow 13.0.0, transformers 5.22.2, tokenizers 0.23.3, huggingface-hub 1.33.0, datasets 5.2.0, filelock 4.2.10, urllib3 2.8.0, pyjwt 2.15.1, mcp 1.30.0, anyio 4.16.0, idna 3.20, fsspec 2026.9.0, certifi 2026.10.23;
- aiohttp, multidict, yarl, aiosignal, frozenlist and propcache drop out of the lock;
- pip-audit then reports "No known vulnerabilities found";
- on that lock, `ruff check src tests` passes, `pyright` reports 0 errors, and `pytest` passes everything except the doc-link fence. That fence failed only because the scratch copy lacked LICENSE and `.github/`.

## Scope

1. `uv lock --upgrade-package certifi` on its own, as the first commit.
2. Add `constraint-dependencies = ["huggingface-hub<2"]` under `[tool.uv]` in `pipeline/pyproject.toml`, with a comment naming SEC19 as what lifts it. Then upgrade the twelve other packages above, in a second commit.
3. Smoke the paths whose libraries moved:
   - one `mp summarize` on the local backend (transformers and tokenizers sit under `mlx_lm`'s tokenizer);
   - one embed-index rebuild (`embed_index.MLXEmbedder`).

## Explicitly not

- Not `truststore` / system-keychain trust. That is a new dependency and needs the owner's yes, so raise it separately if wanted.
- Not the anthropic `<1` / httpx `<1` cap lift (SEC19, with the API-version traps recorded there).
- Not replacing mlx-embeddings to shed the mlx-vlm stack. Its `utils.py` imports `mlx_vlm` at import time, so the heavy dependencies cannot be overridden away. Swapping the embedder model is AI14, a different question.

## Acceptance

- `uv export --frozen --all-extras --no-hashes --no-emit-project` piped to `uvx pip-audit --no-deps` reports no known vulnerabilities, or names only advisories published after the refresh.
- `uv.lock` resolves certifi >= 2026.10.19 and huggingface-hub < 2, and contains no `httpx2` entry.
- `bash scripts/ci-local.sh pipeline` is green.
- The local-backend summarize smoke and the embed-index rebuild both succeed on the owner's Mac, noted in this file's progress line.
