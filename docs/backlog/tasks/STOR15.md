---
id: STOR15
title: 'Evict unused' deletes every model in the shared Hugging Face cache except the summary model, including other tools' models and the app's own search embedder
category: Storage
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). StorageStatsStore.evictUnusedModels removes every models--* repo in ~/.cache/huggingface/hub except summarization.local_model, so it deletes other tools' cached models and mp's own embedder (mlx-community/multilingual-e5-small-mlx); on the owner's Mac on 2026-11-14 the 241 MB it offers is exactly that embedder, and under regulated mode the next Ask or MCP serve then fails closed until a manual mp prefetch-model (F073, F064, F134). Offer only repos the app uses (LocalModelPreset.all, the configured local model, the embedder), keep the embedder, name each repo in the confirm; promote before enabling regulated.
---

# STOR15: 'Evict unused' deletes every model in the shared Hugging Face cache except the summary model, including other tools' models and the app's own search embedder

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: finding F073 (data lens, partially confirmed), with F064 and F134 (data lens, confirmed) as the same defect seen from the data and security lenses, all in the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md). Re-verified in code and on the owner's disk at HEAD `3a2da4fc` on 2026-11-14.

**What it deletes.** `StorageScanner.models(in:activeModelID:)` lists every `models--*` entry in `StorageScanner.hubRoot(home:)` (`~/.cache/huggingface/hub`, the cache every Hugging Face tool on the Mac shares) and marks one in use: `inUse: dir.lastPathComponent == activeDirName`, where `activeModelID` is `configStore.summarizationLocalModel`. `StorageStats.ModelEntry`'s doc says "Everything else is evictable". `StorageStatsStore.evictUnusedModels` filters `!$0.inUse` and runs `try? FileManager.default.removeItem(at: dir)` on each. The confirm (`"Delete unused models?"`, button `Delete <bytes>`) says "Every downloaded model except the one Pipeline is configured to use. They re-download on demand." and names no repo.

**Two things it should not touch.** Other tools' models in the shared cache, which the app did not download and does not own. And mp's own embedder, `embed_index.DEFAULT_EMBED_MODEL = "mlx-community/multilingual-e5-small-mlx"`, used by `mp ask`, `mp mcp-serve` and `mp actions --cluster`. The daemon has no knowledge of the embedder's ID at all; it appears only in `pipeline/src/mp/embed_index.py`.

**Field evidence, 2026-11-14.** The owner's hub holds two repos: `models--mlx-community--Qwen2.5-3B-Instruct-4bit` (1.6 GB, the configured `local_model`, so in use) and `models--mlx-community--multilingual-e5-small-mlx` (241 MB). Evict unused is enabled and offers exactly the embedder. `regulated_mode = false` and `backend = "anthropic"`, so today the cost is a 241 MB re-download on the next Ask.

**The functional break is regulated-only.** `MLXEmbedder._ensure_loaded` raises `EmbedderUnavailableError` ("Embedding model ... is not in the local HuggingFace cache, and this is a regulated/NDA run, so it cannot be downloaded now") when `egress_guard.is_armed()` and `not model_is_cached(self.model_id)`. `ask.py` and `mcp_serve.py` are library-wide and `ask.py`'s docstring says a per-meeting NDA flag structurally cannot arm them, so only global `regulated_mode` reaches this: Ask and MCP serve then fail closed until a manual `mp prefetch-model`. The deletion of foreign models happens in every mode.

Correction at filing: the audit says `actions --cluster` fails closed too. `action_clusters` wraps `default_embedder()` and the embed in `except Exception` and returns every action ungrouped ("fail-open, see the module docstring"), so clustering degrades silently rather than failing. FluidAudio's transcription models are not in the hub cache (they live under `~/Library/Application Support/FluidAudio`), so eviction does not reach them.

Correction at filing (on F064 and F134's direction): an ownership manifest written by `mp prefetch-model` alone would miss the embedder, which is fetched implicitly by `mlx_embeddings.utils.load` inside `_ensure_loaded` outside a regulated run, never through prefetch, and would miss every repo cached before the manifest existed. The keep and offer sets have to be named from code, not only recorded at download time.

## Scope

1. **Offer only repos the app uses.** In `StorageScanner.models(in:activeModelID:)` (or a new pure helper beside it), classify each hub entry as one of: in use (the configured `summarization.local_model`, or the embedder), evictable (any other `LocalModelPreset.all` model id, from `PreferencesWindow.swift`), or not the app's (everything else). `evictableModelBytes` and `evictUnusedModels` count and delete only the evictable class. Entries that are not the app's are still shown in the size total, labelled as belonging to other tools, and never deleted.
2. **Share the embedder id across trees.** A Swift constant for `mlx-community/multilingual-e5-small-mlx`, pinned against `embed_index.DEFAULT_EMBED_MODEL` by a cross-tree fence or golden fixture in the style `CONVENTIONS.md#cross-tree-golden-fixtures` lists, so a model swap (see [AI14](./AI14.md)) cannot leave the daemon evicting the new embedder.
3. **Name the repos in the confirm.** The dialog's message lists each repo it will delete with its size, and says the other tools' models are left alone.

## Explicitly not

- An ownership manifest written at download time (see the correction above). It can be added later as a refinement; the code-named sets are the floor.
- Making eviction delete to the Trash: these are caches, and a re-download restores them.
- The `models_evicted` event's `bytes_freed` counting failed removals: [STOR7](./STOR7.md)'s 2026-10-25 amendment owns it.
- Download and cancel behaviour of `ModelDownloadSupervisor`: [LOCAL20](./LOCAL20.md). The local model bench: [LOCAL13](./LOCAL13.md).
- A proactive warning when regulated mode is turned on with the embedder uncached. Worth noting for whoever enables regulated mode; not filed.

## Acceptance

- `StorageStatsTests` over a temp hub dir holding the configured model, a second `LocalModelPreset` model, the embedder and a foreign `models--someone--other-model`: only the second preset is evictable, `evictableModelBytes` equals its size, and after `evictUnusedModels` the configured model, the embedder and the foreign repo still exist.
- A fence test that the Swift embedder constant equals `DEFAULT_EMBED_MODEL` in `pipeline/src/mp/embed_index.py`, failing when either side changes alone.
- A test (view-model level, not a token-presence fence) that the confirm's message names each evictable repo.
- `cd daemon && swift build` and `swift test` green, the number of new tests in the commit body; `bash scripts/ci-local.sh` green.
- README's description of Evict unused (and `docs/GUIDE.md`, if it gains one) says it removes only the app's unused summary models and leaves the search embedder and other tools' models, in the same commit.
