# LOCAL15: Serve the LoRA adapter that `--adapter-path` silently drops

Band origin: filed 2026-07-23 (found while shipping LOCAL11, commit 65ba629; verified three ways in the filing session before filing). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

**LOCAL15 (P2, new): `summarization.local_adapter_path` is a no-op, because mlx-lm drops the `--adapter-path` flag LOCAL9's serving seam passes.** The base model serves regardless of the setting, silently, with no warning on either side. Correctness in character (a documented, README-advertised config knob does nothing), banded P2 rather than P1 only because the blast radius as of filing is zero: the knob is opt-in with an empty default and no adapter has ever been trained on this Mac. The owner may re-band.

## Context

`build_server_command` (pipeline/src/mp/summarize_local.py:154) appends `--adapter-path <dir>` when `summarization.local_adapter_path` is set. Both spawn paths use it: the lazy `LocalSummaryClient._spawn` and the warm `mp serve-local` (`summarize_local.main`, which `execvpe`s the same argv). `mp dogfood --adapter` is on the same seam and equally affected. The flag never reaches the model loader.

Verified three ways on 2026-07-23, so the pickup session does not need to re-derive any of it.

**(1) Code read**, mlx-lm 0.31.3 as installed in `pipeline/.venv`. `ModelProvider.__init__` keys its maps by the alias: `self._adapter_map["default_model"] = self.cli_args.adapter_path`. `ModelProvider.load` then does `model_path = self._model_map.get(model_path, model_path)` followed by `adapter_path = self._adapter_map.get(model_path, adapter_path)`, so the adapter lookup is keyed by the **already-reassigned** real model path while the map is keyed `"default_model"`. The lookup misses and the adapter falls back to `None`. The sibling line immediately below it, `draft_model_path = self._draft_model_map.get(draft_model_path, draft_model_path)`, keys off its original argument, so the adapter line is inconsistent with its own neighbours: a defect, not a design choice.

**(2) Empirical**, a real `ModelProvider` constructed with `_load` stubbed so the resolved arguments are observable without loading weights. `load_default()`, which is the path the server takes at startup, resolves to `adapter_path=None`: the adapter is dropped. A chat-completion request carrying the repo id as `model` and no adapter field also resolves to `None`. A request carrying the `adapters` body field resolves to the real path: the adapter is served.

