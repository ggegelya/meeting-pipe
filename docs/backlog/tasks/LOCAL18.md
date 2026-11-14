---
id: LOCAL18
title: Nobody has seen the free-RAM watchdog fire, and its floor may be unreachable
category: Local models
status: new
priority: P2
comment: Split out of LOCAL16 on 2026-07-31 by owner decision, on the VALID1-to-EGRESS1 precedent that an unmeasured leg is split rather than dressed up as a pass. LOCAL16's **tier refusal is verified** (Preferences annotations, `mp doctor`, and the refusal copy all confirmed by the owner that day) and it is the protection that would have stopped the documented 14B-on-32GB incident. The **runtime watchdog is not**: it has never fired in the entire event-log history, and an attempt to make it fire failed, with `memory_pressure -p 8 -y 45` reporting "Run out of allocable memory" while still at 65% by its own reckoning and the summarize completing normally. The doubt is about the metric rather than the code: `free_pct` sums `free`, `inactive`, `speculative` and `purgeable` (`resource_guard.py:309`) for a documented and sound reason (macOS keeps `Pages free` near zero, so a floor on free alone would fire constantly), but `inactive` and `purgeable` are what macOS reclaims **under** pressure, so the sum stays high exactly while the machine copes by compressing and swapping; during the test `vm_stat` showed 10.1M swapouts and ~7.5 GB in the compressor while the metric read 65% free. Scope splits in two: whether the abort path works at all, answerable safely today by raising the `summarization.local_memory_floor_pct` knob so any run trips it; and whether 10% is reachable, which needs an instrumented heavy run rather than synthetic allocation. Owner may re-band: this is the backstop under a P1's "never hangs the machine" promise, and P2 assumes the verified tier refusal carries the known case. Amended 2026-11-13 by the audit band: the 4,000-token tier ceilings sit below the 4,004 to 4,101-token fixed prompt, so 7B on 16 GB and 14B on 24 GB get the native 28,768 budget, and the watchdog samples only before a request (F079).
---

# LOCAL18: Nobody has seen the free-RAM watchdog fire, and its floor may be unreachable

Band origin: split out of LOCAL16 on 2026-07-31 by owner decision, following the VALID1 to EGRESS1 precedent (a leg that was not measured is split out rather than dressed up as a pass). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

LOCAL16 shipped two protections and they are not equally proven.

**The tier refusal is verified.** It refuses at spawn time on total physical RAM, and it is the protection that would have stopped the documented incident (a 14B model loading on a 32 GB Mac). The owner confirmed it on 2026-07-31 from three sides: the Preferences presets annotate against this machine, `mp doctor` reports the tier honestly ("32 GB RAM admits a model up to ~9 GB (~8000 tokens per request)", "free memory now: 38%"), and the refusal message for an over-tier model on a pretend 16 GB Mac reads correctly.

**The free-RAM watchdog has never been observed to fire, and an attempt to make it fire failed.** On 2026-07-31 the owner started a local summarize and ran `memory_pressure -p 8 -y 45` against it. The tool reported "System-wide memory free percentage: 65%", tried to allocate down to 8%, and gave up with "Run out of allocable memory". The summarize completed normally. A grep of the entire event-log history (`events.jsonl` plus the 63 MB `events.1.jsonl` and `pipeline_events.jsonl`) finds no memory-guard event of any kind, ever.

**The doubt this raises is about the metric, not the code.** `MemoryWatchdog.check` compares `sample.free_pct` against a 10% floor, and `free_pct` is computed over four `vm_stat` buckets (`resource_guard.py:309-315`):

```python
_VM_STAT_FREE_BUCKETS = ("free", "inactive", "speculative", "purgeable")
```

The comment gives a sound reason for not measuring `free` alone: "macOS keeps `Pages free` near zero by design (it caches aggressively), so a floor measured against free alone would fire constantly on a healthy machine and teach the user to ignore it." That reasoning is right. The problem is the other end of it. `inactive` and `purgeable` are exactly the pages macOS reclaims *under* pressure, so the sum stays high precisely while the machine is coping by compressing and swapping. During the owner's test `vm_stat` reported 10.1M swapouts and roughly 7.5 GB resident in the compressor while the metric still read 65% free.

So a floor of 10% measured this way may be unreachable in practice, which would mean the runtime backstop does not engage in the situation it exists for. That is a hypothesis with evidence, not a conclusion, and the whole point of this task is to settle it rather than assume either way.

## Scope, in two separable questions

The two are worth keeping apart, because the first is cheap and safe and the second is neither.

