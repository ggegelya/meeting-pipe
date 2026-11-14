---
id: PIPE42
title: Unknown or misplaced config keys are dropped without a word, including the regulated-mode switch, and a misspelt sink fails only after the summary is paid for
category: Pipeline
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). Appending the README's `modes.regulated_mode = true` to the end of config.toml nests it under the last table (`transcription` in the owner's Swift-written file), pydantic drops it and the Swift reader misses it too, so regulated mode stays off; a wrong-typed `regulated_mode = "true"` reads true in Python and false in Swift, which then saves false; a misspelt sink raises only after summarize. Fail closed on a misplaced section table, warn on unknown keys in the Python-owned sections, validate sink names at load and in doctor, and read regulated_mode's wrong types closed in ConfigStore. promote before enabling regulated or NDA.
---

# PIPE42: Unknown or misplaced config keys are dropped without a word, including the regulated-mode switch, and a misspelt sink fails only after the summary is paid for

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: F095 in the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md) ("Unknown or misplaced config keys are silently dropped, including the regulated-mode switch", security lens, confirmed), with F213 from the same audit ("Wrong-typed regulated_mode silently reads false and is then overwritten on save") folded in as its Swift twin. No field evidence: the owner never turned regulated mode on.

**Python, re-verified at HEAD `3a2da4fc` on 2026-11-14.** In `pipeline/src/mp/config.py`, `Modes`, `Summarization`, `OutputCfg`, `NotionCfg`, `ObsidianCfg`, `FilesystemCfg`, `LanCfg`, `MCPCfg` and the top-level `Config` declare no `model_config`, so pydantic's default `extra='ignore'` drops any unknown key without a word and the default wins. `Recording`, `Detection` and `Transcription` declare `model_config = {"extra": "ignore"}` on purpose: their docstrings record legacy keys and Swift-owned keys that Python must tolerate (ARCH9, ADR 0007). `Config.load` is `tomllib.load` then `cls(**raw)`. `OutputCfg.sinks` is `list[str]`, and an unknown name raises `PublisherBuildError(f"unknown sink in output.sinks: {name!r}")` only from `publish_router._build_one`, which `publish_fanout` reaches after summarize has run. `doctor.check_config` prints `output.sinks` and `modes.regulated_mode` but validates neither.

**The misplaced-key scenario holds, and lands in a worse table than the audit named.** TOML dotted keys bind to the last open table: `tomllib.loads('[mcp]\nenabled = false\nmodes.regulated_mode = true\n')` returns `{'mcp': {'enabled': False, 'modes': {'regulated_mode': True}}}` (checked 2026-11-14). The README writes the switch as `modes.regulated_mode = true` in three places. Correction at filing: the audit's example lands under `[mcp]`, the last table of `config.example.toml`, but the owner's live `config.toml`, which `ConfigStore` re-serializes through TOMLKit on every save, has its tables in alphabetical order and ends with `[transcription]` (table names checked 2026-11-14). An appended `modes.regulated_mode = true` there becomes `transcription.modes`, inside a model that declares `extra='ignore'` on purpose, so making only the four named sections strict would not catch it. The check has to recognise a misplaced section, not only an unknown key.

**Swift, re-verified at HEAD (F213).** `ConfigStore` reads `self.regulatedMode = file.parseError != nil || (mod?["regulated_mode"]?.bool ?? ConfigDefaults.regulatedMode)`. The fail-closed half (ARCH9) covers only a file that does not parse. A misplaced key leaves `mod` (the `modes` table) without it, and a wrong-typed `regulated_mode = "true"` or `= 1` makes `.bool` nil; both read false. Python's pydantic lax mode coerces `"true"` and `1` to `True`, so the two trees then disagree about the same file, and the next Preferences save writes `ensureTable("modes")["regulated_mode"] = regulatedMode`, i.e. `false`, over the owner's intent.

**Owner's live file today.** A keys-only comparison of the owner's `~/.config/meeting-pipe/config.toml` against every Python model on 2026-11-14 found no unknown keys in any section, so a strict check does not break the current install.

Related: ARCH9 and [ADR 0007](../../decisions/0007-python-sidecar.md) (the deliberate `extra='ignore'` placeholders), [UX94](./UX94.md) (a config that does not parse), [SEC21](./SEC21.md) (workflow files, not config.toml), and UX96 from the same band (the Swift save that re-reads before writing).

## Scope

1. **A misplaced section fails closed.** In `Config.load`, before `cls(**raw)`, walk every table and raise a new `ConfigError` (config.py has none today) naming the path when a nested table's name is a top-level section name (`transcription.modes`, `mcp.modes`, `summarization.output`, and so on). This is the same posture as a file that does not parse: no run egresses on a config whose regulated switch might be sitting in the wrong table.
2. **Unknown keys in the Python-owned sections warn, loudly.** For `modes`, `summarization`, `output`, `notion`, `obsidian`, `filesystem`, `lan`, `mcp` and the top level, collect keys that are not model fields and log one warning per run plus `events.emit("pipeline", "config_unknown_key", section=..., key=...)`. `Recording`, `Detection` and `Transcription` keep `extra='ignore'` (their keys are legacy or Swift-owned) and are covered only by item 1.
3. **Sink names validated at load.** Type `OutputCfg.sinks` as `list[Literal["notion", "obsidian", "filesystem", "lan"]]` (the names `_build_one` accepts), so a misspelt sink fails `Config.load` before any model call, and `PublisherBuildError`'s unknown-name branch becomes unreachable from config.
4. **Doctor reports all three.** `doctor.check_config` FAILs on items 1 and 3 (it already turns a load exception into `config parse error`) and WARNs on each item-2 key.
5. **Swift reads the switch closed.** In `ConfigStore`, a `regulated_mode` that is present but not a TOML boolean reads as `true` (the ARCH9 fail-closed rule extended from a parse error to a wrong type), and a nested `modes` table under any other section does the same; Preferences shows the file needs fixing rather than saving `false` over it.

## Explicitly not

- `extra='forbid'` on every model: it would reject legacy keys ARCH9 deliberately tolerates in `[recording]`, `[detection]` and `[transcription]`, and turn an upgrade into a failed run.
- Workflow file validation: [SEC21](./SEC21.md).
- How a config load failure is surfaced in the app: [UX94](./UX94.md).
- The Swift save that writes from a stale in-memory copy: UX96.

## Acceptance

- `test_config.py`: `modes.regulated_mode = true` appended after `[transcription]` and after `[mcp]` each raise `ConfigError` naming the path; a top-level `[modes]` with `regulated_mode = true` still loads true.
- `test_config.py`: an unknown key in `[summarization]` and one at the top level each load with defaults, log one warning, and emit `config_unknown_key`; legacy keys in `[recording]` (`capture_mode`) and `[transcription]` (`model`) emit nothing.
- `test_config.py`: `output.sinks = ["obsidan"]` fails at `Config.load`; `["obsidian", "filesystem"]` loads.
- `test_doctor.py` (or the existing doctor tests): FAIL for a misplaced section and a misspelt sink, WARN for an unknown key.
- `ConfigStoreTests`: `regulated_mode = "true"`, `= 1`, and a `transcription.modes.regulated_mode = true` each read `regulatedMode == true`; a boolean `false` reads false.
- `config_unknown_key` is in `CONVENTIONS.md`'s event table and `python3 scripts/truth_fences.py events config` is green.
- `cd pipeline && uv run --extra dev ruff check src tests`, `uv run --extra dev --extra mcp pyright` and `uv run --extra dev pytest -q` green; `cd daemon && swift test` green; new test counts in the commit body; `bash scripts/ci-local.sh` green.
