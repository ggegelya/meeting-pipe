"""The one backend table (PIPE19).

Backend choice used to be an if/elif over the same ids in four places, each with
its own subset; cleanup's subset missed two backends and failed silently. These
tests pin that every configurable backend has a row, that each row's locality is
what the long-meeting guard and the zero-egress rule expect, and that an unknown
id fails at lookup with the id in the message.
"""
from __future__ import annotations

import pytest

from mp import providers
from mp.config import BACKENDS, Config
from mp.orchestrate import _will_summarize_locally


def test_every_backend_has_a_row() -> None:
    assert set(providers.PROVIDERS) == set(BACKENDS)


@pytest.mark.parametrize("backend", sorted(BACKENDS))
def test_row_is_keyed_by_its_own_id(backend: str) -> None:
    assert providers.lookup(backend).backend_id == backend


# What `orchestrate`'s long-meeting guard and the Swift `SummarizationEngine`
# locality both assume. A cloud row that read "on_device" would exempt a
# billable run from the guard; the reverse would bundle a free one.
EXPECTED_LOCALITY = {
    "local": "on_device",
    "apple_intelligence": "on_device",
    "anthropic": "cloud",
    "claude_cli": "cloud",
    "openai": "cloud",
    "auto": "cloud_then_local",
}


def test_locality_matches_what_callers_expect() -> None:
    assert {k: v.locality for k, v in providers.PROVIDERS.items()} == EXPECTED_LOCALITY


@pytest.mark.parametrize("backend", sorted(BACKENDS))
def test_long_meeting_guard_reads_the_row(
    monkeypatch: pytest.MonkeyPatch, backend: str
) -> None:
    cfg = Config.model_validate({"summarization": {"backend": backend}})
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    assert _will_summarize_locally(cfg) is (EXPECTED_LOCALITY[backend] == "on_device")
    monkeypatch.delenv("ANTHROPIC_API_KEY")
    assert _will_summarize_locally(cfg) is (EXPECTED_LOCALITY[backend] != "cloud")


def test_unknown_id_raises_at_lookup_with_the_id() -> None:
    with pytest.raises(ValueError, match="made-up"):
        providers.lookup("made-up")


def test_every_python_path_is_covered_or_stood_in() -> None:
    """Cleanup and free-form text have a builder on every row, or a stand-in row
    that does. A row with neither is the silent gap PIPE19 closed."""
    for row in providers.PROVIDERS.values():
        target = providers.lookup(row.stand_in) if row.stand_in else row
        assert target.build_text is not None, row.backend_id
        assert target.build_cleanup is not None, row.backend_id
        assert row.build_summary is not None, row.backend_id


def test_stand_ins_stay_on_device() -> None:
    # A stand-in must never widen egress: Apple Intelligence's Python paths run
    # on the local MLX model, not on a cloud row.
    for row in providers.PROVIDERS.values():
        if row.stand_in:
            assert row.locality == "on_device"
            assert providers.lookup(row.stand_in).locality == "on_device"
