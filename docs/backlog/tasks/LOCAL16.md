# LOCAL16: Local-LLM resource protection: RAM tiers, fail-closed spawn, free-RAM watchdog

Band origin: filed 2026-07-29 (owner exploratory sweep, item 8: "check the available resources, and limit the capabilities to certain threshold of memory... make it crystall clear to the user... and make a system 100% protected from hangs and out of memory things"). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

P1 because the broken promise is that on-device processing degrades by refusing with a reason, never by hanging the machine, and the machine has been taken down twice: the 14B OOM-hung this 32 GB Mac at long context (recorded in the `local_model` default's own comment, `config.py:123-127`, and AI2's measurements), and the 2026-07-29 `mp ask` incident ended in a hard reboot (AI11 carries that trace). The owner may re-band.

## Context

What exists today, verified 2026-07-29:

- **The only RAM check in the product is `mp doctor`**: `_estimate_model_gb` (0.62 GB per billion params, `doctor.py:287-300`), `_physical_ram_gb` via `sysctl hw.memsize` (:303-317), compared in `check_local_stack` (:375-387) as fail / warn(+4 GB headroom) / ok. It is advisory, manual-only, against TOTAL physical RAM (not free), and nothing in `run-all`, `summarize`, `serve-local`, or `ask` calls it.
- **No free-RAM watchdog is shipped anywhere.** The protocol exists as a shell snippet in the LOCAL13 bench doc (`docs/spikes/local13-local-model-refresh-bench.md:215-234`: kill `mlx_lm.server` below 10% free, `vm_stat`-based) and as AI2's harness-local guard; neither ever became product code. Grep for `vm_stat` / `psutil` / `hw.memsize` outside doctor: zero hits.
- **The server spawn has no memory levers and hides its death note.** `build_server_command` emits only model/host/port/adapter (`summarize_local.py:255-276`); no `--max-kv-size`, no cache limit. Spawned with `stdout=DEVNULL, stderr=STDOUT` (:736-737), so an OOM message from the server is discarded, and the failure surfaces as the generic "exited during startup (rc=...). Check that the model name resolves and you have enough RAM" guess (:765-768).
- **The user-facing limits are static prose.** `LocalModelPreset.all` (`PreferencesWindow.swift:93-118`) hardcodes "~2 GB / ~4.3 GB / ~8 GB" and "wants 24 GB+ RAM (can OOM on 16 GB)" as strings; nothing reads the machine. `ProcessInfo.processInfo.physicalMemory` is used nowhere in the app (only inside vendored FluidAudio).
- **The precedent for a fail-closed refusal already exists at the right seam**: `_spawn` refuses an uncached model under the egress guard with an actionable message Swift pattern-matches (`summarize_local.py:721-731`), mirrored by `mp serve-local` (:1029-1039). A RAM-tier refusal is the same shape at the same seams.
- **Measured numbers to build the tier table from**: 4-bit resident ~0.55-0.62 GB/B params (LOCAL13 :79, doctor's estimator); 7B ~4.3 GB measured; 14B ~8 GB, "OOM-unsafe above ~13k-char transcripts" on 32 GB (engine-comparison.md:11, :25); MoE 17-20 GB excluded outright (LOCAL13 :90); AI2's context boundaries (14B fine at 4K, watchdog-abort at 8K, OOM at 16K).

## Scope

1. **A shared resource-guard module** (`pipeline/src/mp/resource_guard.py` or similar): physical-RAM read, a free-memory sampler (`vm_stat` pages-free+purgeable derived, cheap enough per-batch), a pure tier policy (physical RAM to max advisable model GB and a context-token ceiling), and a watchdog helper that aborts the owning run with a typed, surfaced error when free memory crosses the floor (default 10%, config-backed, documented in `config.example.toml` per CI5). Pure `decide` separated from sampling so the policy is table-tested.
2. **Fail-closed spawn.** `_spawn` and `mp serve-local` refuse a model whose estimate exceeds the tier for this machine, with the `summarize_local.py:721-731` message shape naming the smaller preset ("This Mac has 16 GB; the 14B preset needs about 24 GB. Pick Small or Recommended in Preferences > Pipeline."). An explicit override env (`MP_RAM_GUARD=0`) for bench runs, documented as owner-dev.
3. **Watchdog on the paths that can swap the machine**: the local summarize request loop and AI11's embed/answer path consume the same helper; an abort emits a `pipeline` event and writes the failure sidecar naming memory as the stage, so the Library row's failed state says why.
4. **Surfaced limits.** The Preferences preset picker reads `ProcessInfo.processInfo.physicalMemory` and annotates each preset live ("fits comfortably" / "little headroom" / "needs ~24 GB; this Mac has 16"), graying the over-tier preset with the reason (truthful-disabled, the UX30 rule). `LocalModelPreloader.shouldPreload` (already a pure gate, `LocalModelPreloader.swift:64-66`) gains the same term so a warm server is never preloaded over tier. `mp doctor` keeps the deep check and gains the tier line. SETUP.md's model-choice paragraph updates in the ship commit (DOC10 rule).
5. **Capture the server's stderr** to a rotated log file (or the existing pipeline log) instead of DEVNULL, so the next OOM postmortem has the actual message.

## Explicitly not in scope

Automatic model downgrade or dynamic quantization fallback (refusal with a named alternative is the contract; silent substitution hides the quality change). MLX cache-limit tuning experiments beyond what AI11 needs (`mx.clear_cache` between embed batches is AI11's leg; a server-side cache lever, if mlx-lm grows one, is a future amendment). Killing or throttling other processes. The LOCAL13 bench itself and its 12 GB bar (owner-owed there). Context-length truncation policy for single-pass summarize (the 80k threshold stands; the guard aborts before swap rather than silently truncating content).

## Acceptance

Pipeline tests: the pure tier policy table (16/24/32/48 GB against 3B/7B/14B and an unparseable model id); spawn refusal (estimate over tier raises the typed error naming the preset, no `Popen` attempted; override env bypasses); watchdog abort with an injected sampler (floor crossing raises, event emitted, failure sidecar stage says memory); stderr of a failing fake server lands in the log.

Daemon tests: preset annotation derivation per RAM size (pure, table-tested); `LocalModelPreloader.shouldPreload` false when over tier; the grayed preset carries the reason string.

Truth fences green with the new config key(s) documented in `config.example.toml` and README in the same commit. Both suites, ruff, pyright green (baselines at filing: 1770 Swift, 1050 Python).

Owner eyeball on this 32 GB Mac: the 14B preset annotates per the table (fits, with the headroom caveat), a simulated 16 GB tier (env override for the test, or the unit table) refuses it, and a local summarize under artificial memory pressure aborts with the named error instead of beachballing the Mac.

## Progress (shipped 2026-07-30, owner-owed on the eyeball)

All five scope items landed; the status stays `owner-owed` only for the eyeball clause above, which needs a rebuilt app in front of a human and a real memory-pressure run.

**The guard module.** `pipeline/src/mp/resource_guard.py` carries the three pieces separably, because AI11 consumes two of them without wanting the third: the sizing helpers (`estimate_model_gb` / `physical_ram_gb`, promoted out of `doctor`, which was no longer their only reader), the pure tier policy (`tier_for` / `assess` / `refusal_message`), and `MemoryWatchdog`, whose sampler and clock are both injectable and whose `check(stage=)` is throttled so an embed loop can call it per batch without paying for a `vm_stat` per iteration.

**The tier table is anchored on measurements, not on a ratio** (a flat "RAM / 3" was tried first and put the 14B over on 24 GB, contradicting its own shipped copy). Rows: 8 GB admits 2.5 GB / 2K tokens, 16 GB admits 5.0 / 4K, 24 GB admits 9.0 / 4K, 32 GB admits 9.0 / 8K, 48 GB admits 20.0 / 16K. That reproduces every number the product already asserts: the 7B runs on 16 GB but tight, the 14B is refused there ("can OOM on 16 GB"), 24 GB is its floor, and on the owner's 32 GB it is still `tight` rather than comfortable, which is the honest reading of a model that has OOM-hung that exact machine.

**Decided, not in the spec: the guard refuses only what it can measure.** A repo id with no parameter count (any Custom preset) assesses `unknown` and is never refused on size, because guessing that a custom id is too big would close the one escape hatch a user has; the watchdog is the backstop for that case. Same fail-open rule when physical RAM cannot be read.

**Decided, not in the spec: the cross-language marker.** The daemon writes `<stem>.error.json`, not Python, so "failure sidecar naming memory as the stage" is implemented as a new `PipelineFailureSidecar.Stage.memory` that `SinkDispatcher.stage(for:)` selects by matching the phrase `Not enough memory` that both the refusal and the abort carry. That is the UX21 `not in the local HuggingFace cache` arrangement, and CONVENTIONS now records it beside the exit-3 mapping. The exit-3 publish mapping deliberately still wins over the marker.

**Decided, not in the spec: the suite pins the guard off.** A `conftest.py` autouse fixture sets `MP_RAM_GUARD=0`, so no unrelated local-client test can fail because the developer's Mac was under pressure or a CI runner is smaller than the model a fixture names; the two files that test the guard turn it back on and pass an explicit `ram_gb`.

**Also shipped:** the server's stdout and stderr now go to a rotated `~/Library/Logs/MeetingPipe/mlx-server.log` (both from the lazy spawn and, via `dup2` before `execvpe`, from the warm `mp serve-local`), and the startup-failure message quotes that log's tail instead of guessing between two causes. `mp doctor` gained a tier line reading the same policy the spawn enforces, plus the current free-memory reading. `LocalModelPreloader.shouldPreload` gained a `fitsMemory` term. `diarize_cleanup` and `engine` (the `mp ask` answer leg) both build their client on the configured floor.

**Verified:** pipeline ruff + pyright clean, 1131 pipeline tests green (51 new: 43 in `test_resource_guard.py`, 8 in `test_summarize_local.py`); `swift build` clean and 1908 daemon tests green (17 new: 14 in `LocalModelTierTests.swift`, 1 in `LocalModelPreloaderTests.swift`, 4 in `SinkDispatcherTests.swift`, less the signature updates); CI5 truth fences green with `summarization.local_memory_floor_pct` documented in `config.example.toml` and the README reference. Docs: README (config reference, local-model paragraph, two troubleshooting entries), ARCHITECTURE (the `resource_guard` bullet, `LocalModelTier`, the preloader's new gate, the error-sidecar stage vocabulary in two places), CONVENTIONS (the memory-marker contract), `docs/SETUP.md` (step 7's model-choice paragraph), root `daemon/CLAUDE.md` and `pipeline/CLAUDE.md` (file index, promoted helpers), and `design/ui_kits/macos_app/PreferencesWindow.jsx` (the local-model row, which was also still showing the pre-LOCAL6 14B as "Recommended").

**Not done, deliberately:** no golden fixture pins the Swift/Python mirror. The two tier tables are pinned by the same worked rows in both suites and each file names the other, which is the `MuteLabels`-style arrangement rather than the CI4 one; a fixture would be the stronger fence if this table ever starts changing.

## Owner walkthrough (for the session that picks this up)

Steps are tagged [owner] / [session] by who acts. The owner does not read code; everything below is done from the app or one pasted command.

1. [session] `./scripts/rebuild.sh`, then tell the owner it is ready.
2. [owner] Preferences > Pipeline > Configure local model. Open the **Local model** menu. On this 32 GB Mac all three presets should be selectable, and the sublabel under the row should end with a sentence about *this* Mac: "Fits comfortably on this Mac (32 GB)" for Small and Recommended, "Runs on this Mac (32 GB) with little headroom" once Large is selected. Nothing should read "wants 24 GB+ RAM" any more, and no row should say 32.0.
3. [owner] The refusal is not reproducible on a 32 GB Mac without lying to the app, so it is checked from the pipeline side instead. Paste this and read the last lines: `cd <repo>/pipeline && uv run mp doctor 2>&1 | sed -n '/local summarization stack/,/local model server/p'`. Expect a `memory tier:` line naming 32 GB, the admitted size, and the token ceiling, then a verdict on the configured model, then a `free memory now:` reading. Nothing should fail.
4. [owner] The refusal text itself, on a pretend 16 GB Mac: `cd <repo>/pipeline && uv run python -c "from mp import resource_guard as r; print(r.refusal_message(r.assess('mlx-community/Qwen2.5-14B-Instruct-4bit', 16.0)))"`. It should name the Mac's 16 GB, say the model needs about 24 GB, and tell you to pick Recommended (Qwen 7B-4bit) in Preferences > Pipeline. If that sentence would confuse you in a Library row, say so and it gets rewritten.
5. [owner] The watchdog under real pressure, the one leg that needs a live run. Start a local summarize (Library > any meeting > Re-summarize with > Local MLX) and, while it runs, push the Mac's free memory under 10% (opening a large app, or a `memory_pressure -l critical -S -s 60` in a terminal, is enough). Expected: the run stops within a couple of requests with "Not enough memory: free RAM fell to N% during local summarize", the Library row goes to Failed with the reason visible, and **the Mac stays responsive**. A beachball here is the bug this whole task exists to remove, and is worth reporting immediately.
6. [owner] Say "LOCAL16 good to close" (or what is wrong); [session] moves the row and the spec into `q6-final.md` and deletes this file.
