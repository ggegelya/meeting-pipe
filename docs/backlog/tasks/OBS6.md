# OBS6: the Verbose logging toggle adds no diagnostic detail anywhere, yet turning it on writes verbatim transcript text into the event log

Band origin: filed 2026-10-25 from the 2026-10-25 observability audit band ([audit](../../audits/2026-10-25-observability-audit.md) row O22; finder LG-7). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Verified in code on 2026-10-25 (base `01e904a`).

**What the toggle promises.** Preferences ▸ Advanced (`PreferencesView+Advanced`) renders "Verbose logging" with the sublabel `"Emit extra detail to the unified log and pass MP_VERBOSE=1 to pipeline subprocesses."` The design kit mirror (`design/ui_kits/macos_app/PreferencesWindow.jsx`) carries the same sublabel. Root `CLAUDE.md`'s Quick reference describes it as a working verbose run: "`MP_VERBOSE=1` is exported when `UISettings.verboseLogging` is on".

**What it does.**

- `AppDelegate` at launch: `if UISettings.shared.verboseLogging { Log.main.info("verbose logging: ON"); setenv("MP_VERBOSE", "1", 1) }`.
- **Nothing reads `MP_VERBOSE`.** `grep -rn MP_VERBOSE pipeline/src` finds no hit. `pipeline/src` has no `.debug(` call at all (the finder counted one; on 2026-10-25 there are none), and `_configure_logging` sets the root logger to `INFO` unconditionally.
- **The daemon gates no detail on it.** The only `Log.*.debug` in `daemon/Sources` is `"verbose logging: off"`, and os.Logger debug lines are not persisted by macOS in any case, so "extra detail to the unified log" could not reach a file even if it existed.
- **Its only consumer adds content.** `TranscriptTab` reads `UISettings.shared.verboseLogging` twice: `transcript_correction` gains `original_text` and `edited_text`, and `vocabulary_term_added` gains `heard` and `canonical`. SEC14 (archived in [q6-final.md](../q6-final.md)) put that text behind the toggle on purpose so the default log carries lengths only. So turning the toggle on to diagnose a missed meeting buys verbatim transcript sentences in `events.jsonl` and nothing else.
- **Not reached on this Mac:** `defaults read com.meetingpipe.daemon mp.ui.verboseLogging` does not exist.

**Why no fence caught it.** `scripts/truth_fences.py`'s dead-knob check diffs `config.toml` key sets and documents that `UISettings` is outside it ("Read a pass here as 'no dead *config* key', never as 'no dead knob'"). An environment variable the daemon exports for the pipeline is a third store that neither side checks.

## Scope

0. **Owner decision, before any code: make it real or remove it.** Recommended: make it real, narrowly, because a missed-meeting investigation is the one time extra detection narration is worth its size, and the toggle is already the opt-in SEC14 hangs the correction text on. Removal is the fallback if the owner would rather not carry it.

**If made real (recommended):**

1. **Pipeline.** `_configure_logging` and OBS4's shared formatter set the `mp` logger (not the root, so `httpx`, `urllib3` and the mlx stack stay at INFO and cannot log request detail) to `DEBUG` when `MP_VERBOSE == "1"`. Add `log.debug` lines at the decision points a failure investigation needs: backend resolution and the workflow overlay in `workflow.apply_overrides` (which already logs "Workflow overlay applied" at INFO), sink selection in `publish_router`, the summarize path choice (staged, local, cloud) and the no-speech and suspect-transcript guards in `orchestrate`. No transcript or summary text in any of them.
2. **Daemon.** Verbose detail goes to the files, not os.Logger: a `Log.verbose(_ category:, _ message:)` that is a `Log.writeLine` gated on the live `UISettings.shared.verboseLogging`, with lines at the detection decision branches (`MeetingSourceScanner` admission and rejection reasons, discovery cooldown, the end engine's hold and confirm) and the recorder's device and format decisions. These are narration; failures stay unconditional through OBS1's `Log.failure`, which is never gated.
3. **Honest sublabel**, in the view and the design kit mirror: it adds detection and pipeline detail to the log files, and it also writes the text of transcript corrections and vocabulary terms into the event log.
4. **Fence the env var.** A truth-fence check (new `env` mode in `scripts/truth_fences.py`) that every `MP_*` name the daemon exports (a `setenv("MP_` call or an `env["MP_` assignment under `daemon/Sources`) is read somewhere under `pipeline/src`. It would have caught this, and it covers OBS4's `MP_RUN_ID` and `MP_STEM` when they land.

**If removed:**

1. Delete the toggle, `UISettings.verboseLogging` and its key, the `setenv`, and the two `TranscriptTab` branches, so correction events carry lengths only, always.
2. Delete the root `CLAUDE.md` Quick reference line and the design kit row.
3. The same item 4 fence.

Either way: `docs/GUIDE.md` and `README.md` do not mention the toggle today (checked 2026-10-25); if a recipe is added for it, it lands in the same commit.

## Explicitly not / out of scope

- Making os.Logger debug output persistent (a logging profile). It needs a configuration profile and is still unreadable to `mp logs`.
- Changing what the default (non-verbose) logs carry. OBS1 to OBS5 do that unconditionally.
- Verbose transcript text anywhere new. The existing two events are the only content the toggle may add.
- A per-run verbose flag from the Library. The toggle is daemon-wide and read at spawn; a one-shot flag is a separate request.

## Acceptance

- Made real: a pytest that with `MP_VERBOSE=1` the `mp` logger is at DEBUG and a debug line from `apply_overrides` reaches the configured handler, while the root and `httpx` loggers stay at INFO; without it no debug line is emitted. A Swift test that `Log.verbose` writes to the named log only while the setting is on.
- Removed: the `TranscriptTab` correction tests assert `original_text` and `heard` are never present.
- The env fence passes on the tree, and fails on a scratch daemon source exporting an unread `MP_FOO`.
- `python3 scripts/truth_fences.py` green; `cd daemon && swift test` and `cd pipeline && uv run --extra dev pytest -q` green, ruff and pyright clean; `bash scripts/ci-local.sh` green. N new tests in the commit body.
