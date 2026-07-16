# VALID1: on-device acceptance runbook

Five bars (A15, A16, DIAR1, SUM1-APPLE, UX4) shipped code in Q3 and were never validated on a real machine. This runbook is the checklist: the exact command per bar, the pass threshold, and where to read the result.

**All five are now closed (2026-07-16); see Results.** Three were machine-checkable once the scaffolding was fixed. Two needed a human and got one: a physically forced capture failure (UX4, 2026-07-15) and a person to say who was actually speaking (DIAR1 DER, 8.99%, 2026-07-16). One leg was **waived rather than measured** and is labelled as such rather than dressed up as a pass: SUM1-APPLE's zero-egress (now EGRESS1, P4).

This file stays as the reproduction recipe: every number below has the command that regenerates it, so a later regression is a re-run rather than an archaeology project.

`scripts/valid1_check.py` is the harness. Stdlib-only, so it runs on a clean Mac without `uv`.

```bash
scripts/valid1_check.py                 # every read-only bar at once
scripts/valid1_check.py --ux4           # UX4 assertion (exit 1 on fail)
scripts/valid1_check.py --diar          # DIAR1 latency (exit 1 on fail)
scripts/valid1_check.py --attribution   # speaker-attribution coverage
scripts/valid1_check.py --attribution --since 2026-06-01T00:00:00Z
scripts/valid1_check.py --coldstart     # A15: cold vs warm local summarize (runs the model)
```

What it reads:

- `~/Library/Logs/MeetingPipe/events.jsonl` (daemon: `recording.degraded` / `recording.recovered`, `transcription.engine_*`)
- `~/Library/Logs/MeetingPipe/pipeline_events.jsonl` (pipeline: `run_*` / `stage_*`)
- `~/Documents/Meetings/raw/<stem>.json` (transcripts, for `--attribution`)

> **Two traps this runbook used to walk into.** Both cost a quarter each; they are fixed here, and named so nobody re-walks them.
>
> 1. **ASR and diarization are not pipeline stages.** They moved to Swift (FluidAudio), so their timing lands in `events.jsonl` under `transcription.*`, not in the `pipeline.stage_*` table. The old DIAR1 and A15 recipes said to read the stage table, which structurally could not show them. The data was in the log the whole time.
> 2. **`mp summarize` emits no stage events at all.** Only `mp run-all` does (`orchestrate.py`). So "run `mp summarize` and read `stage summarize`" was never going to print anything. `--coldstart` wall-clocks the subprocess itself instead.
>
> A third, smaller one: the **Swift test suite writes into the real `events.jsonl`**. Its `fake` and `pass` engines emit `transcription.engine_failed`, so an unfiltered read of this log reports hundreds of transcription "failures" that are `FakeRunner.Boom` from `SinkDispatcherTests`. `--diar` filters to the real engine and prints what it skipped.

---

## A15: local summarize cold-start

**What:** the wall-clock cost of the first local (MLX) summary after a fresh start, which pays the model load, against a warm one that does not. The delta is the load cost.

**How:** `scripts/valid1_check.py --coldstart`

It refuses to run if something is already serving on the endpoint (a cold measurement against a warm server is a lie), picks a median-length transcript, and summarizes it twice: once with nothing running (a one-shot `mp summarize` spawns its own `mlx_lm.server` and tears it down on exit, so it reloads the model every time), then once against a `mp serve-local` it holds up alongside. It writes `<stem>.summary.candidate.*` and never touches a real summary. The run is wrapped in `caffeinate` and aborts if free memory drops under 10 percent, because the 14B at long context has OOM-hung this Mac before.

**Threshold:** a regression check against the previously recorded cold-start. **There was never a prior number to regress against**, which is the real reason this bar sat open; the Results table below now records one. Treat a later cold-start more than 10 percent above it as a regression.

**Caveat, stated rather than hidden:** the OS page cache means the second cold start of a model reads its safetensors from cache. This measures a warm-disk cold start, not a first-ever load.

## A16: quality and latency

**Closed in Q5, no action.** The engine-comparison run over 26 real meetings produced the quality read: see [`docs/local-llm-quality.md`](../local-llm-quality.md) and [`docs/engine-comparison.md`](../engine-comparison.md). Its actionable outcome (standardize the local backend on the 7B) shipped as LOCAL6. Summary quality is a human read by nature and does not become machine-checkable by wanting it to.

## DIAR1: diarization latency and error rate

Two legs, and they have very different fates.

### Latency: measured, passing

**How:** `scripts/valid1_check.py --diar`

Pairs `transcription.engine_started` / `engine_succeeded` on `file`. `engine_succeeded` carries `audio_seconds` and `segments`, so the real-time factor falls straight out.

**Threshold:** every run faster than real time. The original "no segment over 10 s" phrasing predates FluidAudio, which diarizes the whole file in one `performCompleteDiarization` call rather than streaming per segment, so there is no per-segment stage to time. Keeping up with real time is the meaningful restatement.

### Error rate: measured, 8.99%

**How:**

