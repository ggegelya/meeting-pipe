# LOCAL18: Nobody has seen the free-RAM watchdog fire, and its floor may be unreachable

Band origin: split out of LOCAL16 on 2026-07-31 by owner decision, following the VALID1 to EGRESS1 precedent (a leg that was not measured is split out rather than dressed up as a pass). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

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
