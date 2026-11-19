"""PIPE32: `LocalSummaryClient.from_config` threads every config-backed parameter.

Every constructor parameter is defaulted, so a hand-built client that forgot one
ran on the constant: PIPE12 (adapter), LOCAL19 (memory floor) and speaker cleanup
(both local timeouts). These pin the factory and the two sites whose omissions it
closes; `test_local_client_contract.py` fences direct construction.
"""
from __future__ import annotations

import pytest

from mp import engine, providers
from mp.config import Config
from mp.summarize_local import DEFAULT_MAP_REDUCE_ABOVE_CHARS, LocalSummaryClient

#: Every config-backed field at a value no constructor default has.
NON_DEFAULT = {
    "local_model": "org/custom-model",
    "local_endpoint": "http://127.0.0.1:9911",
    "local_startup_timeout_sec": 333.0,
    "local_request_timeout_sec": 444.0,
    "summary_language": "uk",
    "skip_above_chars": 55_555,
    "local_adapter_path": "/adapters/mine",
    "local_memory_floor_pct": 17.5,
}


def _cfg(**summarization: object) -> Config:
    return Config.model_validate({"summarization": {**NON_DEFAULT, **summarization}})


def _threaded(client: LocalSummaryClient) -> dict[str, object]:
    return {
        "model": client._model,
        "host": client._host,
        "port": client._port,
        "startup_timeout_sec": client._startup_timeout_sec,
        "request_timeout_sec": client._request_timeout_sec,
        "summary_language": client._summary_language,
        "map_reduce_above_chars": client._map_reduce_above_chars,
        "adapter_path": client._adapter_path,
        "memory_floor_pct": client.watchdog.floor_pct,
    }


EXPECTED = {
    "model": "org/custom-model",
    "host": "127.0.0.1",
    "port": 9911,
    "startup_timeout_sec": 333.0,
    "request_timeout_sec": 444.0,
    "summary_language": "uk",
    "map_reduce_above_chars": 55_555,
    "adapter_path": "/adapters/mine",
    "memory_floor_pct": 17.5,
}


def test_from_config_threads_all_nine_config_backed_parameters() -> None:
    assert _threaded(LocalSummaryClient.from_config(_cfg())) == EXPECTED


@pytest.mark.parametrize("key,value", [
    ("model", "other/model"),
    ("port", 1234),
    ("adapter_path", None),
    ("summary_language", "auto"),
])
def test_an_override_replaces_exactly_one(key: str, value: object) -> None:
    got = _threaded(LocalSummaryClient.from_config(_cfg(), **{key: value}))
    assert got == {**EXPECTED, key: value}


def test_an_empty_adapter_path_means_the_base_model() -> None:
    assert LocalSummaryClient.from_config(_cfg(local_adapter_path=""))._adapter_path is None


def test_an_unknown_override_raises_like_the_constructor() -> None:
    with pytest.raises(TypeError):
        LocalSummaryClient.from_config(_cfg(), not_a_parameter=1)


def test_local_cleanup_carries_the_configured_timeouts() -> None:
    """`providers._local_cleanup` passed model, endpoint and floor only, so cleanup
    ran on the 120 s constructor defaults whatever the config said."""
    cleanup = providers._local_cleanup(_cfg())
    client = cleanup._local  # type: ignore[attr-defined]
    assert client._startup_timeout_sec == 333.0
    assert client._request_timeout_sec == 444.0
    assert client.watchdog.floor_pct == 17.5


def test_engine_local_client_keeps_the_adapter_and_its_two_decisions() -> None:
    """PIPE12's adapter fix and its deliberate skips, pinned through the factory:
    the adapter is configured, `summary_language` is `auto` whatever the configured
    summary language, and the map-reduce bound is the constructor default."""
    client = engine._local_client(_cfg(), None)
    assert client._adapter_path == "/adapters/mine"
    assert client._summary_language == "auto"
    assert client._map_reduce_above_chars == DEFAULT_MAP_REDUCE_ABOVE_CHARS
    assert client._model == "org/custom-model"
    assert client._request_timeout_sec == 444.0
    assert client.watchdog.floor_pct == 17.5
    assert engine._local_client(_cfg(), "picked/model")._model == "picked/model"
