"""LOCAL16: the memory policy and the free-RAM watchdog.

The tier table is pure, so it is tested as a table: every machine size the
owner is likely to meet against every curated preset. The watchdog is tested
with an injected sampler, because the thing it guards against (a machine
swap-storming) is not something a test suite gets to reproduce.

These rows are mirrored by `LocalModelTierTests` on the Swift side. The two
policies have to agree, and there is no shared constant across the language
boundary, so a one-sided edit is meant to fail one of the two suites.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from mp import events, resource_guard
from mp.resource_guard import (
    LOW_MEMORY_MARKER,
    Assessment,
    LowMemoryError,
    MemorySample,
    MemoryWatchdog,
    ModelTooLargeError,
    assess,
    estimate_model_gb,
    guard_enabled,
    largest_preset_within,
    parse_vm_stat,
    refusal_message,
    require_model_fits,
    tier_for,
)


@pytest.fixture(autouse=True)
def _guard_on(monkeypatch):
    """The suite pins `MP_RAM_GUARD=0` (conftest) so no unrelated test reads the
    real machine. This file is the one that tests the guard, so it turns it back
    on; every case here passes an explicit `ram_gb` rather than measuring."""
    monkeypatch.delenv(resource_guard.OVERRIDE_ENV, raising=False)


SMALL = "mlx-community/Qwen2.5-3B-Instruct-4bit"
RECOMMENDED = "mlx-community/Qwen2.5-7B-Instruct-4bit"
LARGE = "mlx-community/Qwen2.5-14B-Instruct-4bit"
CUSTOM = "mlx-community/some-instruct-4bit"


# ---------- model size estimate (promoted out of doctor) --------------------


@pytest.mark.parametrize("model_id,expected", [
    (SMALL, 1.9),
    (RECOMMENDED, 4.3),
    (LARGE, 8.7),
    ("mlx-community/Qwen2.5-32B-Instruct-4bit", 19.8),
    ("mlx-community/gemma-2-9b-it-4bit", 5.6),
])
def test_estimate_model_gb_parses_param_count(model_id: str, expected: float) -> None:
    assert estimate_model_gb(model_id) == expected


def test_estimate_model_gb_ignores_the_quant_suffix() -> None:
    # "4bit" must not be read as a 4B parameter count.
    assert estimate_model_gb(CUSTOM) is None


# ---------- the pure tier policy -------------------------------------------


@pytest.mark.parametrize("model_id,ram_gb,expected", [
    # 16 GB: the 7B is the shipped default and runs, but with little headroom;
    # the 14B is the one LOCAL6 recorded as "can OOM on 16 GB".
    (SMALL, 16.0, "fits"),
    (RECOMMENDED, 16.0, "tight"),
    (LARGE, 16.0, "over"),
    # 24 GB: the tier the 14B's shipped copy has always named as its floor.
    (SMALL, 24.0, "fits"),
    (RECOMMENDED, 24.0, "fits"),
    (LARGE, 24.0, "tight"),
    # 32 GB, the owner's Mac. The 14B runs here and has still OOM-hung it at
    # long context, so "tight" is the honest answer, not "comfortable".
    (SMALL, 32.0, "fits"),
    (RECOMMENDED, 32.0, "fits"),
    (LARGE, 32.0, "tight"),
    # 48 GB: the first tier where the 14B is genuinely roomy.
    (LARGE, 48.0, "fits"),
    # A model id with no parameter count is never refused on size.
    (CUSTOM, 16.0, "unknown"),
    (CUSTOM, 8.0, "unknown"),
])
def test_tier_table(model_id: str, ram_gb: float, expected: str) -> None:
    assert assess(model_id, ram_gb).fit == expected


def test_tier_ceilings_rise_with_the_machine() -> None:
    # The context ceiling is the second half of the policy (AI11 clamps its
    # answer budget to it). Monotonic, so a bigger Mac is never told to think
    # in smaller chunks than a smaller one.
    ceilings = [tier_for(ram).context_token_ceiling for ram in (8, 16, 24, 32, 48, 128)]
    assert ceilings == sorted(ceilings)
    assert tier_for(32.0).context_token_ceiling == 8_000


def test_a_machine_below_the_first_tier_still_gets_a_policy() -> None:
    # There is nothing smaller to offer a 4 GB Mac; it gets the smallest tier
    # and the watchdog underneath, rather than an index error.
    assert tier_for(4.0) is resource_guard.TIERS[0]


def test_assess_reports_the_ram_a_refused_model_wants() -> None:
    a = assess(LARGE, 16.0)
    assert a.fit == "over"
    assert a.wants_ram_gb == 24.0
    assert a.model_gb == 8.7


# ---------- the refusal message --------------------------------------------


def test_refusal_names_the_machine_the_model_and_the_alternative() -> None:
    message = refusal_message(assess(LARGE, 16.0))
    assert LOW_MEMORY_MARKER in message          # the marker Swift stamps as stage=memory
    assert "16 GB" in message                    # this Mac
    assert "24 GB" in message                    # what the model wants
    assert "Large (Qwen 14B-4bit)" in message    # what was configured
    assert "Recommended (Qwen 7B-4bit)" in message  # where to go instead
    assert "Preferences > Pipeline" in message


def test_refusal_does_not_advertise_the_override() -> None:
    # This text becomes the Library row's failure reason. "Here is how to turn
    # the safety off" is not advice to put in front of someone whose Mac has
    # already been taken down twice.
    assert resource_guard.OVERRIDE_ENV not in refusal_message(assess(LARGE, 16.0))


def test_largest_preset_within_walks_down_with_the_machine() -> None:
    assert largest_preset_within(48.0) == "Large (Qwen 14B-4bit)"
    assert largest_preset_within(24.0) == "Large (Qwen 14B-4bit)"
    assert largest_preset_within(16.0) == "Recommended (Qwen 7B-4bit)"
    assert largest_preset_within(8.0) == "Small (Qwen 3B-4bit)"


# ---------- require_model_fits ---------------------------------------------


def test_require_model_fits_raises_for_an_over_tier_model() -> None:
    with pytest.raises(ModelTooLargeError) as excinfo:
        require_model_fits(LARGE, ram_gb=16.0)
    assert "Recommended (Qwen 7B-4bit)" in str(excinfo.value)


def test_require_model_fits_passes_a_model_within_tier() -> None:
    require_model_fits(RECOMMENDED, ram_gb=32.0)


def test_require_model_fits_fails_open_on_an_unknown_size() -> None:
    # The Custom preset is the user's one escape hatch; refusing every id we
    # cannot parse would close it.
    require_model_fits(CUSTOM, ram_gb=8.0)


def test_require_model_fits_fails_open_when_ram_is_unreadable(monkeypatch) -> None:
    monkeypatch.setattr(resource_guard, "physical_ram_gb", lambda: None)
    require_model_fits(LARGE)


def test_override_env_bypasses_the_refusal(monkeypatch) -> None:
    # Owner-dev only: LOCAL13's bench measures the boundary this guard exists to
    # keep runs away from, so it has to be able to cross it.
    monkeypatch.setenv(resource_guard.OVERRIDE_ENV, "0")
    assert guard_enabled() is False
    require_model_fits(LARGE, ram_gb=16.0)


def test_unset_override_means_the_guard_is_on(monkeypatch) -> None:
    monkeypatch.delenv(resource_guard.OVERRIDE_ENV, raising=False)
    assert guard_enabled() is True


# ---------- the free-RAM sampler -------------------------------------------


_VM_STAT = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                1000.
Pages active:                            300000.
Pages inactive:                            2000.
Pages speculative:                          500.
Pages throttled:                              0.
Pages wired down:                        100000.
Pages purgeable:                            500.
"""