```bash
scripts/valid1_check.py --der                                  # lower bound, all corrected meetings
scripts/valid1_check.py --der --reviewed <stem> [<stem> ...]   # a real DER over meetings reviewed line by line
```

The speaker reassignments made in the Transcript tab are hand-made ground truth: reassigning a line means the diarizer put it on the wrong person. So mislabelled-speech / total-speech is a real measurement, and `<stem>.speaker_labels.json` accumulates it as a side effect of normal use rather than a labelling chore.

Two things deliberately do not count as errors, both filtered by comparing the **resolved person** rather than the raw label: a cluster rename (naming an unnamed voice is not fixing a wrong one), and a no-op override assigning a line to the person it already showed (the real data has these).

**`--reviewed` is what makes it a DER rather than a bound.** Without it, an untouched line is either correct or never looked at, and nothing on disk tells those apart, so the number is only a lower bound. Naming the meetings that were reviewed line by line makes the denominator honest: in those, an untouched line is *known* correct. No file can infer this, so it is an explicit input.

**Result (2026-07-16): DER = 8.99%** over 39.7 min across three meetings the owner reviewed end to end:

```
20260716-103024   49.0% misattributed  of   4.8 min
20260715-163053   13.6% misattributed  of   8.4 min
20260716-113206    0.3% misattributed  of  26.5 min
```

Reproduce with:

```bash
scripts/valid1_check.py --der --reviewed 20260715-163053 20260716-103024 20260716-113206
```

**This is the project's definition of DER** (mislabelled speech / total speech, i.e. speaker attribution over transcribed speech), the one the original bar asked for. It is *not* the academic NIST DER, which also charges missed speech and false alarms against a reference segmentation. Do not compare it to published DER numbers without that caveat.

**Read the spread, not the mean.** 0.3% / 13.6% / 49.0% is bimodal: two meetings were fine and one was a catastrophe. The 8.99% aggregate flatters it, and averaging is what would hide the real defect. The only reference point available is FluidAudio's published AMI SDM DER (13.89% at step 0.1), a different corpus and a different metric; the aggregate sits under it, but the 49% meeting does not, and that outlier is the thing worth fixing. It is tracked as DIAR2, not as a VALID1 remainder: VALID1's job was to produce the number, and DIAR2's is to move it.

### The failure mode the corrections exposed

`--der` also reports any raw cluster that had to be split across several real people. This found the thing that actually matters: in `20260716-103024`, `THEM-A` (named "Sudip") in fact held **five people** (Sudip, Anisha, Heorhii, Yash, Ayush). The diarizer merged the whole meeting into one voice and the user re-separated it by hand, which is why that meeting scores 49% while the spot-checked ones score under 1%. The user's own voice was inside the merge too: `label_me_speaker` pulled out only 3 segments and left 6 more buried in `THEM-A`. Tracked as DIAR2.

### A true DER still needs one exhaustive sample

The lower bound cannot become a real DER without a meeting labelled end to end. **The tempting shortcut does not work, and it is worth knowing why before reaching for it again.**

Recordings are stereo (mic-left, system-right), and FluidAudio provably diarizes a mono `(L+R)/2` downmix (`FluidAudioRunner.readMonoFloat32`), so the channel *looks* like an independent oracle for "me vs them". It is not: `diarize.label_me_speaker` already picks the "me" speaker **from the channel** (`_resolve_me_id` takes the channel-assigned mic speaker as its first precedence, and `identify_user_speaker` cross-tabulates against the channel verdict). Grading that label against the channel measures the channel against itself and returns a meaningless near-zero. The channel is also blind to the split that actually matters, since every remote speaker shares the system channel.

**The bounded path to a real DER**, if the number is ever wanted: pick 3 meetings, listen through them, and hand-label who spoke when among the remote speakers (`THEM-A` vs `THEM-B` vs ...). Grade the transcript's labels against that. It is roughly an hour of listening, and it is the only honest way there.

**The step-ratio question (FluidAudio step 0.1 vs 0.2) is answered without DER.** The published case for 0.2 was "~2x faster" (AMI SDM: DER 13.89 percent at 0.1 vs 15.07 percent at 0.2). At a **median 91x real time** there is no speed pressure whatsoever, so the accuracy-favouring 0.1 is free. Note the knob is not currently plumbed: `FluidAudioRunner.ensureDiarizer` constructs a bare `DiarizerManager()` with defaults. Plumbing it is a tuning task, not a validation one.

### Attribution coverage: the part that needs no ground truth

**How:** `scripts/valid1_check.py --attribution [--since <ISO8601>]`

How much speech the diarizer credited to **nobody** (`speaker_unknown`, or a raw `speaker_N` that never resolved) is true without any labels at all. It is not a DER and is not reported as one. There is no threshold; it is a baseline to watch.

Always pass `--since`. Attribution quality is not stationary: the pre-roster era drags the lifetime number up badly, so a lifetime read understates how well the current diarizer does.

## SUM1-APPLE: Apple Intelligence quality, latency, zero egress

