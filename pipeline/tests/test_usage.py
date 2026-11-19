"""PIPE27: the long-meeting gate's knob is split from local chunking, the gate bills
only per-token engines, and a run's token spend is recorded."""
from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pytest

from mp import corrections, usage
from mp.config import Config, local_chunk_above_chars
from mp.orchestrate import _check_too_long, run_all
from mp.summarize import _create_message
from mp.summarize_local import LocalSummaryClient


@pytest.fixture(autouse=True)
def _fresh_tally():
    usage.reset()
    yield
    usage.reset()


def _cfg(**summarization: object) -> Config:
    return Config.model_validate({"summarization": summarization})


# ----- the split knob -----


def test_a_zero_cloud_gate_no_longer_turns_local_windowing_off() -> None:
    cfg = _cfg(skip_above_chars=0)
    assert local_chunk_above_chars(cfg) == 80_000
    assert LocalSummaryClient.from_config(cfg)._map_reduce_above_chars == 80_000


def test_an_old_non_zero_gate_still_bounds_local_chunking() -> None:
    assert local_chunk_above_chars(_cfg(skip_above_chars=50_000)) == 50_000


def test_both_knobs_set_act_independently(tmp_path: Path) -> None:
    cfg = _cfg(skip_above_chars=200_000, local_chunk_above_chars=30_000, backend="anthropic")
    assert LocalSummaryClient.from_config(cfg)._map_reduce_above_chars == 30_000
    md = tmp_path / "20260101-090000.md"
    md.write_text("x" * 100_000, encoding="utf-8")
    t = {"md": md, "json": tmp_path / "20260101-090000.json"}
    # 100 000 chars is over the chunk bound but under the cloud gate: no bundle.
    assert _check_too_long(tmp_path / "20260101-090000.wav", t, md.read_text(), cfg) is None


# ----- the gate bills per-token engines only -----


def _long(tmp_path: Path) -> tuple[Path, dict[str, Path], str]:
    md = tmp_path / "20260101-090001.md"
    md.write_text("A: " + "word " * 50, encoding="utf-8")
    return tmp_path / "20260101-090001.wav", {"md": md, "json": tmp_path / "x.json"}, md.read_text()


def test_claude_cli_over_the_threshold_summarizes_rather_than_bundles(tmp_path: Path) -> None:
    wav, t, text = _long(tmp_path)
    assert _check_too_long(wav, t, text, _cfg(backend="claude_cli", skip_above_chars=10)) is None
    assert not (tmp_path / "20260101-090001.READY_FOR_MANUAL.md").exists()


def test_anthropic_over_the_threshold_still_bundles(tmp_path: Path) -> None:
    wav, t, text = _long(tmp_path)
    skipped = _check_too_long(wav, t, text, _cfg(backend="anthropic", skip_above_chars=10))
    assert skipped is not None and "manual_bundle" in skipped


# ----- usage -----


class _FakeMessages:
    def __init__(self, usage_block: object) -> None:
        self._usage = usage_block

    def create(self, **_: object) -> object:
        return SimpleNamespace(content=[], stop_reason="end_turn", usage=self._usage)


def _anthropic_call(input_tokens: int, output_tokens: int, cache_read: int | None = None) -> None:
    block = SimpleNamespace(input_tokens=input_tokens, output_tokens=output_tokens,
                            cache_creation_input_tokens=None, cache_read_input_tokens=cache_read)
    _create_message(SimpleNamespace(messages=_FakeMessages(block)), model="m", max_tokens=1)


def test_every_anthropic_call_through_the_seam_is_summed() -> None:
    _anthropic_call(1000, 200)
    _anthropic_call(500, 50, cache_read=400)
    assert usage.snapshot() == {
        "calls": 2, "input_tokens": 1500, "output_tokens": 250, "cache_read_input_tokens": 400,
    }


def test_a_response_without_usage_records_nothing() -> None:
    _create_message(SimpleNamespace(messages=_FakeMessages(None)), model="m", max_tokens=1)
    assert usage.snapshot() is None


def test_openai_usage_is_recorded_in_the_same_names() -> None:
    usage.record_openai({"usage": {"prompt_tokens": 70, "completion_tokens": 9,
                                   "prompt_tokens_details": {"cached_tokens": 20}}})
    assert usage.snapshot() == {
        "calls": 1, "input_tokens": 70, "output_tokens": 9, "cache_read_input_tokens": 20,
    }


def test_the_run_sidecar_carries_usage_and_omits_it_when_none_ran(tmp_path: Path) -> None:
    common = dict(recordings_dir=tmp_path, transcript_path=tmp_path / "a.md", transcript_chars=1,
                  summary_json_path=tmp_path / "a.summary.json", backend="anthropic", model="m")
    with_usage = corrections.write_run_sidecar(stem="a", usage={"calls": 1, "input_tokens": 5,
                                                                "output_tokens": 2}, **common)
    assert json.loads(with_usage.read_text())["usage"] == {"calls": 1, "input_tokens": 5, "output_tokens": 2}
    without = corrections.write_run_sidecar(stem="b", **common)
    assert "usage" not in json.loads(without.read_text())


def test_a_run_writes_its_usage_to_run_json_and_run_completed(tmp_path: Path, monkeypatch) -> None:
    from .test_orchestrate import _write_fluidaudio_sidecar

    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    emitted: list[tuple] = []
    monkeypatch.setattr("mp.orchestrate.events.emit",
                        lambda cat, action, **attrs: emitted.append((cat, action, attrs)))
    stem = "20260516-0900"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem)
    summary_json = tmp_path / f"{stem}.summary.json"
    summary_json.write_text("{}", encoding="utf-8")
    spent = {"calls": 2, "input_tokens": 12_000, "output_tokens": 900}

    def fake_summarize(*_a: object, **_k: object) -> dict:
        _anthropic_call(12_000, 900 - 400)
        _anthropic_call(0, 400)
        return {"json": summary_json, "md": tmp_path / f"{stem}.summary.md",
                "backend": "anthropic", "model": "m", "usage": usage.snapshot()}

    with patch("mp.orchestrate.summarize", side_effect=fake_summarize), \
         patch("mp.orchestrate.publish_fanout", return_value={"sinks": {}, "failures": []}):
        run_all(wav, cfg=Config())

    run = json.loads((tmp_path / f"{stem}.run.json").read_text(encoding="utf-8"))
    assert run["usage"] == spent
    completed = next(attrs for _, a, attrs in emitted if a == "run_completed")
    assert completed["input_tokens"] == 12_000 and completed["output_tokens"] == 900
