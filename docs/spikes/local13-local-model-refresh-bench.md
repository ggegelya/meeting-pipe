# LOCAL13 bench: local model refresh (candidates vs the incumbent 7B)

Status: **harness prepared, runs and scoring owner-owed.** Thresholds below are pre-registered and were written before any score existed. Everything under [Results](#results) is deliberately empty; fill it in place.

The question: is `mlx-community/Qwen2.5-7B-Instruct-4bit` (a 2024-generation model, `pipeline/src/mp/config.py:128` and the owner's `~/.config/meeting-pipe/config.toml`) still the right local default, and does a newer 4-bit build in the 8B to 14B class beat it by enough to flip `summarization.local_model`? Cloud parity is explicitly not the target. The gap the task is aimed at is the 2026-07-23 side-by-side on stem `20260723-103118`, where the local pass produced topic-level bullets and a generic title while `claude-sonnet-4-6` produced named, checkable output.

Model class is the only lever this bench moves. No prompt changes, no pipeline-shape changes (that is LOCAL14), no LoRA (LOCAL9), no Apple Intelligence.

---

## 1. Pre-registered ship thresholds

Binding. A candidate flips `summarization.local_model` only if **every** bar clears on the 5-stem core set. Nothing here may be revised after a score is entered; if a bar turns out to be wrong, say so in the verdict and keep the incumbent, rather than moving the line.

**Q1. Action capture.** Candidate mean `actions_capture` >= incumbent mean **+ 0.05**, measured over the same 5 core stems.

**Q2. Decision capture.** Candidate mean `decisions_capture` >= incumbent mean **+ 0.05**, same stems.

**Q3. No per-meeting collapse.** On no single core stem is the candidate worse than the incumbent by more than **0.10** on either capture score. A good mean carrying one wrecked meeting is not a win.

**Q4. No hallucination regression.** Candidate mean `hallucination_rate` <= incumbent mean **+ 0.02**, and <= **0.05** absolute (the existing `dogfood.SHIP_GATE` ceiling).

**M1. Memory.** Peak server RSS <= **12 GB** across every core-stem run (this Mac has 32 GB; that leaves >= 60% headroom), and **zero watchdog aborts** on the core set. A candidate that trips the free-RAM watchdog once on a core stem is out, regardless of quality.

**L1. Latency ceiling.** Owner-chosen, and it must be written on this line **before the first candidate run**:

> Latency ceiling (owner, fill before scoring): `_______` seconds p50 on the anchor stem. Default if left blank at the time of the first candidate run: **2.0x the incumbent's measured p50 on `20260723-103118`**, from the latency leg in section 7 step 3.

**Tie-break**, if more than one candidate clears every bar: higher mean `decisions_capture` wins; if within 0.02, lower p50 latency wins; if still tied, lower peak RSS.

**Default outcome: keep the incumbent.** No candidate clearing all six bars is a legitimate and expected result, and it gets recorded with the reason, not retried with softer bars.

### What explicitly does not count as evidence for a flip

- Probe-leg results (arch loads, `response_format`, template quirks). Those are prerequisites and LOCAL14 input, not quality evidence.
- The anchor stem alone. `20260723-103118` motivated the task, so it is the stem most at risk of being read generously.
- "Reads better" without a filled scorecard.
- A candidate that only wins after a prompt tweak. That is LOCAL14, and mixing levers destroys attribution.

### Grading rules, also pre-registered

- **Fixed cloud reference.** `mp dogfood` re-runs the Anthropic baseline on every invocation, so each model's file carries a *different* cloud sample. Grade every model's capture scores against **the cloud column from the incumbent pass** (`local13-qwen2.5-7b/<stem>.dogfood.md`), not against the column sitting in the candidate's own file. Otherwise the reference moves under the comparison.
- **Score the core 5 first, then the stress stem.** The aggregate that decides the verdict is the 5-stem core. The stress stem is reported separately.
- **Known limitation, accepted:** this is not blinded. The runs directory names the model and the reviewer knows which is which. Blinding would need a harness change, which is out of scope here; note it as a bias the verdict has to live with, and prefer the numeric bars over impressions because of it.

---

## 2. What the session prepared vs what is owner-owed

Owner-owed by the spec, and not attempted here: the runs, the hand-scoring, and any model download. Each candidate is a multi-GB fetch, a long generation job on the daily-driver Mac, and a judgement call about output quality. `summarization.local_model` was **not** touched.

Prepared here (all read-only, no repo code changed):

- The pre-registered thresholds above.
- A candidate list **refreshed against the live HuggingFace API on 2026-07-24**, which corrects the filing-date list in two places (section 3).
- The fixed transcript set, chosen from the real 215-transcript corpus and **token-counted offline with the incumbent's own tokenizer**, so the 14B context guard is grounded in measured numbers rather than a rule of thumb (section 4).
- Static answers to two of the three probe legs, read out of the installed `mlx_lm` 0.31.3 source, so the owner's probe time goes to confirming rather than discovering (section 5). One of those answers is a surprise and matters to LOCAL14.
- The run protocol (`caffeinate`, free-RAM watchdog, incremental writes, warm-server hygiene) and the exact invocations (sections 6 and 7).

Environment as measured on 2026-07-24: `mlx-lm` **0.31.3**, `mlx` 0.31.2, venv Python 3.12; machine RAM **32 GB** (`hw.memsize` 34,359,738,368, 16 KiB pages); 505 GB free on the data volume; the HuggingFace cache is already 25 GB, and the only MLX chat models in it are Qwen2.5 3B / 7B / 14B, so **every candidate needs a fresh download**.

---

## 3. Candidates, refreshed at pickup

The spec's own instruction was to re-check the candidate space at pickup because it moves. It moved. Queried live against `https://huggingface.co/api/models` on 2026-07-24, and cross-checked against the architectures the installed `mlx-lm` 0.31.3 can actually load (a `model_type` loads only if `mlx_lm/models/<model_type>.py` exists; the loader imports it by name).

| # | Repo id | `model_type` | `mlx_lm` module present | HF downloads | HF lastModified | Class |
|---|---|---|---|---|---|---|
| 0 | `mlx-community/Qwen2.5-7B-Instruct-4bit` | `qwen2` | `qwen2.py` yes | (incumbent, cached) | - | 7B dense |
| 1 | `mlx-community/Qwen3.5-9B-4bit` | `qwen3_5` | `qwen3_5.py` yes | 24,849 | 2026-03-02 | 9B dense |
| 2 | `mlx-community/Qwen3-8B-4bit` | `qwen3` | `qwen3.py` yes | 31,853 | 2025-04-28 | 8B dense |
| 3 | `mlx-community/gemma-3-12b-it-qat-4bit` | `gemma3` | `gemma3.py` yes | 33,778 | 2025-04-21 | 12B dense, QAT |
| 4 | `mlx-community/Qwen3-14B-4bit` | `qwen3` | `qwen3.py` yes | 4,484 | 2025-04-29 | 14B dense |
| 5 | `mlx-community/phi-4-4bit` | `phi3` | `phi3.py` yes | 853 | 2025-01-12 | 14B dense |

Run order: 0 first (it sets the reference), then 1, 2, 3, then the 14B pair 4 and 5 last, because they are the memory-marginal ones and a watchdog abort late in the batch costs least.

On-disk size is **not** stated here on purpose. A 4-bit build runs roughly 0.55 to 0.6 GB per billion parameters, so expect about 5 GB for the 8-9B, 7 GB for the 12B and 8 to 9 GB for the 14B pair, roughly 33 GB for all five. The authoritative number is the `total_bytes` field in the first `started` event `mp prefetch-model` emits; record the real figure in the results table.

### Two corrections to the filing-date list, with evidence

**(a) The "Qwen3 8B and 14B instruct line (the 2507 refresh)" does not exist.** Searching `mlx-community/Qwen3-8B` and `mlx-community/Qwen3-14B` returns no `-Instruct-2507-` build at either size. The 2507-refresh repos that do exist on mlx-community are `Qwen3-4B-Instruct-2507-4bit` (below the target class) and `Qwen3-30B-A3B-Instruct-2507-4bit` (a MoE, excluded on memory below). So the dense 8B and 14B candidates are the **original hybrid-thinking Qwen3 builds**, not instruct-only refreshes. That is not a cosmetic difference: it promotes probe leg 3 (thinking-mode default) from a nicety to a prerequisite, because a hybrid model that emits reasoning text by default feeds prose into the 3-layer JSON extractor on every call.

**(b) A newer candidate exists that the filing list could not have named: `mlx-community/Qwen3.5-9B-4bit`**, created 2026-03-02, 24,849 downloads. It is two generations newer than the incumbent, sits exactly in the target class, and its architecture is supported by the installed `mlx-lm` (see leg 1). Treat it as the headline candidate rather than an also-ran. Two properties to know before running it: it is a **multimodal checkpoint** (`Qwen3_5ForConditionalGeneration`, HF pipeline tag `image-text-to-text`, repo carries `preprocessor_config.json` / `video_preprocessor_config.json`), and it ships a `chat_template.jinja`, so it is a chat model and not a base model despite the `base_model:Qwen/Qwen3.5-9B-Base` lineage tag.

### Excluded, with the reason recorded

- **`Qwen3.6-*` (27B, 35B-A3B, and the rest).** They exist on mlx-community as of today, but there is **no `qwen3_6.py` in the installed `mlx-lm` 0.31.3**, so the loader cannot resolve the arch. Running them means bumping `mlx-lm`, which is a dependency change and an owner gate. Out of scope for this bench; a legitimate reason to revisit later.
- **MoE builds (`Qwen3-30B-A3B-Instruct-2507-4bit`, `Qwen3.5-35B-A3B-4bit`, `Qwen3.5-122B-A10B-4bit`).** Resident size at 4-bit is roughly 17 to 20 GB and up. The 14B class already OOM-hung this Mac at long context (AI2), so a 30B-class resident set fails M1 before quality is even a question.
- **Non-4-bit and derivative builds** (8bit, 6bit, DWQ, AWQ, OptiQ, abliterated, distilled merges). The bench holds quantization fixed at 4-bit so the comparison is model class, not quantization scheme. DWQ / AWQ / OptiQ variants of a candidate that wins are a reasonable follow-up, not part of this run.

---

## 4. The fixed transcript set

Chosen from the owner's real corpus (215 transcripts under `~/Documents/Meetings/raw/`). Every stem below is a Teams-native meeting with `workflow_nda_mode: false`, which matters because **`mp dogfood` refuses a regulated or NDA meeting outright** (it would have to POST the transcript to Anthropic for the cloud baseline). Transcript path is `~/Documents/Meetings/raw/<stem>.md`.

Token counts measured offline with the **incumbent's own tokenizer** (`HF_HUB_OFFLINE=1`, tokenizer only, no weights loaded, nothing downloaded). `prompt` = system prompt + JSON schema + the composed user message. `peak` = that prompt plus the tokens in the summary the pipeline actually produced for that meeting.

| # | Stem | Lang | Chars | Minutes | Transcript tok | Prompt tok | Peak tok |
|---|---|---|---|---|---|---|---|
| 1 | `20260716-103024` | EN | 4,506 | 7.1 | 1,131 | 4,651 | 5,306 |
| 2 | `20260723-103118` | EN | 8,644 | 12.6 | 2,020 | 5,540 | 6,419 |
| 3 | `20260723-163108` | UK | 5,734 | 12.4 | 2,836 | 6,356 | 6,678 |
| 4 | `20260520-183044` | UK | 5,771 | 6.9 | 2,986 | 6,506 | 7,005 |
| 5 | `20260526-103149` | EN | 12,693 | 16.0 | 2,984 | 6,504 | 7,267 |
| S | `20260618-113150` | UK | 9,319 | 15.0 | 4,338 | 7,858 | 8,587 |

Stems 1 to 5 are the **core set**: 3 EN, 2 UK, 6.9 to 16.0 minutes, and every one stays under an 8K peak even against the corpus p90 output length (1,070 tokens), so every candidate including the 14B pair runs all five. Stem **S is the stress leg**: at roughly 8.9K peak against a p90 output it is the only one that crosses 8K, so the 8B to 12B candidates run it unconditionally and the 14B pair runs it **last** and may skip it if the watchdog has already fired. The verdict aggregate is the core 5 either way, so the comparison stays like-for-like.

Stem 2 is the anchor: it is the meeting the 2026-07-23 side-by-side used, so it is the one case where a prior cloud-vs-local read already exists.

### Three measured facts that shape the protocol

**The system prompt plus JSON schema is 3,520 tokens** (15,892 chars), and it is fixed on every call. On stems 1, 2 and 5 that preamble is **larger than the transcript**. The spec's framing that "a 12-minute meeting is ~2.5K tokens, well inside every candidate's window" is right about the transcript and understates the prompt: the anchor's full prompt is 5,540 tokens. Practical consequence: the "14B runs at 4-8K context only" guard is a real constraint even on short meetings, and the 4K end of that range is **unreachable for any real meeting** at the current prompt. The guard as applied here is the 8K end.

**Nothing in this corpus triggers the local map-reduce.** `summarize_local` windows a transcript only above `DEFAULT_MAP_REDUCE_ABOVE_CHARS` = 80,000 chars (matching `summarization.skip_above_chars` = 80,000 in the owner's config), and the longest transcript in the entire corpus is 72,890 chars. So every bench run is a **single call**, and the PIPE4 reduce path is not a confound in these numbers. It is also the reason not to reach for a longer stem to "cover" map-reduce: nothing real exercises it.

**Cyrillic costs about twice as many tokens per char.** Measured across the set: 0.22 to 0.25 tok/char for English, 0.47 to 0.49 for Ukrainian. That is why the UK stems are shorter in chars but comparable in prompt tokens, and it is why a UK stem is the stress leg.

---

## 5. Probe legs

Each is minutes, and the results are recorded here before the bench proper. Two of the three already have a static answer read out of the installed `mlx_lm` source; the owner's job on those is to confirm, not to discover.

### Leg 1: does the installed `mlx_lm` load each candidate arch at all?

Static answer, from `mlx_lm/models/` in the pipeline venv: `qwen3.py`, `qwen3_5.py`, `gemma3.py` (plus `gemma3_text.py`) and `phi3.py` are all present, so all five candidates resolve. There is **no** `qwen3_6.py`, which is what excludes the Qwen3.6 line.

The one worth actually testing is candidate 1. `Qwen3.5-9B-4bit` is a `ForConditionalGeneration` multimodal checkpoint, and text-only loading of one of those depends on the module handling a nested `text_config` and dropping the vision weights. `mlx_lm/models/qwen3_5.py` does exactly that: its `ModelArgs.from_dict` falls back to treating the whole config as `text_config` when the key is absent, builds a `TextModel` from `args.text_config`, and its weight sanitizer skips keys starting with `vision_tower` or `model.visual`. Same shape as `gemma3.py`, which is the precedent for candidate 3. So the expectation is that both load text-only. Confirm it rather than assume it.

Confirmation, per candidate, after the prefetch:

```sh
# one candidate at a time; ~1 to 2 minutes each once cached
MODEL=mlx-community/Qwen3.5-9B-4bit
mlx_lm.server --model "$MODEL" --host 127.0.0.1 --port 8799 &
sleep 20 && curl -s http://127.0.0.1:8799/v1/models | head -c 400 ; echo
kill %1
```

Port 8799 deliberately, not the configured 8765, so a probe never collides with a warm production server. Record: loads / fails, and the error text if it fails.

| Candidate | Loads on mlx-lm 0.31.3 | Notes |
|---|---|---|
| `Qwen3.5-9B-4bit` | | |
| `Qwen3-8B-4bit` | | |
| `gemma-3-12b-it-qat-4bit` | | |
| `Qwen3-14B-4bit` | | |
| `phi-4-4bit` | | |

### Leg 2: does the server honor the `response_format: json_schema` hint?

**Static answer, and it is a surprise: no, and not for any candidate.** `mlx-lm` 0.31.3's `server.py` never reads `response_format` at all. Grepping the installed file for `response_format`, `json_schema`, `schema`, `grammar`, `outlines` and `structured` returns nothing, and the request parser reads its body keys explicitly (`stream`, `model`, `adapters`, `max_completion_tokens`, `temperature`, `top_p`, `top_k`, `logit_bias`, `seed`, and so on), so an unrecognised key is silently dropped.

This is a **server property, not a model property**, which collapses the leg: it is one check for the whole bench, plus a re-check if `mlx-lm` is ever bumped. Two consequences worth carrying forward:

- Every candidate is decoded **unconstrained**, and the 3-layer extractor in `summarize_local.py` is doing all of the JSON-reliability work today. That makes JSON robustness a genuine part of what this bench measures rather than something the server guarantees. Log any parse-repair noise per candidate in the notes column.
- **LOCAL14 input:** constrained decoding is not available over this HTTP seam at the pinned version. If LOCAL14 wants it, that is an `mlx-lm` upgrade (dependency gate) or in-process loading, not a request field.

Related, and the more useful discovery for LOCAL14: the same server **does** parse `chat_template_kwargs` and passes it through to `apply_chat_template`. That is the supported lever for turning off Qwen3's thinking mode (`{"chat_template_kwargs": {"enable_thinking": false}}`). The pipeline sends no such field today.

Confirmation, one call, once any candidate is serving on 8799:

```sh
curl -s http://127.0.0.1:8799/v1/chat/completions -H 'content-type: application/json' -d '{
  "model":"x","max_tokens":64,"temperature":0.2,
  "messages":[{"role":"user","content":"Reply with a JSON object with key ok set to true."}],
  "response_format":{"type":"json_schema","json_schema":{"name":"t","strict":true,
    "schema":{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"]}}}
}' | head -c 600 ; echo
```

Prose around the object, or a shape the schema forbids, confirms the hint is ignored. Record the verdict once, not per candidate.

> Flag for the owner, not acted on here: the comment at `pipeline/src/mp/summarize_local.py:814-816` says "Newer mlx_lm.server builds honor this and constrain decoding via outlines under the hood; older builds ignore it." The build actually installed and pinned is newer and ignores it. The comment is not wrong about some hypothetical build, but it reads as reassurance that does not hold here. Correcting it is a code change and the spec reserved those, so it is left alone and named instead.

### Leg 3: tokenizer and chat-template quirks that break schema-as-text

The one that needs a real run per candidate, because it is a property of the shipped `chat_template.jinja`. What to look for in the first produced summary:

- **Thinking-mode prefixes.** Qwen3 (candidates 2 and 4) is a hybrid-thinking line whose template defaults to emitting reasoning. Check candidate 1 as well: the Qwen3.5 template was not inspected here and may carry the same default. Text before the JSON object lands in the 3-layer extractor, which will usually recover it and sometimes will not, and it costs output tokens either way. Note it; **do not fix it here.** The fix, if one is needed, is the `chat_template_kwargs` lever above, and per the spec that ships separately with its own test.
- **Fenced output.** A template that wraps output in a markdown fence exercises extractor layer 2 on every call.
- **Language drift.** The local path already replays once when the produced summary's language disagrees with the target (LOCAL7). A candidate that drifts to English on the UK stems will show up as a doubled latency on stems 3, 4 and S; check the log for the retry rather than reading it as slowness.

| Candidate | Thinking prefix | Fenced | Language retries (UK stems) | Notes |
|---|---|---|---|---|
| `Qwen3.5-9B-4bit` | | | | |
| `Qwen3-8B-4bit` | | | | |
| `gemma-3-12b-it-qat-4bit` | | | | |
| `Qwen3-14B-4bit` | | | | |
| `phi-4-4bit` | | | | |

---

## 6. Run protocol

Four things this bench can get silently wrong. All four have a cheap guard.

**(a) A warm server serves the wrong model, and every candidate scores like the incumbent.** `LocalSummaryClient` reuses any healthy server on the configured port. Since LOCAL11 it checks the served identity, but on a mismatch it only *restarts* a server it owns; the daemon's warm `mp serve-local` preloader is not ours to kill, so it **warns and proceeds with the wrong weights**. That warning goes to the log, not to the dogfood file, and the dogfood file records no model id. So:

- **Quit MeetingPipe.app before the bench** (or otherwise ensure nothing is preloading on 8765).
- `mp doctor` before each model. The green light is the line `nothing is serving on port 8765; the next local run starts its own server`. If it instead names a served model, stop and clear it.
- **Always tee the run log.** `run_one` logs `running local backend (<model id>)`, which is the only per-file attribution that exists, and the LOCAL11 mismatch warning appears in the same stream.
- After each model, grep its logs for `is configured for`. Two different warnings carry that phrase and they mean opposite things. `... it is not ours to restart, so the run sidecar will record what served` means the wrong weights answered and **that model's whole pass is void**. `... restarting it` is the healthy path: the client owned the stale server, killed it, and respawned the right one, so the pass stands.

**(b) Sleep eats the run.** Background work dies under clamshell sleep and a long generation can be cut across a dark-wake sliver. Every leg runs under `caffeinate -dims`, and **the lid stays open** (caffeinate does not prevent clamshell sleep).

**(c) Memory.** The 14B class OOM-hung this Mac before. Run the watchdog below in a second terminal for the whole bench. It kills the model server, not the harness, so the harness fails loudly with a recoverable machine rather than the machine swap-storming.

**(d) Buffered results.** Every invocation is one stem, writing one file and one log, so an abort keeps everything already completed. Do not wrap the set in a single long-running command whose output only lands at the end.

### Free-RAM watchdog

Second terminal, running for the whole bench. Arithmetic verified on this machine (it read 18% free while idle).

```sh
# LOCAL13 watchdog: kill the model server if free RAM drops below 10%.
PAGE=$(vm_stat | sed -n '1s/.*page size of \([0-9]*\).*/\1/p')
TOTAL=$(sysctl -n hw.memsize)
while :; do
  FREEISH=$(vm_stat | awk '/^Pages (free|inactive|speculative|purgeable)/ {gsub("[.]","",$NF); s+=$NF} END {print s}')
  PCT=$(( FREEISH * PAGE * 100 / TOTAL ))
  if [ "$PCT" -lt 10 ]; then
    echo "$(date +%H:%M:%S) free RAM ${PCT}% - killing mlx_lm.server" | tee -a ~/Documents/Meetings/dogfood/local13-watchdog.log
    pkill -f mlx_lm.server
  fi
  sleep 5
done
```

A kill counts as a **watchdog abort** against bar M1. Record which model and which stem in the results table; do not silently rerun it.

---

## 7. The invocations

All from the repo's `pipeline/` directory so `mp` resolves. `BENCH=~/Documents/Meetings/dogfood` throughout, matching the existing `runs` / `runs-v2` convention there.

### Step 0, once: fetch the candidates

Outside any NDA or regulated meeting. The egress guard's prefetch rule stands, and `mp prefetch-model` is the one command that deliberately does not arm the guard.

```sh
cd pipeline
for M in mlx-community/Qwen3.5-9B-4bit \
         mlx-community/Qwen3-8B-4bit \
         mlx-community/gemma-3-12b-it-qat-4bit \
         mlx-community/Qwen3-14B-4bit \
         mlx-community/phi-4-4bit ; do
  uv run mp prefetch-model "$M" | tee -a ~/Documents/Meetings/dogfood/local13-prefetch.log
done
```

Record each model's `total_bytes` from its `started` event in the results table. Roughly 33 GB total against 505 GB free, so disk is not a constraint; the cache grows from 25 GB to about 58 GB.

### Step 1: probe legs

Section 5. Do these before the bench proper, and drop any candidate that fails leg 1 rather than carrying an empty column through the whole run.

### Step 2, per model: quality (`mp dogfood`)

One invocation per stem, per model. Per-model runs directory, because `mp dogfood` writes `<stem>.dogfood.md` and a second model would otherwise **overwrite the first model's file**.

```sh
cd pipeline
BENCH=~/Documents/Meetings/dogfood
RAW=~/Documents/Meetings/raw
CORE="20260716-103024 20260723-103118 20260723-163108 20260520-183044 20260526-103149"
STRESS="20260618-113150"

# --- the incumbent first: it sets the fixed cloud reference every model is graded against
MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit ; SLUG=qwen2.5-7b
# --- then, one at a time:
#   MODEL=mlx-community/Qwen3.5-9B-4bit          SLUG=qwen3.5-9b
#   MODEL=mlx-community/Qwen3-8B-4bit            SLUG=qwen3-8b
#   MODEL=mlx-community/gemma-3-12b-it-qat-4bit  SLUG=gemma3-12b-qat
#   MODEL=mlx-community/Qwen3-14B-4bit           SLUG=qwen3-14b
#   MODEL=mlx-community/phi-4-4bit               SLUG=phi4-14b

uv run mp doctor | grep -i "port 8765"          # expect: nothing is serving on port 8765
mkdir -p "$BENCH/local13-$SLUG"
for S in $CORE $STRESS ; do                      # 14B pair: drop $STRESS if the watchdog has fired
  caffeinate -dims uv run mp dogfood "$RAW/$S.md" \
      --local-model "$MODEL" \
      --runs-dir "$BENCH/local13-$SLUG" \
      2>&1 | tee "$BENCH/local13-$SLUG/$S.run.log"
done
grep -l "not ours to restart" "$BENCH/local13-$SLUG"/*.run.log   # must print nothing; a hit voids this model's pass
pkill -f mlx_lm.server                           # clear the server before the next model
```

Then hand-score each `$BENCH/local13-$SLUG/<stem>.dogfood.md` front-matter (`actions_capture`, `decisions_capture`, `hallucination_rate`, `notes`), grading against the **incumbent pass's** cloud column per the pre-registered rule, and aggregate per model:

```sh
uv run mp dogfood --report \
    --runs-dir "$BENCH/local13-$SLUG" \
    --report-out "$BENCH/local13-$SLUG/report.md"
```

Per-model `--report-out` matters. The default is the *relative* path `docs/local-llm-quality.md`, so six models pointed at the default would each clobber the last, and a run started from the repo root would overwrite the committed `docs/local-llm-quality.md` instead of writing a bench artifact. Note the report's own SHIP / DO NOT SHIP line answers "is this model good enough in absolute terms" against the existing `SHIP_GATE`; it does **not** answer "does it beat the incumbent", which is what section 1's bars decide.

Cost note: `mp dogfood` re-runs the Anthropic baseline every time, so the full matrix is 6 models x 6 stems = **36 Sonnet calls**. Cheap in dollars, and unavoidable without a harness change, but it is also why the fixed-reference grading rule exists.

### Step 3, per model: latency and peak RSS (`local12_bench.py`)

`mp dogfood` records neither, so the LOCAL12 harness supplies both. It drives the same production path with the same prompt, keys peak-RSS sampling off the listening port, and prints each run's latency as it completes, so a tee'd log keeps the numbers even if a later run dies.

```sh
cd pipeline
BENCH=~/Documents/Meetings/dogfood
RAW=~/Documents/Meetings/raw
for S in 20260723-103118 20260526-103149 ; do    # anchor + the largest core stem
  caffeinate -dims uv run python ../docs/spikes/local12_bench.py \
      --transcript "$RAW/$S.md" \
      --model "$MODEL" --label "local13-$SLUG-$S" \
      --runs 3 --runs-dir "$BENCH/local13-$SLUG" \
      2>&1 | tee "$BENCH/local13-$SLUG/$S.bench.log"
done
```

Two stems, 3 runs each, is enough for a p50 and a peak-RSS read without turning the bench into an afternoon per model. Note the first run after a server launch pays a one-time model load and kernel compile (AI2 measured that as tens of seconds); `--runs 3` and the p50 is what absorbs it, so quote the p50, not the mean.

> Trip hazard: `local12_bench.py`'s docstring says `~/Documents/Meetings/raw/<stem>.transcript.md`. The real filename in this library is `<stem>.md`; `.transcript.md` does not exist. Use the paths above.

---

## Results

Everything below is empty by design. Fill in place; do not move a threshold.

### Probe legs

Leg 1 table and leg 3 table are in section 5. Leg 2 verdict (one line, whole bench):

> `response_format` honored by mlx-lm 0.31.3: `_______` (static read says no; confirmed / refuted on `______`)

### Per-model scorecards

One row per stem. Core rows decide the verdict; the stress row is reported, not aggregated.

**Incumbent, `mlx-community/Qwen2.5-7B-Instruct-4bit`** (the reference)

| Stem | actions_capture | decisions_capture | hallucination_rate | Notes |
|---|---|---|---|---|
| 20260716-103024 | | | | |
| 20260723-103118 | | | | |
| 20260723-163108 | | | | |
| 20260520-183044 | | | | |
| 20260526-103149 | | | | |
| **core mean** | | | | |
| 20260618-113150 (stress) | | | | |

**Candidate 1, `mlx-community/Qwen3.5-9B-4bit`**

| Stem | actions_capture | decisions_capture | hallucination_rate | Notes |
|---|---|---|---|---|
| 20260716-103024 | | | | |
| 20260723-103118 | | | | |
| 20260723-163108 | | | | |
| 20260520-183044 | | | | |
| 20260526-103149 | | | | |
| **core mean** | | | | |
| 20260618-113150 (stress) | | | | |

**Candidate 2, `mlx-community/Qwen3-8B-4bit`**

| Stem | actions_capture | decisions_capture | hallucination_rate | Notes |
|---|---|---|---|---|
| 20260716-103024 | | | | |
| 20260723-103118 | | | | |
| 20260723-163108 | | | | |
| 20260520-183044 | | | | |
| 20260526-103149 | | | | |
| **core mean** | | | | |
| 20260618-113150 (stress) | | | | |

**Candidate 3, `mlx-community/gemma-3-12b-it-qat-4bit`**

| Stem | actions_capture | decisions_capture | hallucination_rate | Notes |
|---|---|---|---|---|
| 20260716-103024 | | | | |
| 20260723-103118 | | | | |
| 20260723-163108 | | | | |
| 20260520-183044 | | | | |
| 20260526-103149 | | | | |
| **core mean** | | | | |
| 20260618-113150 (stress) | | | | |

**Candidate 4, `mlx-community/Qwen3-14B-4bit`**

| Stem | actions_capture | decisions_capture | hallucination_rate | Notes |
|---|---|---|---|---|
| 20260716-103024 | | | | |
| 20260723-103118 | | | | |
| 20260723-163108 | | | | |
| 20260520-183044 | | | | |
| 20260526-103149 | | | | |
| **core mean** | | | | |
| 20260618-113150 (stress, optional) | | | | |

**Candidate 5, `mlx-community/phi-4-4bit`**

| Stem | actions_capture | decisions_capture | hallucination_rate | Notes |
|---|---|---|---|---|
| 20260716-103024 | | | | |
| 20260723-103118 | | | | |
| 20260723-163108 | | | | |
| 20260520-183044 | | | | |
| 20260526-103149 | | | | |
| **core mean** | | | | |
| 20260618-113150 (stress, optional) | | | | |

### Latency and peak RSS

p50 over 3 runs per stem. Peak RSS is the LOCAL12 sampler's figure for whatever is listening on 8765.

| Model | Download (GB) | p50 s, anchor `20260723-103118` | p50 s, `20260526-103149` | Peak RSS (GB) | Watchdog aborts |
|---|---|---|---|---|---|
| Qwen2.5-7B-Instruct-4bit (incumbent) | cached | | | | |
| Qwen3.5-9B-4bit | | | | | |
| Qwen3-8B-4bit | | | | | |
| gemma-3-12b-it-qat-4bit | | | | | |
| Qwen3-14B-4bit | | | | | |
| phi-4-4bit | | | | | |

### Verdict

> Named verdict here, against the six bars in section 1, one line per bar per surviving candidate. "Keep the incumbent" is a verdict and needs the same accounting.

On a flip: set `summarization.local_model` in `~/.config/meeting-pipe/config.toml`, then verify with `mp doctor` (it reports `summarization.local_model` and whether the listening server matches it) and confirm `mp prefetch-model <new repo id>` short-circuits as already cached. On a keep: record the reason here so the next refresh starts from the finding instead of the question.

---

## What LOCAL14 should carry out of this

1. **Constrained decoding is not available over the current seam.** mlx-lm 0.31.3's server ignores `response_format` entirely, so the 3-layer extractor is load-bearing, not a belt-and-braces defence. Getting real JSON constraints means an `mlx-lm` bump or in-process loading, both of which are decisions rather than parameters.
2. **`chat_template_kwargs` is honored** and unused by the pipeline. That is the supported way to switch off Qwen3-family thinking mode.
3. **The fixed prompt overhead is 3,520 tokens**, which exceeds the transcript on a typical stand-up. Any staged-pipeline design that multiplies the number of calls multiplies that preamble too, so per-stage prompt size is a first-order cost, not a rounding error.
4. **Nothing in the real corpus reaches the 80,000-char map-reduce threshold** (longest transcript 72,890 chars), so the PIPE4 reduce path that LOCAL14 plans to replace is, on this library, dead code in practice. Worth confirming before designing around it. *(Carried out 2026-07-28: LOCAL14 dropped that path from its motivation rather than designing around it, and corrected the claim in its own spec. The staged pipeline still subsumes the reduce path, but as a consequence, not a justification.)*
5. **Cyrillic costs about 2x the tokens per char** of English here (0.47 to 0.49 against 0.22 to 0.25), so a token budget calibrated on English stems is roughly half as generous on UK meetings.
