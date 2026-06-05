# Spike: Swift port of the pipeline (TECH-DIST2)

Status: evaluation only (no decision). Re-evaluate on the trigger in the last section.

## Context

Distribution has one real problem: a clean Mac has no usable Python 3 (Apple removed the system Python; the Command Line Tools shim is 3.9, below the 3.11+ the pipeline needs), so installing today requires Homebrew + uv + ffmpeg. There are two ways out:

- **TECH-DIST1, bundle the runtime:** embed a relocatable Python (python-build-standalone) + static ffmpeg + the pipeline wheels in the app, notarize, and the daemon shells out to the embedded `mp`. Ships near-term; the app gets bigger and gains a notarization step.
- **TECH-DIST2 (this spike), port the pipeline to Swift:** drop Python entirely so the app is a single Swift binary. The clean endgame, but gated on one hard blocker (below). This would moot DIST1 and overlaps TECH-I7 ("drop Python entirely").

The pipeline is already small: ADR 0007 moved ASR + diarization into the Swift daemon (FluidAudio), so the Python side is **summarize + publish only**. That makes a port plausible to scope, which is why this spike exists.

## What the Python pipeline still does

`mp` is a thin CLI (one module per subcommand). The surface a Swift port would have to replace:

| Area | Python today | Port difficulty |
|---|---|---|
| Summarize, Anthropic backend | `anthropic` SDK over httpx, tool-use forced schema | **Low.** A Swift HTTP client + Codable structs. The Messages API is plain HTTPS. |
| Summarize, Apple Intelligence backend | already produced in the Swift daemon (Foundation Models); Python only finalizes + hands off | **None.** Already Swift. |
| Summarize, local MLX backend | `mlx_lm.server` running Qwen 2.5 on Metal, JSON-schema-constrained decode | **High. This is the blocker (below).** |
| Publish: Notion | Notion REST API over httpx, idempotent by stored page id | **Low.** HTTPS + Codable. |
| Publish: Obsidian / filesystem / LAN | local file writes, atomic + reachability checks | **Low.** Foundation `FileManager`. |
| Chunking primitive | `chunked_windows` | **Done.** Already mirrored as `TranscriptChunker` in Swift, pinned identical by the TECH-ARCH4 golden fixture. |
| Config / secrets | TOML + `secrets.env` | **Low.** The daemon already round-trips the same TOML via TOMLKit. |
| Egress guard (regulated/NDA) | one httpx transport that hard-fails non-loopback | **Medium.** Re-implement as a URLSession/`URLProtocol` guard; the contract is small and well-tested. |
| Schemas / typed summary | pydantic `MeetingSummary` | **Low.** Codable structs (the daemon already has a `MeetingSummary` reader). |
| Event log | `events.jsonl` append | **None.** The daemon already owns `Log.event`. |
| Correction loop | run/correction sidecars | **Low.** JSON file IO. |

So roughly everything except the **local MLX summarizer** is a low-risk Swift rewrite over HTTP + file IO + already-present primitives.

## The blocker: the local summarization backend

The privacy story (`summarization.backend = "local"`, and the zero-egress contract under `regulated_mode`) depends on running an LLM fully on-device. Today that is `mlx_lm` (Python): it loads a quantized Qwen 2.5 from the Hugging Face cache, serves an OpenAI-style endpoint on localhost, and supports schema-constrained decoding. `mlx_lm` is mature and actively maintained.

The Swift-native equivalent is **MLX-Swift**. MLX-Swift (the array framework) is solid, but the **LM tooling on top of it** (tokenizer parity across model families, robust model loading from HF repos, a generation loop with sampling, and JSON-schema / grammar-constrained decoding) is materially **less mature than `mlx_lm`**. Porting the local backend means owning that LM stack in Swift, including:

- model loading + quantization formats for the Qwen family (and the curated Small/Recommended/Large presets the UI exposes),
- a correct tokenizer for each preset,
- constrained decoding to keep the `MeetingSummary` JSON contract (today enforced via `response_format` + the 3-layer extractor),
- and ongoing maintenance as new local models ship.

That is the bulk of the effort and essentially all of the risk. It is not a port; it is adopting (and maintaining) a second LM runtime.

## Options

1. **Full Swift port now.** Rewrite summarize + publish in Swift, including the local LLM on MLX-Swift. Single binary, no Python, cleanest distribution. Cost: own an immature LM stack; high risk to the privacy backend that is the product's main differentiator.
2. **Port everything except the local backend.** Rewrite the Anthropic/Notion/file paths in Swift, keep a thin Python (or a separate process) only for local MLX. This does **not** drop Python, so it does not achieve DIST2's goal and adds a second codebase for one feature. Not worth it.
3. **Stay Python, bundle the runtime (DIST1).** Ship now with an embedded Python; revisit the port when the blocker clears.

## Recommendation

**Defer the full Swift port. Pursue DIST1 (bundle the runtime) for near-term distribution.** The local-MLX backend cannot move to Swift today without taking on the immature MLX-Swift LM tooling, and that backend is the privacy differentiator, exactly the thing not to put at risk. Everything else ports cheaply, but "everything except the hard 20%" does not drop Python, so it does not pay off.

DIST1 is the lower-risk, ships-now path and is independently useful (locked-down regulated Macs often cannot install Homebrew either). The Swift port stays the clean endgame, not the next step.

## Re-evaluation trigger

Reopen DIST2 when **either** holds:

- **MLX-Swift LM tooling reaches production maturity** for the Qwen family, robust HF model loading, correct per-preset tokenizers, and constrained/grammar decoding that can hold the `MeetingSummary` JSON contract; or
- **Apple Intelligence (Foundation Models) proves out as the sole on-device summarizer** for the user's English/Ukrainian meetings, removing the need for an MLX local backend at all (the TECH-I7 promotion trigger). At that point summarize is already Swift, publish is a small HTTP/file rewrite, and the port becomes mostly mechanical.

Until then: ADR 0007 stands (Python summarizes + publishes), DIST1 is the distribution path, and this spike is the standing rationale for not porting yet.
