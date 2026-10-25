# PIPE32: LocalSummaryClient is assembled at seven sites from different subsets of its eleven parameters, which already caused LOCAL19 and PIPE12

Band origin: filed 2026-10-25 from the 2026-10-25 code-quality audit band ([code-quality audit](../../audits/2026-10-25-code-quality-audit.md) PIPE32, finder PY2). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

`summarize_local.LocalSummaryClient.__init__` takes eleven keyword-only parameters, every one defaulted: `model`, `host`, `port`, `startup_timeout_sec`, `request_timeout_sec`, `idle_timeout_sec`, `summary_language`, `manage_subprocess`, `map_reduce_above_chars`, `adapter_path`, `memory_floor_pct`. Nine of them come from eight `cfg.summarization` fields (`local_model`, `local_endpoint` split by `parse_local_endpoint`, `local_startup_timeout_sec`, `local_request_timeout_sec`, `summary_language`, `skip_above_chars`, `local_adapter_path`, `local_memory_floor_pct`); `idle_timeout_sec` and `manage_subprocess` have no config key. Because every parameter has a default, a construction that forgets one does not fail, it silently runs on the constructor's constant.

After PIPE19 (shipped 2026-10-24) put the backend table in `providers.py`, the constructions on 2026-10-25 are:

| Site | Parameters passed |
|---|---|
| `providers._local_summary` | all nine |
| `summarize.AutoFallbackClient.summarize`, its `_local` closure | all nine, a hand copy of the row above |
| `engine._local_client` | seven; `summary_language` and `map_reduce_above_chars` skipped on purpose, with the reasons in comments (PIPE12) |
| `providers._local_cleanup` | four: `model`, `host`, `port`, `memory_floor_pct` |
| `dogfood.run_one` | two: `model`, `memory_floor_pct` (no host or port, so it ignores `local_endpoint`) |
| `dogfood.run_one_adapter`, base and adapter rungs | four and five |

Two shipped defects were exactly this omission. PIPE12 (2026-08-03): `engine._local_client` did not pass `adapter_path`, so a trained LoRA adapter served every summary and no ask, digest or classification. LOCAL19 (2026-08-15): the auto ladder's local rung did not pass `memory_floor_pct`, so the free-RAM watchdog on `auto` ignored the configured floor. LOCAL19's fix added `test_local_client_contract.py`, an AST walk asserting every `LocalSummaryClient(...)` call passes `memory_floor_pct=<cfg>.summarization.local_memory_floor_pct`, plus a `pipeline/CLAUDE.md` Don't bullet. The fence covers one keyword of nine.

The next instance is already in the table: `providers._local_cleanup` never passes `local_startup_timeout_sec` or `local_request_timeout_sec`, so speaker-label cleanup on the local backend runs on the 120 s constructor defaults whatever the owner sets in `config.example.toml`'s "Local-backend timeouts (LOCAL2)" block. The defaults happen to equal the shipped config values, which is why nothing has noticed.

Re-checked at filing: the audit counted six sites; it is seven constructions in four modules (`dogfood` has three), and `providers._local_cleanup` is a live omission the audit did not name.

## Scope

1. **`LocalSummaryClient.from_config(cfg: Config, **overrides) -> LocalSummaryClient`**, a classmethod in `summarize_local.py`. It threads all nine config-backed parameters (endpoint through `parse_local_endpoint`, `local_adapter_path or None`), then applies `overrides` by keyword; an override naming a parameter the constructor does not have raises `TypeError` as the constructor would.
2. **Every construction calls it.** `providers._local_summary` becomes `LocalSummaryClient.from_config(cfg)`. `AutoFallbackClient`'s `_local` rung calls the same factory (or `providers._local_summary`), deleting its copy. `engine._local_client` passes its two deliberate skips as explicit overrides (`summary_language="auto"`, `map_reduce_above_chars=...` at the constructor default) with the existing reasons kept beside them, plus its `model` override. `providers._local_cleanup` calls it bare, which is the fix for the timeout omission. `dogfood`'s three pass only what differs (`model`, and for the adapter rung `port=port + 1` and `adapter_path`).
3. **Shrink the fence.** `test_local_client_contract.py` asserts, by the same AST walk and with its guard-the-guard test kept, that no `LocalSummaryClient(...)` call exists under `src/mp` outside `summarize_local.py`, and that no `from_config` call overrides `memory_floor_pct`. Update the `pipeline/CLAUDE.md` Don't bullet to name the factory instead of the keyword.

## Explicitly not / out of scope

- The Anthropic clients' three construction policies (timeouts, SDK retries): PIPE24 is the cloud half of the same smell and stays separate.
- Splitting `summarize_local.py` or `summarize.py`: PIPE21. If PIPE21 lands first and moves `LocalSummaryClient`, the factory goes with the class.
- Adding a config key for `idle_timeout_sec` or `manage_subprocess`. Neither is configurable today and this task adds no knob.
- `summarize_staged.py` and the `dogfood` subcommands' future as shipped product surface: PIPE20.
- Changing any default value.

## Acceptance

- `test_local_client_contract.py`: the walk still finds the known modules (guard), fails on a planted direct construction outside `summarize_local.py` and on a planted `memory_floor_pct` override (both tried and reverted, said in the commit body).
- A table test in `test_summarize_backend.py` or a new `test_local_client_factory.py`: with every config-backed field set to a non-default value, `from_config(cfg)` produces a client whose nine attributes carry those values, and an override replaces exactly one.
- `test_providers.py`: the local cleanup builder's client carries the configured startup and request timeouts (fails on `main`).
- `test_engine.py`: the client `engine._local_client` builds carries the configured adapter and `summary_language == "auto"` whatever the configured summary language, so PIPE12's adapter fix and its deliberate skip are both pinned through the factory.
- `bash scripts/ci-local.sh pipeline` green, with the number of new tests in the commit body.
