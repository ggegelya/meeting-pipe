# pipeline/ — Python `mp` CLI

Loaded when you touch files in this subtree. Full subsystem map in [`../ARCHITECTURE.md`](../ARCHITECTURE.md); patterns in [`../CONVENTIONS.md`](../CONVENTIONS.md); terms in [`../ARCHITECTURE.md#glossary`](../ARCHITECTURE.md#glossary). This file is the short list of things that bite if you forget them.

## Build + test

```bash
uv run --extra dev ruff check src tests       # from pipeline/
uv run --extra dev pyright                    # from pipeline/ (basic mode, src/ only)
uv run --extra dev pytest -q                  # from pipeline/
../scripts/coverage.sh python                 # T3: pytest-cov report, not a gate
```

CI runs ruff strictly — any F401 unused import fails the pipeline job. Run locally before committing.

CI also runs pyright (TYPE1), configured in `pyproject.toml`'s `[tool.pyright]`. It covers `src/` only; `tests/` is full of deliberately-partial fakes and would need its own pass. Two things to know when it complains:

- **Don't reach for a blanket suppression.** The errors it finds are usually real (`getattr(b, "type", ...)` defeats union narrowing where `b.type` does not; `isinstance(seg.get("end"), float)` narrows nothing about the value the comprehension then collects).
- **The three imports CI cannot resolve** (`mlx_embeddings`, `mlx.core`, `huggingface_hub` — darwin/arm64-only, never installed on the Linux runner) carry a `# pyright: ignore[reportMissingImports]` at their lazy import site. That is deliberately per-site, not a global `reportMissingImports = "none"`, so a genuine typo in any other import still fails the build. A new heavy lazy import needs the same comment.

## Patterns to match

- **Stdlib first.** Reach for `pathlib`, `dataclasses`, `argparse`, `subprocess`, `json` before adding a dep. The dependency surface here is deliberately small.
- **Lazy heavy imports - inside the function, not at module top.** ASR and diarization run in the Swift daemon (FluidAudio); the pipeline only summarizes and publishes. The heavier imports it still has, `mlx_lm` (the local-summary backend, darwin/arm64-only) and `soundfile` + `numpy` (the channel-aware speaker fallback in `diarize.py`), are slow to load. `mp --help` and `mp logs` shouldn't pay that cost, and Linux CI installs only a light dep set. The contract is: top-level imports are stdlib + pydantic + httpx + anthropic; everything else lives inside the function that uses it.
- **One subcommand per module.** `pipeline/src/mp/<name>.py` exposing `def main(argv: list[str]) -> int`. Register in `__main__.py` with both the dash form and the snake_case alias:
  ```python
  if cmd in {"my-cmd", "my_cmd"}:
      from .my_cmd import main as run
      return run(rest)
  ```
  A new subcommand also adds a row to the subcommand table in [`../ARCHITECTURE.md`](../ARCHITECTURE.md), in the same commit. The table went 17 modules stale before DOC7 rebuilt it; every session that reads it to orient is the cost.
- **Every entry point calls `entry.prepare(...)` first.** Workflow overlay, then arm the egress guard on the resolved config, then load secrets. Never hand-roll the triple: arming before the overlay misses a per-meeting NDA workflow, loading secrets before arming hands the cloud tokens to the `mlx_lm.server` child. Clamps key off `config.zero_egress(cfg)`, never a fresh `regulated or nda` boolean. See [`../CONVENTIONS.md`](../CONVENTIONS.md) "The entry contract".
- **Services as `Protocol`s.** `services.py` defines narrow contracts; concrete implementations live next to use sites (`AnthropicSummaryClient` in `summarize.py`, `NotionRestPublisher` in `publish_notion.py`). Tests inject in-memory fakes, not SDK mocks.
- **An underscore name belongs to its module.** If a sibling module needs it, that is the signal to promote it to a public name in a home that makes sense, not to import the private one. A module-private copy of a sibling's helper is worse still: `publish_fs` carried its own `_render_summary_md` "so it does not depend on a private helper", and the copy silently drifted from the original until PIPE7 deleted it. The shared ones today: `markdown.render_summary_md`, `config.parse_local_endpoint`, `workflow.read_meta`, `backend_fallback.run_with_local_fallback` (the one cloud-then-local `auto` ladder, shared by `summarize` and `engine`), `json_extract.largest_balanced_json_object` (the balanced-JSON scan, shared by `summarize_local` and the PROV1 `provider_*` backends; PROV1 promoted it out of `summarize_local` for exactly this reason), and `summarize_local.augment_with_schema` / `.compose_user_message` (the system and user turns the local server sends, promoted out of `LocalSummaryClient` by LOCAL9 so `train_adapter` trains on the exact shape inference uses; a LoRA tuned on a prompt the server never sends is tuned for nothing), plus `orchestrate.existing_daemon_transcript` / `.finalize_streamed_transcript` / `.apply_glossary` (run-all's finalize stage, promoted by ASR3 so `mp finalize` re-runs the same transform for the re-transcribe ratchet instead of a copy that would drift from it). `render_summary_md` and `largest_balanced_json_object` each have a Swift mirror (`AppleIntelligenceSummarizer.renderMarkdown` / `.largestJSONObject`) pinned by CI3 golden fixtures (`Fixtures/summary-md-golden.json`, `Fixtures/json-extract-golden.json`), so a cross-language drift breaks one suite (the CI2 meta-contract precedent).
- **Pydantic schemas as the contract.** `MeetingSummary` (in `schemas.py`) is the JSON shape every publisher expects. Adding a field means updating the schema + every publisher + the tests.
- **Idempotent publishers.** Each sink runs through `publish_router.fanout`; one failing doesn't block the others. Re-publish must be upsert, not duplicate (Notion derives its page slug deterministically from the meeting stem).
- **A publish that landed nowhere exits 3.** `run-all` / `publish` / `publish-from-paste` / `merge-meetings` / `digest --publish` return `publish_router.EXIT_PUBLISH_FAILED` when every configured sink failed, and `fanout` records the run's outcome in `<stem>.publish.json`. Zero sinks configured is a success (`all_sinks_failed`, not `publish_state == "none"`). A new command that fans out inherits both or it lies to the daemon. The sidecar's shape and `publish_state`'s three-value vocabulary are pinned by `Fixtures/publish-result-golden.json` (CI4); six Swift sites branch on those literals, so a fourth value is not a widening, it is six silent else-branches.
- **Changing a cross-tree writer means regenerating its fixture.** `<stem>.publish.json`, the `mp prefetch-model` progress JSONL, and the speaker overlay are generated into the Swift test bundle by `scripts/gen_contract_fixtures.py`. Run `cd pipeline && uv run python ../scripts/gen_contract_fixtures.py`, and diff. `test_ci4_contracts.py` fails if you forget; the Swift suite fails if the new shape is one Swift does not understand. Full table in [`../CONVENTIONS.md#cross-tree-golden-fixtures`](../CONVENTIONS.md#cross-tree-golden-fixtures).
- **Rewriting the only copy of a transcript/summary is atomic.** `storage.atomic_write_text(path, text)` (tmp-in-dir → chmod 0600 → `os.replace`) is the one helper; a crash mid-write leaves the prior file intact, never a truncated one a reader or retry then parses. Used by `orchestrate` finalize + glossary, `summarize`, and `merge_meetings` (PIPE8). Don't hand-roll `write_text` + `chmod` for content files.

## Tests

- pytest + monkeypatch. No live HTTP, no real network sockets.
- **Outbound HTTP is faked with `httpx.MockTransport`, not recorded.** Monkeypatch `httpx.Client` to inject `transport=httpx.MockTransport(handler)` and answer from a handler function (`test_publish_notion.py` is the template; `test_summarize_backend.py` and `test_publish_from_paste.py` use the same shape). There are no cassettes and no `tests/cassettes/` directory: responses are written inline, so a test says what it expects instead of hiding it in a recorded fixture, and nothing ever needs re-recording. `pytest-vcr` / `vcrpy` were declared as dev deps for years without a single import; DOC9 dropped them.

## Event log

`mp.events.emit(category, action, **attrs)` from `events.py` appends to `~/Library/Logs/MeetingPipe/pipeline_events.jsonl`. Categories the pipeline writes: `pipeline`, `prefetch`, and `publisher` (fenced against the emitters by `scripts/truth_fences.py events`, so a new one needs a row in the CONVENTIONS table in the same commit). Schema details in [`../CONVENTIONS.md#event-log-schema`](../CONVENTIONS.md#event-log-schema).

Under pytest it appends somewhere else, and that is load-bearing. `mp.events.logs_dir` honours `MEETINGPIPE_LOGS_DIR` and otherwise redirects to a temp dir when it sees a test runner, so the suite cannot write fixture rows into the log every analysis reads back. Without it pytest owned 21% of that file. Don't remove the guard, and don't reintroduce a hard-coded path in a new writer. Reading the log has its own trap (historical residue that no filter can fully remove); `is_test_residue` and the "Event log schema" section of `../CONVENTIONS.md` cover it.

## Sidecar — the Swift↔Python contract

`mp.workflow.apply_overrides` reads `<stem>.meta.json` and overlays workflow-resolved values on top of the global config. The schema is mirrored by Swift's `MeetingMetaSidecar.build`. Adding or renaming a key requires touching both sides + `test_workflow_overlay.py`. See [`../CONVENTIONS.md#sidecar-schema-stem-metajson`](../CONVENTIONS.md#sidecar-schema-stemmetajson).

A second Swift-to-Python surface: `mp.speaker_overlay` reads `<stem>.speaker_labels.json` (the daemon's reversible speaker-label overlay, FEAT3-UNDO / FEAT3-SEGMENT) and applies it when re-summarizing, so a regenerate reflects in-app namings + reassignments. Its resolution (per-segment override, else raw speaker, then mapped through the cluster-name table) must stay byte-identical to Swift's `SpeakerLabelStore`; change one side and change the other. Pinned by `Fixtures/speaker-overlay-golden.json` (CI4). The subtle half is the *filtering*: both readers are fail-open, and they have to be fail-open the same way, so `read_overlay` drops an empty key, an empty or non-string value, and a non-integer segment key exactly as Swift does, and canonicalizes segment keys because Swift keys them by `Int`.

A third: `mp.transcript_corrections` reads `<stem>.transcript_corrections.json` (the reversible text-correction overlay, written by Swift's `TranscriptCorrectionStore` when the user edits a transcript line, PIPE9) and applies edited text by segment array index. `transcript_corrections.overlaid_markdown` is the composed transcript view (speaker labels THEN text corrections), used by `summarize` and `embed_index.chunk_library`, so any re-read applies both overlays; `library_fingerprint` folds both sidecars in so a correction rebuilds the `mp ask` index. Both resolutions are pinned against Swift by `Fixtures/transcript-corrections-golden.json` (both suites read it); change one side and change the other.

## Don't

- Don't add a new top-level import for a heavy dep. Move it inside the function body.
- Don't introduce a new package without asking. The current dep list is deliberately small.
- Don't spawn a subprocess with an inherited env. Pass `env=egress_guard.child_env()` so a zero-egress run cannot egress from inside the child (the httpx patch only covers this process).
- Don't `print(...)` for event-stream data. Use `events.emit(...)` so `mp logs` and `mp analyze-detection` see it. A new category goes in the `CONVENTIONS.md` table in the same commit, fenced by `scripts/truth_fences.py` (CI5); `prefetch` sat undocumented for months before that fence existed.
- Don't add a field to a `config.py` model without documenting it in `config.example.toml`. CI5 diffs the pydantic models against that file and the README, in both directions, and `[extra] = "ignore"` on several models means an undocumented key is swallowed silently rather than rejected.
- Don't bypass `services.Protocol` boundaries — tests can't fake what they can't see.