def test_parse_vm_stat_sums_the_available_buckets() -> None:
    # free + inactive + speculative + purgeable = 4000 pages of 16 KiB, against
    # a total set to exactly ten times that, so the percentage is checkable.
    sample = parse_vm_stat(_VM_STAT, total_bytes=4000 * 16384 * 10)
    assert sample is not None
    assert sample.free_bytes == 4000 * 16384
    assert sample.free_pct == pytest.approx(10.0)


def test_parse_vm_stat_ignores_the_buckets_that_are_not_available() -> None:
    # `active` and `wired down` are the bulk of the numbers above; counting
    # them would report a machine as roomy right up to the moment it swaps.
    sample = parse_vm_stat(_VM_STAT, total_bytes=4000 * 16384 * 10)
    assert sample is not None
    assert sample.free_bytes < 300000 * 16384


def test_parse_vm_stat_returns_none_for_unparseable_output() -> None:
    assert parse_vm_stat("not vm_stat output", total_bytes=1) is None


# ---------- the watchdog ----------------------------------------------------


def _sample(free_pct: float) -> MemorySample:
    total = 32 * 1024 ** 3
    return MemorySample(free_bytes=int(total * free_pct / 100), total_bytes=total)


def test_watchdog_passes_above_the_floor() -> None:
    w = MemoryWatchdog(floor_pct=10.0, sampler=lambda: _sample(18.0))
    assert w.check(stage="local summarize") is not None


