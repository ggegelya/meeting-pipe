# TYPE2: The Python lint and type config states more than it enforces: 34 noqa directives for rules that are off, an unchecked line length, an unlinted scripts tree, and blanket type ignores hiding two real errors

Band origin: filed 2026-10-25 from the 2026-10-25 code-quality audit band ([code-quality audit](../../audits/2026-10-25-code-quality-audit.md) PY14, CV1, CV5). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Predecessor: [TYPE1](../q6-final.md) (shipped 2026-07-10) put pyright basic over `src/` in CI and left "ratcheting to strict" as a later decision. CI8 made ruff's rule set explicit after an upstream default change broke CI: `[tool.ruff.lint] select = ["E4", "E7", "E9", "F"]` in [`pipeline/pyproject.toml`](../../../pipeline/pyproject.toml), with a comment saying that wider families are "a deliberate commit, not something an upstream release gets to do for us". This is that commit. Re-measured on 2026-10-25 with the locked ruff 0.15.12 and pyright 1.1.411, scratch configs only:

- **Suppressions for rules nothing enables.** `ruff check src tests --extend-select RUF100` reports 34 unused `noqa` directives, all "non-enabled": 24 `BLE001` (23 in `src`, 1 in `tests/test_publish_router.py`), 4 `N802`, 3 `ARG002`, 2 `ANN001`, 1 `ARG001`, the last ten all in `tests/`. The only `noqa` in `src` and `tests` that suppresses a live rule is `tests/test_entry_contract.py`'s `from . import entry  # noqa: F401`. A reader takes each directive as evidence a rule is on.
- **A line length nothing checks.** `line-length = 100` is set and `E501` is not selected; 192 lines exceed it (107 in `src`, 85 in `tests`). The setting still does something: ruff falls back to it for import wrapping once `I` is on, which nobody has written down.
- **`scripts/` is never linted.** `ci-local.sh`'s `pipeline` job runs `ruff check src tests`. `scripts/gen_contract_fixtures.py` carries a live F401 today: `from mp import prefetch_model, publish_router, speaker_overlay  # noqa: E402`, where `prefetch_model` is never used because the script reads `prefetch_model.py` with `ast.parse`. The root `CLAUDE.md`, `CONVENTIONS.md` ("Any F401 (unused import) fails CI") and `pipeline/CLAUDE.md` all promise that cannot happen. Run from `pipeline/`, `ruff check ../scripts` resolves `pipeline/pyproject.toml` (the cwd fallback, checked with `--show-settings`), so including it needs no second config.
- **Blanket type ignores against the per-site rule.** `pipeline/CLAUDE.md` says "Don't reach for a blanket suppression". `src` has 7 `# type: ignore` comments, and pyright treats the mypy-style bracket codes on them as blanket. With `reportUnnecessaryTypeIgnoreComment` on, 5 are dead: the two `import soundfile as sf  # type: ignore` in `diarize.py`, the two `httpx` transport assignments in `egress_guard.arm` (`# type: ignore[method-assign]`), and `overlay.summarization.backend = "local"` in `workflow.apply_overrides`. With `enableTypeIgnoreComments = false`, the other 2 surface as errors:
  1. `providers._openai_cleanup` calls `functools.partial(oai.complete, json_mode=True)` on the result of `_openai_summary`, whose declared return is `SummaryClient`, a Protocol with no `complete`. It works at runtime because the object is an `OpenAIClient`. The same erasure is why `_plain_text(_openai_summary)` and `_plain_text(_claude_cli_summary)` type-check only because every text builder returns `Any`, and so `services.TextClient`, the PROV1 Protocol for free-form clients, annotates nothing and checks nothing.
  2. `workflow.apply_overrides` assigns `backend_raw`, a `str` narrowed only by `backend_raw in BACKENDS`, to a `BackendName` Literal field. Runtime-safe, statically a hole.
