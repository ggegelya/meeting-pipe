# PIPE19: the summarization backend is a string switch in four places, and speaker-label cleanup silently never runs for the openai and claude_cli backends

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) A6). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Re-verified against `main` at `45b8c6a` on 2026-10-24.

**The broken promise.** Preferences ▸ Pipeline ▸ Speaker labels offers **Clean up speaker labels after transcription** on every backend; `DiarizeCleanup.base` in `SpeakerAccuracy.swift` is documented "True on every backend", and for a cloud engine `DiarizeCleanup.sublabel(backendID:)` adds "It follows your summarization backend". For `openai` and `claude_cli` it never runs. `diarize_cleanup._select_cleanup_backend` handles `apple_intelligence` (to local), `auto`, `local` and `anthropic`, then ends `raise ValueError(f"unknown summarization.backend: {backend!r}")`. In `orchestrate.run_all` the stage is wrapped as non-fatal:

```
events.emit("pipeline", "stage_started", stage="diarize_cleanup")
try: ... cleanup_transcript(t["json"], cfg=cfg) ...
except Exception as e:  # noqa: BLE001
    log.warning("diarize cleanup failed (non-fatal): %s", e)
```

So every such meeting logs a `stage_started` with no `stage_completed` and no failure event, one warning line in `pipeline.log`, and a summary over the un-cleaned transcript. Nothing on screen says the toggle did nothing. The same holds for a workflow that pins either backend, since the overlay lands in `cfg.summarization.backend` before `effective_backend` reads it.

**The shape that let it happen.** Backend choice is an if/elif over the same backend ids in four places, each with its own subset:

- `summarize._select_backend`: all six (`apple_intelligence` raises, `local`, `anthropic`, `auto`, `claude_cli`, `openai`).
- `engine.complete_text`: all six (`apple_intelligence` substitutes local, then `local`, `anthropic`, `claude_cli`, `openai`, `auto`).
- `diarize_cleanup._select_cleanup_backend`: four, as above.
- `orchestrate._will_summarize_locally`: `local`, `apple_intelligence`, `auto` by key presence.

Then `summarize._identify_backend` recovers which backend answered with an `isinstance` ladder (`_AutoFallbackClient`, `AnthropicSummaryClient`, `ClaudeCLIClient`, `OpenAIClient`, `LocalSummaryClient`, else `"unknown"`). Adding a backend means editing every site, and missing one fails at runtime, sometimes silently.

## Scope

1. **One table.** `pipeline/src/mp/providers.py` keyed by backend id, each row carrying `locality` (`on_device`, `cloud`, `cloud_then_local`), `build_summary(cfg)`, `build_text(cfg)` and `build_cleanup(cfg)` (each may be `None` for "not supported"). `effective_backend` stays the one zero-egress chokepoint and runs before the lookup.
2. **Route the four sites through it.** `_select_backend`, `complete_text`, `_select_cleanup_backend` and `_will_summarize_locally` become lookups. The `auto` ladder stays in `backend_fallback.run_with_local_fallback`; the table row for `auto` wires it.
3. **Clients name themselves.** Every summary and text client gets a `backend_id` attribute (`_AutoFallbackClient` reports the one that answered, as `last_used_backend` does today). Delete `_identify_backend`.
4. **An unsupported pairing fails loudly and early.** For cleanup the owner picks one of two at pickup, recorded in the commit: (a) implement cleanup for `openai` (structured output) and `claude_cli`, or (b) declare them unsupported in the table, emit `stage_skipped` with `reason=unsupported_backend` and the backend id instead of swallowing a `ValueError`, and make the Swift sublabel say "Not available with <engine>" for those engines. Either way, a genuine cleanup exception emits a `stage_failed` event, not only a log line.

## Explicitly not

- The Anthropic client's timeout and retry policy (PIPE24, which can use this table as its home).
- Splitting `summarize.py` (PIPE21) or making the daemon the only owner of `mlx_lm.server` (LOCAL21). This task changes dispatch only; PIPE21 should land after it.
- The typed engine on the Swift side (ARCH14). The Swift sublabel change in item 4(b) is a string, not that refactor.
- Apple Intelligence as a real provider row (ARCH11's follow-on leg). Here it stays "summary produced by the daemon".
- A `deps` argument for `run_all` (T6). The table is what T6's fake provider will plug into, so name it as the seam.

## Acceptance

- `pipeline/tests/test_providers.py`: every id in `config.BackendName` (via the derived `BACKENDS` set) has a row; each row's `locality` matches what `orchestrate` and the long-meeting guard expect; an unknown id raises at lookup with the id in the message.
- `test_diarize_cleanup.py`: with `backend = "openai"` and `backend = "claude_cli"`, cleanup either runs against a fake client (option a) or emits `stage_skipped reason=unsupported_backend` (option b). Both fail on the current code, which raises and is swallowed.
- `test_orchestrate.py`: a cleanup exception emits `stage_failed` with `stage=diarize_cleanup` and the run still summarizes.
- `test_summarize_backend.py`: the run sidecar's backend comes from `client.backend_id` for all five Python-side backends, with `_identify_backend` gone.
- Option (b) only: a Swift test that `DiarizeCleanup.sublabel(backendID:)` says the pass is unavailable for `openai` and `claude_cli`.
- `cd pipeline && uv run --extra dev pytest -q`, `ruff check src tests`, and `pyright` green, new test count in the commit body; `swift test` green if Swift was touched. New event actions are added to `CONVENTIONS.md`'s event table in the same commit and `python3 scripts/truth_fences.py events` stays green.
- `README.md`'s `summarization.diarize_cleanup` entry and `docs/GUIDE.md` say which engines run the pass.