def test_watchdog_aborts_below_the_floor() -> None:
    w = MemoryWatchdog(floor_pct=10.0, sampler=lambda: _sample(7.0))
    with pytest.raises(LowMemoryError) as excinfo:
        w.check(stage="local summarize")
    message = str(excinfo.value)
    assert LOW_MEMORY_MARKER in message      # so the Library row says memory
    assert "7%" in message                   # what it measured
    assert "local summarize" in message      # where it was


def test_watchdog_abort_emits_a_pipeline_event(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("MEETINGPIPE_LOGS_DIR", str(tmp_path))
    w = MemoryWatchdog(floor_pct=10.0, sampler=lambda: _sample(3.0))
    with pytest.raises(LowMemoryError):
        w.check(stage="embed")
    rows = [
        json.loads(line)
        for line in (tmp_path / "pipeline_events.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    aborted = [r for r in rows if r["action"] == "memory_guard_aborted"]
    assert len(aborted) == 1
    assert aborted[0]["category"] == "pipeline"
    assert aborted[0]["stage"] == "embed"
    assert aborted[0]["free_pct"] == 3.0


def test_watchdog_throttles_its_sampling() -> None:
    # The embed path calls this between batches; a `vm_stat` per batch would be
    # a cost the guard imposes on every healthy run.
    calls = {"n": 0}
    now = {"t": 0.0}

    def sampler() -> MemorySample:
        calls["n"] += 1
        return _sample(50.0)

    w = MemoryWatchdog(
        floor_pct=10.0, sampler=sampler, min_interval_sec=2.0, clock=lambda: now["t"]
    )
    for _ in range(10):
        w.check(stage="embed")
    assert calls["n"] == 1
    now["t"] = 2.5
    w.check(stage="embed")
    assert calls["n"] == 2


def test_watchdog_is_off_when_the_floor_is_zero() -> None:
    w = MemoryWatchdog(floor_pct=0.0, sampler=lambda: _sample(1.0))
    assert w.enabled is False
    assert w.check(stage="local summarize") is None


def test_watchdog_is_off_under_the_override(monkeypatch) -> None:
    monkeypatch.setenv(resource_guard.OVERRIDE_ENV, "0")
    w = MemoryWatchdog(floor_pct=10.0, sampler=lambda: _sample(1.0))
    assert w.check(stage="local summarize") is None


def test_watchdog_does_not_abort_when_it_cannot_measure() -> None:
    # A guard that fires on its own failure to read the machine is worse than
    # no guard: it would turn an unreadable `vm_stat` into a failed meeting.
    w = MemoryWatchdog(floor_pct=10.0, sampler=lambda: None)
    assert w.check(stage="local summarize") is None


def test_sample_memory_is_self_consistent_or_absent() -> None:
    # Runs for real on both CI (Linux, no vm_stat -> None) and the owner's Mac.
    sample = resource_guard.sample_memory()
    if sample is not None:
        assert sample.total_bytes > 0
        assert 0.0 <= sample.free_pct <= 100.0


def test_assessment_is_pure_data() -> None:
    # `assess` returns a frozen record so a caller can hold it, log it, and
    # render from it without the policy being re-derived three different ways.
    a = assess(RECOMMENDED, 32.0)
    assert isinstance(a, Assessment)
    with pytest.raises(AttributeError):
        a.fit = "over"  # type: ignore[misc]


def test_events_module_is_the_only_writer(monkeypatch, tmp_path: Path) -> None:
    # Guard against a future edit reaching for print(): `mp logs` and
    # `mp analyze-detection` only see rows that went through events.emit.
    monkeypatch.setenv("MEETINGPIPE_LOGS_DIR", str(tmp_path))
    seen: list[tuple[str, str]] = []
    monkeypatch.setattr(
        events, "emit", lambda category, action, **_: seen.append((category, action))
    )
    monkeypatch.setattr(resource_guard, "events", events)
    with pytest.raises(ModelTooLargeError):
        require_model_fits(LARGE, ram_gb=16.0)
    assert seen == [("pipeline", "memory_guard_refused_model")]
