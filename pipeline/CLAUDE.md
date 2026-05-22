# pipeline/ — Python `mp` CLI

Loaded when you touch files in this subtree. Full subsystem map in [`../ARCHITECTURE.md`](../ARCHITECTURE.md); patterns in [`../CONVENTIONS.md`](../CONVENTIONS.md); terms in [`../GLOSSARY.md`](../GLOSSARY.md). This file is the short list of things that bite if you forget them.

## Build + test

```bash
uv run --extra dev ruff check src tests       # from pipeline/
uv run --extra dev pytest -q                  # from pipeline/
```

CI runs ruff strictly — any F401 unused import fails the pipeline job. Run locally before committing.

## Patterns to match

- **Stdlib first.** Reach for `pathlib`, `dataclasses`, `argparse`, `subprocess`, `json` before adding a dep. The dependency surface here is deliberately small.
- **Lazy heavy imports - inside the function, not at module top.** ASR and diarization run in the Swift daemon (FluidAudio); the pipeline only summarizes and publishes. The heavier imports it still has, `mlx_lm` (the local-summary backend, darwin/arm64-only) and `soundfile` + `numpy` (the channel-aware speaker fallback in `diarize.py`), are slow to load. `mp --help` and `mp logs` shouldn't pay that cost, and Linux CI installs only a light dep set. The contract is: top-level imports are stdlib + pydantic + httpx + anthropic; everything else lives inside the function that uses it.
- **One subcommand per module.** `pipeline/src/mp/<name>.py` exposing `def main(argv: list[str]) -> int`. Register in `__main__.py` with both the dash form and the snake_case alias:
  ```python
  if cmd in {"my-cmd", "my_cmd"}:
      from .my_cmd import main as run
      return run(rest)
  ```
- **Services as `Protocol`s.** `services.py` defines narrow contracts; concrete implementations live next to use sites (`AnthropicSummaryClient` in `summarize.py`, `NotionRestPublisher` in `publish_notion.py`). Tests inject in-memory fakes, not SDK mocks.
- **Pydantic schemas as the contract.** `MeetingSummary` (in `schemas.py`) is the JSON shape every publisher expects. Adding a field means updating the schema + every publisher + the tests.
- **Idempotent publishers.** Each sink runs through `publish_router.fanout`; one failing doesn't block the others. Re-publish must be upsert, not duplicate (Notion derives its page slug deterministically from the meeting stem).

## Tests

- pytest + monkeypatch. No live HTTP, no real network sockets.
- VCR cassettes for Notion / Anthropic replay live next to the test file.
- Don't re-record cassettes for cosmetic changes; only when the upstream API actually changed.

## Event log

`mp.events.emit(category, action, **attrs)` from `events.py` appends to `~/Library/Logs/MeetingPipe/pipeline_events.jsonl`. Categories the pipeline writes: `pipeline` and `publisher`. Schema details in [`../CONVENTIONS.md#event-log-schema`](../CONVENTIONS.md#event-log-schema).

## Sidecar — the Swift↔Python contract

`mp.workflow.apply_overrides` reads `<stem>.meta.json` and overlays workflow-resolved values on top of the global config. The schema is mirrored by Swift's `MeetingMetaSidecar.build`. Adding or renaming a key requires touching both sides + `test_workflow_overlay.py`. See [`../CONVENTIONS.md#sidecar-schema-stem-metajson`](../CONVENTIONS.md#sidecar-schema-stemmetajson).

## Don't

- Don't add a new top-level import for a heavy dep. Move it inside the function body.
- Don't introduce a new package without asking. The current dep list is deliberately small.
- Don't `print(...)` for event-stream data. Use `events.emit(...)` so `mp logs` and `mp analyze-detection` see it.
- Don't bypass `services.Protocol` boundaries — tests can't fake what they can't see.
