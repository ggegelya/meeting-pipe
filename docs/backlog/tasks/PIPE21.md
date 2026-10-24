# PIPE21: summarize.py and summarize_local.py are god modules, and five private helpers are imported across module boundaries

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) B3). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Re-verified against `main` at `45b8c6a` on 2026-10-24.

`pipeline/src/mp/summarize.py` is 1,001 lines with 51 commits in its history, the most-churned pipeline module. It mixes the Anthropic transport and retry (`_should_retry_anthropic`, `_create_message` with its tenacity and PIPE10 sleep logic, `AnthropicSummaryClient`), prompt assembly (`_load_system_prompt`, `_extra_sections_directive`, `_summary_language_directive`, `summary_request`), a library scan for prior meetings (`_prior_meeting_context`), backend selection (`_select_backend`, `_AutoFallbackClient`), identity attribution (`_identify_backend`, `_identify_adapter`, `_served_local_identity`), evidence verification (`_verify_evidence`), language repair (`_verify_and_repair_language`), the CLI (`main`) and the sidecar rewrite (`rewrite_run_sidecar`). `summarize()` itself runs from its `def` to its `finally` across roughly a hundred lines that call most of the above.

`summarize_local.py` is 1,128 lines: prompt shaping (`augment_with_schema`, `compose_user_message`, `repair_messages`, `_reduce_instructions`), the map-reduce (`_batched`, `_render_for_reduce`), and `LocalSummaryClient`, which owns both the request path and the whole `mlx_lm.server` lifecycle (`_ensure_running`, `_reuse_is_safe`, `_owns`, `_spawn`, `_wait_for_health`, `_terminate_proc`, the idle timer).

Private names crossing module boundaries (each a `from .x import _y`):

- `diarize_cleanup` imports `summarize._create_message` and `summarize_local._largest_balanced_json_object`, which is only an alias (`_largest_balanced_json_object = largest_balanced_json_object`) of the public `json_extract` function.
- `dogfood` and `train_adapter` import `summarize._load_system_prompt`.
- `doctor` imports `prefetch_model._bytes_on_disk`.
- `roster` imports `voiceprint._l2_normalize`.

The tests are coupled to the current layout: at filing, 14 single-line `monkeypatch.setattr` calls in `pipeline/tests` name an `mp.summarize.` or `mp.summarize_local.` attribute by dotted string, and more patch the module objects or span several lines (for example `"mp.summarize._select_backend"`, `"mp.summarize_local.LocalSummaryClient"`, `"mp.summarize._create_message.retry.wait"`), so a move that is not careful breaks them, or worse, leaves them patching a name nothing reads any more and passing vacuously.

## Scope

Green-to-green, one move per commit, behaviour unchanged at every step:

1. `summarize.py` splits into `prompting.py` (system prompt, directives, request text, prior-meeting context), `provider_anthropic.py` (the Anthropic client, `_create_message` and its retry predicate), and a `summarize.py` of about 200 lines holding `summarize()`, evidence and language verification, the CLI and the sidecar rewrite.
2. `summarize_local.py` splits the server lifecycle out of `LocalSummaryClient` into its own module (for example `local_server_client.py` beside `local_server.py`), leaving the request path and the local prompt shaping. If LOCAL21 has landed, most of this lifecycle is gone and the split is smaller; do LOCAL21 first if both are open.
3. The five cross-module private helpers become public in their natural home (`json_extract.largest_balanced_json_object` already is; delete the alias), or move into `json_extract` and `storage` where they are generic.
4. Every `monkeypatch.setattr` target that names a moved symbol is updated to where the symbol is now read from, in the same commit as the move.

Order: after PIPE19 (provider table) and PIPE24 (one Anthropic client factory), since both rewrite the code this moves. Moving first and editing second doubles the diff each reviewer reads.

## Explicitly not

- Any behaviour change, prompt change or new abstraction. A split that also "improves" something is two tasks.
- Injecting dependencies into `run_all` and `summarize` (T6). This task makes T6 easier; it does not do it.
- `orchestrate.py` (805 lines). It is a sequence of stages, which is a legitimate shape for its size.
- The staged summarizer (PIPE20 decides whether it exists).

## Acceptance

- `cd pipeline && uv run --extra dev pytest -q` green after each commit, with the same pass count before and after each move (no tests added or removed by a move commit; any new test lands separately).
- A guard test that each `monkeypatch.setattr` dotted target in `tests/` resolves to an attribute that exists, so a stale target fails instead of patching nothing (one new test).
- No `from .<module> import _<name>` across modules remains in `src/mp`, checked by a ruff rule or a short test.
- `summarize.py` under 300 lines; no module in `src/mp` that this task touches over 700.
- `ruff check src tests` and `pyright` green; `bash scripts/ci-local.sh pipeline` green; `ARCHITECTURE.md`'s pipeline file table lists the new modules in the same commit.