- **What pyright `standard` costs.** Basic and standard both report 0 errors over `src` with ignores enabled, and the same 2 with them disabled. Standard is free today.
- **The proposed ruff set.** `E4 E7 E9 F B A PIE SIM RUF100 I UP`, with `lint.external = ["BLE001"]` so RUF100 keeps the 24 `BLE001` markers for the observability audit: 65 findings in `src`, 62 in `tests`, 10 in `scripts`, 137 total, 95 safe-autofixable. By rule: UP017 33, I001 27, UP037 18, B905 10, RUF100 10, SIM105 9, SIM102 7, SIM117 7, UP035 5, B017 4, A002 2, and one each of B006 (a mutable default in `tests`), F401, PIE810, SIM103, SIM300.

Re-checked at filing: the audit's "88 findings, 72 autofixable" is `src` alone without the BLE001 carve-out (88, 68 safe-fixable), and the two "real errors" are type-level lies with no runtime failure today.

## Scope

1. **Ruff.** `select = ["E4", "E7", "E9", "F", "B", "A", "PIE", "SIM", "RUF100", "I", "UP"]`, `external = ["BLE001"]` with a comment naming the observability audit as its owner. Apply the safe fixes, then hand-decide the rest: each B905 `zip` gets an explicit `strict=` chosen by reading the call, B017 narrows to the real exception, B006 gets a `None` default. Pre-registered bar: a family whose findings read as pure churn (no defect, no dead construct) goes in `ignore` with a one-line reason instead of being rewritten. PLR2004, TRY003, PLC0415 and T201 stay off as noise.
2. **Line length.** Keep `line-length = 100` and say in the comment that it drives `I` import wrapping only; `E501` stays off (192 lines of churn with no defect behind them).
3. **Scripts.** `ci-local.sh pipeline` runs `ruff check src tests ../scripts`; fix the F401. The root `CLAUDE.md` lint row, `CONVENTIONS.md`'s "Ruff is strict in CI" block and `pipeline/CLAUDE.md`'s command list name the new target.
4. **Pyright.** `typeCheckingMode = "standard"` and `enableTypeIgnoreComments = false`. Delete the 5 dead ignores. Fix the 2 errors at their seam: `_claude_cli_summary` and `_openai_summary` return their concrete client types (imported under `TYPE_CHECKING`), and `_local_text`, `_anthropic_text`, `_auto_text` and `_plain_text` return `TextClient`, which a scratch run confirmed is 0 errors in standard; `workflow.apply_overrides` narrows `backend_raw` with `typing.cast` or a small `TypeGuard`. `# pyright: ignore[reportMissingImports]` is unaffected by the flag, so the mlx lazy imports keep their suppression.
5. Update `CONVENTIONS.md`'s pyright paragraph and `pipeline/CLAUDE.md` from "basic" to "standard", and say a `# type: ignore` now does nothing.

## Explicitly not / out of scope

- `BLE` and every `except Exception` site: the parallel observability and error-handling audit. This task only stops RUF100 deleting their markers.
- `reportUnnecessaryTypeIgnoreComment` as a gate: the mlx `# pyright: ignore` comments are unnecessary on the owner's Mac and necessary on the Linux runner, so the check would flap by platform.
- `strict` mode (1,004 errors, dominated by untyped dicts) and pyright over `tests/` (41 in basic). Both stay later decisions, as TYPE1 left them.
- Linting `docs/spikes/*.py` (owner-run, archived probes) and `daemon/Tests/MeetingPipeTests/Fixtures/failure-process.py`.
- The dead symbols and duplication sweep: [HYG16](./HYG16.md). `summarize_staged.py`'s two B905 sites vanish if [PIPE20](./PIPE20.md) deletes the module first.

## Acceptance

- `cd pipeline && uv run --extra dev ruff check src tests ../scripts` green under the new select; `--extend-select RUF100` reports nothing beyond what `external` keeps.
- A planted unused import in `scripts/` fails `bash scripts/ci-local.sh pipeline` (tried and reverted, said in the commit body).
- `uv run --extra dev --extra mcp pyright` green in standard with `enableTypeIgnoreComments = false`; `git grep -n "type: *ignore" pipeline/src` returns nothing.
- A planted `x: int = "a"  # type: ignore` in `src` fails pyright (tried and reverted).
- `uv run --extra dev pytest -q` green with no test added or removed by the lint fixes; `bash scripts/ci-local.sh pipeline` and `python3 scripts/truth_fences.py` green after the doc edits.
