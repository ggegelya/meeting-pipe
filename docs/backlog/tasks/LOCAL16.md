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
