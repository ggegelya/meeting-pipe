# VALID1: on-device acceptance runbook

These five bars (A15, A16, DIAR1, SUM1-APPLE, UX4) shipped code in Q3 but were never validated on a real machine. They are **runtime acceptance, not code**: each has to be run on a real Apple-Silicon Mac with real meeting audio. This runbook is the checklist, the exact command per bar, the pass threshold, and where to read the result.

A helper, `scripts/valid1_check.py`, turns the event logs the daemon and pipeline already write into a readable report and makes the one event-shaped bar (UX4) a hard pass/fail. It does not measure quality or egress; those stay manual.

```bash
scripts/valid1_check.py            # UX4 check + the latest runs' stage timings
scripts/valid1_check.py --ux4      # only the UX4 assertion (exit 1 on fail)
scripts/valid1_check.py --timings  # only the run/stage timing table
scripts/valid1_check.py --since 2026-06-03T00:00:00Z
```

Event logs read by the helper:

- `~/Library/Logs/MeetingPipe/events.jsonl` (daemon: `recording.degraded` / `recording.recovered`, mic-gate, lifecycle)
- `~/Library/Logs/MeetingPipe/pipeline_events.jsonl` (pipeline: `run_*` / `stage_*`)

Record the outcome of each bar in the table at the bottom.

---

## A15: local cold-start within 10%

**What:** measure the time for the first local (MLX) summary after a fresh launch, the cold path that pays the model load. Compare against the prior baseline (the warm second run, or a recorded earlier number).

**How:**
1. Quit MeetingPipe fully. Set `summarization.backend = "local"` and turn Preferences > Pipeline > Configure local model > Preload at launch **off** (so the first run is genuinely cold).
2. Launch, record a short meeting, Stop.
3. `scripts/valid1_check.py --timings` and read the `stage summarize` duration of that run (the first since launch). That is the cold-start.
4. Run a second meeting without relaunching and read its `stage summarize` (warm baseline).

**Threshold:** cold-start summarize within 10% of the prior recorded cold-start baseline. (Cold is expected to exceed warm; the bar is regression against the previous cold number, not warm.)

**Where:** the `stage summarize` rows in the helper's timing table.

## A16: re-run quality and latency

**What:** confirm the on-device summary quality and latency have not regressed since A16 first shipped.

**How:**
1. With `backend = "local"`, summarize a representative meeting.
2. Use the detail pane's "Re-run locally (preview)" to produce a second summary and eyeball it against the first for quality (coverage, no hallucinated actions/owners).
3. Read the `stage summarize` time from `--timings`.

**Threshold:** quality at least at parity with the last accepted A16 summary (manual read); latency in line with A15's warm number.

**Where:** preview side-by-side in the Summary tab; latency from the helper.

## DIAR1: diarization error rate and per-segment latency

**What:** diarization quality (DER) on a known multi-speaker recording, plus per-segment processing under 10 s.

**How:**
1. Record (or replay) a two-plus-speaker meeting where you know who spoke when.
2. After Stop, inspect the speaker labels in the Transcript tab against ground truth and compute DER (mislabelled speech time / total speech time).
3. For latency, read the diarization stage from the timing table; per-segment must stay under 10 s.

**Threshold:** DER within the DIAR1 target; no segment over 10 s.

**Where:** Transcript tab for labels; helper timings for latency. (Diarization runs in the Swift daemon via FluidAudio; if a stereo channel-aware fallback ran instead, note it.)

## SUM1-APPLE: Apple Intelligence quality, latency, zero egress

**What:** the macOS 26 Foundation Model summarizer at parity with local, within 2x latency, and provably zero-egress.

**How:**
1. On an Apple-Intelligence-capable Mac (macOS 26+), set the global backend to Apple (Preferences > Pipeline) or pin a workflow to Apple Intelligence (now selectable per TECH-WF1).
2. **Install and arm Little Snitch.** Summarize a meeting and confirm Little Snitch shows **no** outbound connection for the summary (the model runs on-device; the daemon produces the summary and the pipeline only publishes if a sink is configured).
3. Compare the summary against a local-backend summary of the same transcript for quality, and read the latency.

**Threshold:** quality at least at local parity; latency within 2x of local; **zero non-loopback connection** during summarization per Little Snitch.

**Where:** Little Snitch network monitor (manual, authoritative for egress); Summary tab for quality; helper timings for latency.

## UX4: live degraded banner on a real failed SCStream

**What:** when system-audio capture genuinely fails mid-recording, the HUD shows the degraded banner and a `recording.degraded` event is written (and `recording.recovered` when it comes back).

**How:**
1. Start a recording.
2. Force a real SCStream failure: revoke Screen Recording permission mid-call (System Settings > Privacy & Security > Screen Recording), or stop the captured target.
3. Watch the HUD for the degraded banner. Restore the condition and watch for recovery.
4. `scripts/valid1_check.py --ux4`.

**Threshold:** the banner appears within a second or two of the failure; `--ux4` exits 0 with at least one `recording.degraded` event (and a `recording.recovered` after restore).

**Where:** the HUD live; `scripts/valid1_check.py --ux4` for the event assertion.

---

## Results

| Bar | Date | Result | Measured | Notes |
|---|---|---|---|---|
| A15 cold-start within 10% | | | | |
| A16 quality + latency | | | | |
| DIAR1 DER + under-10s | | | | |
| SUM1-APPLE quality / 2x / zero-egress | | | | |
| UX4 degraded banner + event | | | | |