**(3) Upstream, reported and unfixed.** Issue [ml-explore/mlx-lm#1248](https://github.com/ml-explore/mlx-lm/issues/1248), "mlx_lm.server --adapter-path silently ignored at startup", open since 2026-05-06 with the same root cause and a repro showing a bogus adapter path starting cleanly instead of raising. [PR #1249](https://github.com/ml-explore/mlx-lm/pull/1249) carries the one-line fix (bind `alias = model_path` before the reassignment, look up `_adapter_map` by the alias), open and unmerged since 2026-05-06, last touched 2026-06-04. Duplicate fix [PR #1365](https://github.com/ml-explore/mlx-lm/pull/1365) was closed unmerged on 2026-06-07. `main` on GitHub still carries the buggy line, and 0.31.3 is the latest PyPI release, so waiting for upstream or bumping the pin is not a plan.

**Why this is urgent rather than merely true.** LOCAL9 is `partial` with the owner-owed remainder "run `mp train-adapter --source runs --adapter-path <dir>`, then `mp dogfood --adapter <dir> <held-out transcript>`, hand-grade the scorecard, and set `summarization.local_adapter_path` only if it wins". If the adapter never serves, that A/B compares the base model against itself and returns a false negative, and an honest-looking "the adapter did not help" would wrongly close LOCAL9 after the owner spent real training and grading time. Resolve this before that A/B is run.

**Why LOCAL11 did not catch it, and structurally cannot.** LOCAL11 (shipped 2026-07-23, archived in [q6-final.md](../q6-final.md)) verifies what a warm server is serving by reading the listening process's argv. Argv is the **spawn contract**, not a readback of the loaded weights: it catches a server started for a different model or adapter, but a server handed `--adapter-path` and silently ignoring it looks correct from the outside. LOCAL11's archive entry records this under "Known limitation". This task is that blind spot.

## Scope

Decide between three routes and implement one. The evidence favours (a), but the decision is the task.

**(a) Send the adapter per request.** Add `"adapters": <path>` to the payload in `LocalSummaryClient._chat_completion` (pipeline/src/mp/summarize_local.py) when `self._adapter_path` is set. This is a documented public field, not an internal detail: `mlx_lm/SERVER.md` specifies `"adapters": (Optional) A string path to low-rank adapters`. It is also the only route the empirical test proved works on the installed version.

Two facts checked during filing so the pickup session does not re-check them. An **absolute** path is fine despite SERVER.md's "the path must be relative to the directory the server was started in" note: `mlx_lm/tuner/utils.load_adapters` does `Path(adapter_path)` then `.exists()`, so an absolute path resolves correctly, which matters because `local_adapter_path` holds a user-chosen absolute path. And that same function raises `FileNotFoundError` on a missing path, so route (a) additionally buys the fail-loud behaviour issue #1248 argues the CLI flag should always have had: a typo'd `local_adapter_path` currently fails silently and serves base.

**(b) Vendor the upstream one-line patch.** Rejected as the default because patching a dependency's source in a repo with a deliberately small dependency surface is a maintenance liability that survives every `uv sync`, and it needs re-verifying on every mlx-lm bump.

**(c) Pin and wait for upstream.** Weakest: the fix has been open and unmerged for roughly two and a half months and one duplicate was closed without merge.

**Cost to measure if (a) is chosen.** The server loads the base model at startup through `load_default()`, giving `model_key = (repo, None, None)`. The first request carrying `adapters` flips the key to `(repo, adapter, None)` and forces one model reload. The key is stable afterwards, so this is a one-time cost per server lifetime, not per request, but it partially defeats the warm-start benefit `mp serve-local` exists to provide, for adapter users specifically. Measure against the warm-start budget A15 baselined (cold 39.8 s, warm 31.4 s, 8.4 s load, 7B) and record the number; if it is material, the follow-on is teaching `mp serve-local` to warm the adapter-carrying key rather than the base one.

**Keep `--adapter-path` on the spawn command even if (a) lands.** Two reasons, and this is load-bearing rather than tidiness. LOCAL11's identity check reads the served adapter out of argv, so dropping the flag would make an adapter-serving server report `adapter_path=None` and read as a mismatch against a configured adapter on every run, inverting the check it was built for. And the flag becomes correct for free if upstream ever merges #1249. If the pickup session concludes the flag must go, LOCAL11's `served_identity` in pipeline/src/mp/local_server.py has to change in the same commit, along with the served-identity section of CONVENTIONS.md.

## Explicitly not

Not fixing mlx-lm upstream: filing or shepherding a PR against ml-explore/mlx-lm is out of scope, and #1249 already exists. Not changing `mp train-adapter`: the training side is unaffected, since it shells out to `mlx_lm.lora` and never touches the server. Not running the LOCAL9 A/B: that stays LOCAL9's owner-owed remainder, and this task is its precondition, not its replacement. Not revisiting whether an adapter is worth adopting: an honest negative from a *valid* A/B remains a fine terminal outcome for LOCAL9.

Observed but deliberately unfiled: mlx-lm's `/v1/models` cannot name the loaded model (it lists the whole HuggingFace cache), which LOCAL11 already worked around and documented in CONVENTIONS.md; no task is needed unless upstream changes that endpoint's contract.

## Acceptance

The decisive bar needs no trained adapter and no grading, so it is checkable on any Mac the moment the change lands: with `summarization.local_adapter_path` pointed at a directory that does not exist, a local summarize run **fails loudly** with the adapter path named, instead of silently producing a base-model summary. That single check distinguishes "the adapter is served" from the 2026-07-23 behaviour, and it is the reason it belongs in acceptance rather than the A/B.

Unit-pinned, in `pipeline/tests/test_summarize_local.py` against the existing fake-server fixture: the chat-completion payload carries `adapters` set to the configured path when one is configured, and omits the key entirely when `local_adapter_path` is empty (an empty string must not be sent as a path). A test that fails if the code regresses to relying on `--adapter-path` alone, so the next session cannot quietly undo this.

If `--adapter-path` is kept on the spawn command, per the scope note above, the existing LOCAL11 identity tests in `pipeline/tests/test_local_server.py` and `pipeline/tests/test_summarize_local.py` stay green unchanged; if it is removed, `served_identity` and the CONVENTIONS.md served-identity section change in the same commit and their tests are updated to match.

Green: `uv run --extra dev pytest -q`, `ruff check src tests`, `pyright`, `python3 scripts/truth_fences.py both`, plus `swift build` and `swift test` if the daemon side is touched at all.

Docs in the same commit: `config.example.toml`'s `local_adapter_path` comment and README's "Improving local quality" section describe the real serving route, and LOCAL9's spec note about preconditions to its A/B is updated to record that this one is resolved. The measured reload cost from the scope section is recorded in the ship note, whatever it turns out to be.