**1. Does the abort path work at all?** This is answerable today without stressing the machine, because the floor is a config knob: `summarization.local_memory_floor_pct` (default 10.0, `config.py:146`). Set it high enough that any run trips it immediately, start a local summarize, and observe the whole chain end to end: the watchdog aborts, the message carries the marker phrase, the Library row goes to Failed with the reason visible, `mlx_lm.server` is reaped rather than orphaned (`LocalServerReaper`), and the guard event is emitted. If that chain works, the mechanism is sound and only the threshold is in question, which is a much smaller problem than it looks today.

**Prerequisite for this leg, and it has landed: LOCAL19 (2026-08-15).** Raising the knob only trips a run if the client actually reads it, and `_AutoFallbackClient._local` did not: on `backend = "auto"` the local rung built its client without `memory_floor_pct`, so the watchdog ran at `resource_guard.DEFAULT_FLOOR_PCT` no matter what the config said. Run this leg on `auto` before that fix and nothing aborts, which reads as "the abort path does not work" while actually being evidence about a constructor. That is now fixed at every construction and fenced by `test_local_client_contract.py`, so the leg is safe to run on whichever backend the owner has configured. On a checkout without LOCAL19, pin the backend to `local` for the duration instead.

**2. Is 10% reachable, and is the metric the right one?** This needs measurement rather than argument. Instrument a genuinely heavy run and record the four buckets alongside swap and compressor figures over its lifetime, so the question becomes what the numbers do when the machine is actually in trouble rather than what they do under synthetic allocation. `memory_pressure` is a poor instrument here, as 2026-07-31 showed: it competes for the same pages and gives up before the target. The honest heavy load is the one from the incident record, a large model at long context, which is also the thing that took the Mac down, so it needs the answer to question 1 in hand first.

If the measurement says the four-bucket sum stays high while the machine thrashes, the metric changes. Candidates to weigh rather than assume: excluding `inactive`, incorporating swap or compressor pressure, or reading the OS memory-pressure level as a second signal alongside the bucket sum. Whatever is chosen, keep the property the current comment protects, that it must not fire on a healthy machine.

## Explicitly not / out of scope

**Not the tier refusal.** Verified working on 2026-07-31 and unchanged by this task. It is the primary protection and this one is the backstop.

**Not loosening anything.** If the floor turns out unreachable, the answer is a metric that reflects real pressure, never a lower bar that fires on a healthy Mac.

**Not `memory_pressure -S`.** LOCAL16's walkthrough originally suggested it and it cannot work here: it simulates the system's pressure level without applying real pressure, while the watchdog reads `vm_stat`. Corrected in that spec on 2026-07-31; recorded here so it is not re-proposed.

**Not AI11's index memory work.** That shipped and was owner-verified responsive on 2026-07-31 over 227 meetings; this is about the summarize path's runtime guard.

## Acceptance

Question 1 answered with an observation, not an argument: with the floor temporarily raised, a local summarize aborts through the watchdog, the Library row shows the reason, no `mlx_lm.server` is left running, and the guard event appears in the log. The floor is returned to its configured value afterwards, and the walkthrough says so explicitly so a raised floor cannot be left behind.

Question 2 answered with numbers: a recorded trace of the four buckets plus swap and compressor figures across a heavy run, written into a spike doc, with a verdict stating whether 10% is reachable. If it is not, the metric change lands with tests pinning both directions (fires when genuinely starved, silent on a healthy machine), and the Swift mirror `LocalModelTier` stays in agreement.

`cd pipeline && uv run --extra dev ruff check src tests`, `pyright`, and `pytest -q` green. `python3 scripts/truth_fences.py both` green. No em-dashes in changed lines.

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule. Steps are tagged [owner] / [session] by who acts. Question 1 is safe; question 2 is not, so they are deliberately separated and the owner should not be asked to do the second on a working day.

1. [session] Raise `summarization.local_memory_floor_pct` in the owner's config to a value any run trips (for example 90), and say plainly that it has been raised and will be restored.
2. [owner] Library, any short meeting, Re-summarize with Local MLX. Pass: it stops almost immediately, the row reads Failed with a reason naming memory, and the reason is legible without opening a log. **The Mac stays responsive**, which it should, since nothing was actually starved.
3. [session] Confirm from the log that the guard event fired and that no `mlx_lm.server` process survives.
4. [session] Restore the floor to its previous value and confirm the file reads what it read before step 1.
5. [owner] Question 2 needs a heavy run that could make the machine unpleasant for a few minutes, so pick a moment when nothing else matters and **save your work first**. [session] will instrument and record; the owner's only job is to say whether the Mac stayed usable.
6. [owner] Say "LOCAL18 good to close" (or what is wrong); [session] moves the row and the spec into `q6-final.md` and deletes this file.