**Quality and latency: closed in Q5** by the same engine-comparison run as A16 ([`docs/engine-comparison.md`](../engine-comparison.md)).

**Zero egress: WAIVED 2026-07-16 by owner decision. Not measured.** Stated plainly so no later reader mistakes this for a pass: nobody has watched the wire during an Apple Intelligence summary, so the zero-egress claim rests on argument, not evidence.

The argument is reasonable, which is why the waiver is reasonable. The Foundation Model runs on-device by construction; the daemon makes no outbound HTTP at all (that is a standing rule, see `daemon/CLAUDE.md`, and outbound calls live in the pipeline); and under regulated / NDA the pipeline's `egress_guard` clamps the process anyway. But an argument is not a measurement, and the original bar asked for a measurement.

Tracked as **EGRESS1 (P4)** in the backlog rather than kept as a VALID1 remainder. Promote it if the zero-egress claim ever becomes load-bearing (an NDA meeting whose confidentiality actually depends on it, or a claim made to someone else).

**Threshold if it is ever run:** arm Little Snitch, summarize a meeting with the backend set to Apple Intelligence (Preferences > Pipeline, or pin a workflow to it), and confirm zero non-loopback connections during summarization.

## UX4: live degraded banner on a real failed SCStream

**PASS (2026-07-15).** The owner forced a real capture failure by declining the screen-capture TCC prompt mid-recording; `events.jsonl` recorded one `recording.degraded` (`reason: The user declined TCCs for application, window, display capture`) and `scripts/valid1_check.py --ux4` exited 0. This was the one bar that could not be scripted here: the daemon emits the event correctly from `Coordinator.onSystemAudioDegraded`, but the failure has to be physically forced (revoke a TCC permission) and the HUD banner watched with human eyes.

**How:**
1. Start a recording.
2. Force a real SCStream failure: revoke Screen Recording (System Settings > Privacy & Security > Screen Recording), or stop the captured target.
3. Watch the HUD for the degraded banner. Restore the permission (the app needs a relaunch to pick it back up) and watch for recovery.
4. `scripts/valid1_check.py --ux4`.

**Threshold:** the banner appears within a second or two; `--ux4` exits 0 with at least one `recording.degraded` (and a `recording.recovered` after restore).

---

## Results

Measured 2026-07-14 on the owner's Mac (arm64, 32 GB, macOS 26.5.2).

| Bar | Date | Result | Measured | Notes |
|---|---|---|---|---|
| A15 cold-start | 2026-07-14 | **baseline set** | cold **39.8 s**, warm **31.4 s**, model load **8.4 s** | Qwen2.5-7B-Instruct-4bit, median-length transcript. No prior number existed to regress against; this is the baseline. Warm-disk cold start (see caveat). |
| A16 quality + latency | Q5 | **closed** | see [`engine-comparison.md`](../engine-comparison.md) | Closed by the 26-meeting engine-comparison run; outcome shipped as LOCAL6. |
| DIAR1 latency | 2026-07-14 | **PASS** | 132 runs, 47.7 h of audio, **0 failures**. Real-time factor min **5x**, median **91x**, max 130x. Longest run 82.8 s for 28.7 min of audio. | Every run faster than real time. Worst case 5.3x. |
| DIAR1 DER | 2026-07-16 | **MEASURED: 8.99%** | **8.99%** over 39.7 min, 3 meetings reviewed end to end: `20260716-103024` **49.0%** (4.8 min), `20260715-163053` 13.6% (8.4 min), `20260716-113206` 0.3% (26.5 min). | From the owner's own in-app corrections (`--der --reviewed <stems>`). The project's DER (mislabelled / total speech), not the academic NIST DER. **Read the spread, not the mean**: bimodal, and the 49% meeting (`THEM-A` held **5 people**) is the real defect, owned by DIAR2. Clears the only reference available (FluidAudio's published 13.89% on AMI SDM, a different corpus + metric). |
| DIAR1 attribution coverage | 2026-07-14 | **baseline set** | Post-roster (since 2026-06-01): **3.2 %** unattributed, 87.4 % named, 9.5 % unnamed remote cluster, over 79 meetings / 21.2 h. Lifetime: 14.0 % unattributed over 175 meetings / 40.4 h. | Not a DER. The lifetime number is dragged up by the pre-roster era (Apr-May: 25.9 %); the current diarizer is ~8x better than that. |
| SUM1-APPLE quality / 2x latency | Q5 | **closed** | see [`engine-comparison.md`](../engine-comparison.md) | |
| SUM1-APPLE zero-egress | 2026-07-16 | **WAIVED, not measured** | - | Owner decision: the on-device-by-construction argument was accepted in place of watching the wire. Not a pass, and recorded as such. Tracked as **EGRESS1 (P4)**; promote if the claim ever becomes load-bearing. |
| UX4 degraded banner + event | 2026-07-15 | **PASS** | 1 `recording.degraded` (reason: user declined the capture TCC prompt) | Owner forced a real capture-permission failure mid-recording; `scripts/valid1_check.py --ux4` exited 0. |
