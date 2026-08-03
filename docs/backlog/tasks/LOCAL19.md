# LOCAL19: the auto backend's local fallback ignores `local_memory_floor_pct`, which poisons LOCAL18's own experiment

Filed 2026-08-03 by the audit band. Found independently by the pipeline-contracts angle and the SOLID angle. Proposed high, downgraded to medium by an independent skeptic.

## What is wrong

There are four production constructions of `LocalSummaryClient`. Three thread the configured memory floor and one does not.

- `pipeline/src/mp/summarize.py:806-816` is `_AutoFallbackClient._local`, whose argument list ends without `memory_floor_pct`.
- `pipeline/src/mp/summarize_local.py:313` is `memory_floor_pct: float = resource_guard.DEFAULT_FLOOR_PCT,`, so the omission silently substitutes 10.0 (`resource_guard.py:62`) rather than failing.
- `pipeline/src/mp/summarize.py:745`, `pipeline/src/mp/engine.py:103` and `pipeline/src/mp/diarize_cleanup.py:413` all pass it.
- `pipeline/src/mp/summarize.py:750-751` shows this is the whole `auto` backend, not a corner of it.

The documentation side is worse than the code side. `pipeline/src/mp/diarize_cleanup.py:411-412` states the intent as a universal: "the configured floor, not the default, so turning the watchdog down (or off) means the same thing on **every local path**". `README.md:613` and `config.example.toml:195` both say `0` turns the watchdog off. None of that holds on `auto`.

CI5's dead-knob fence cannot see this, because the key is genuinely read at four other sites. This is the class of drift a set-comparison fence structurally cannot catch.

## Why this matters more than its severity suggests

**It poisons LOCAL18's own investigation.** LOCAL18's cheap first leg is "whether the abort path works at all, answerable safely today by raising the `summarization.local_memory_floor_pct` knob so any run trips it". Run that way on an `auto` backend, the watchdog still runs at 10 percent, nothing aborts, and the result reads as "the abort path does not work". That is a false negative on the one experiment LOCAL18 exists to run, and it would be written up as evidence about the watchdog when it is actually evidence about this constructor.

Anyone picking up LOCAL18 should land this first or pin their backend to `local` for the duration.

## Scope

Pass `memory_floor_pct=self._cfg.summarization.local_memory_floor_pct` at `summarize.py:806`, matching the other three sites.

Add a test that walks every production `LocalSummaryClient` construction and asserts each threads the configured floor, in the shape of `test_entry_contract.py`'s dispatch walk, so a fifth construction cannot forget. Note that `test_entry_contract.py`'s own walk is a substring test and CI6 covers strengthening it; this new test should assert on the constructor call rather than on source text.

Correct the ARCH5 spec's inventory, which records three constructions where there are four. Decide separately whether `dogfood.py`'s three constructions (`:106`, `:147`, `:154`) should honour the floor or stay on the default, since `MP_RAM_GUARD=0` is the documented bench escape.

## Acceptance

Suite green with new tests. A config with a non-default floor and `backend = "auto"` produces a fallback client carrying that floor. The new test fails against today's code. LOCAL18's spec gains a line naming this as a prerequisite for its first leg.