## Amendment 2026-11-13 (audit band)

From the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md) F079 ("Per-Mac context ceiling is unreachable for the tiers it targets; watchdog cannot see inside a request", medium, listed as a known, accepted trade-off of [LOCAL23](./LOCAL23.md), done, and of LOCAL16's design). Recorded here because this task already asks whether the watchdog fires, and F079 shows the cases where it is the only protection left. Re-run at HEAD (`3a2da4fc`) before filing.

**The 4,000-token tier ceilings cannot be met.** With the stock prompt and an empty team context, `request_tokens(self._messages_for(system_prompt, "", target))`, the fixed part of every request, estimates at 4,004 tokens with no language target, 4,088 for `en` and 4,101 for `uk`. The 16 GB and 24 GB tiers carry `context_token_ceiling=4_000`, so `request_budget` takes its last branch and returns the native `NATIVE_CONTEXT_TOKENS - max(0, max_tokens)`, 32,768 minus the default 4,000, so 28,768, with LOCAL23's warning ("no window can honour that ceiling; using the model's native budget ... and relying on the memory watchdog"). Enumerated over the three presets and 8, 16, 24, 32 and 48 GB: the tight pairs are 7B on 16 GB, 14B on 24 GB and 14B on 32 GB, and the ceiling binds only on the last (8,000). One pair in 15; the two smallest-RAM tight pairs, the population `resource_guard` names as having produced the OOM reports, get the native budget.

**The watchdog it relies on samples only between requests.** `LocalSummaryClient._chat_completion` calls `self.watchdog.check(stage="local summarize")` once before each request ("Checked BEFORE the request"), and `MemoryWatchdog.check` is further throttled by `min_interval_sec` (2.0). Nothing samples while a request is in flight, which is when prefill of a long request grows memory. The audit's scenario: a 24 GB Mac on the Large (14B) preset with a 60-minute English meeting of about 60K chars sends one request of about 19K tokens, above the 16K at which `resource_guard`'s tier notes record an OOM for the 14B on a 32 GB Mac ("fine at 4K tokens, watchdog abort at 8K, OOM at 16K"), and nothing can abort it once sent. Field: the [field evidence](../../audits/2026-11-13-field-evidence.md) saw no local backend in its window, so this is code-derived, not observed.

So even if question 2 settles the metric, a pre-request check cannot stop a request that starts above the floor and crosses it mid-prefill.

Added scope:

3. (F079, budget) In `request_budget`, when a tight tier's ceiling cannot be honoured, return the smallest feasible budget (`smallest`, the fixed prompt plus one `_MIN_MAP_WINDOW_CHARS` window) instead of `native`, and reword the warning. This trades speed for headroom: at about 4,380 tokens a 60K-char meeting becomes roughly 40 map windows. Measure that run on one tight pair and record the window count and wall time in the commit body; if it is impractical, the fallback is a fixed intermediate (the 32 GB tier's 8,000), stated as such. A shorter fixed prompt for tight tiers is the other lever the audit names; it changes summary behaviour and is not taken here. `LocalModelTier`, the Swift mirror, is checked for agreement.
4. (F079, in-flight sampling) While a local request is in flight, sample memory from a timer thread through the same `MemoryWatchdog` and floor; on a breach, abort the request through the existing kill path when the client owns the server (so the run fails with the watchdog's marker phrase), and log the breach without killing when it does not (the daemon's warm server, which [LOCAL21](./LOCAL21.md)'s single owner will take over). The thread stops on success, failure and cancel.

Added acceptance:

- pytest on `request_budget`: a tight tier whose ceiling is below the fixed prompt gets the smallest feasible budget (or the chosen intermediate), not 28,768; a model that fits, and `guard_enabled=False`, still get native; the 14B on 32 GB still gets 8,000.
- pytest with the fake `mlx_lm.server` holding a request open and an injected sampler that drops below the floor mid-request: the client aborts within one sample interval with the watchdog's message, and no sampler thread survives the call on success, failure or abort.
- Question 2's trace also records when an in-flight sample would have tripped compared with the next pre-request check.
- `cd pipeline && uv run --extra dev ruff check src tests`, pyright and `pytest -q` green, with the number of new tests in the commit body.
