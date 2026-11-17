"""OBS6: `MP_VERBOSE=1` puts the `mp` logger, and only it, at DEBUG."""
from __future__ import annotations

import logging
from pathlib import Path

import pytest

from mp import verbose
from mp.config import Config
from mp.workflow import apply_overrides


@pytest.fixture
def mp_logger():
    mp = logging.getLogger("mp")
    before = mp.level
    mp.setLevel(logging.NOTSET)
    yield mp
    mp.setLevel(before)


def test_verbose_sets_the_mp_logger_to_debug_and_leaves_root_and_httpx(mp_logger):
    root_before, httpx_before = logging.getLogger().level, logging.getLogger("httpx").getEffectiveLevel()
    assert verbose.configure({"MP_VERBOSE": "1"}) is True
    assert mp_logger.level == logging.DEBUG
    assert logging.getLogger().level == root_before
    assert logging.getLogger("httpx").getEffectiveLevel() == httpx_before


def test_without_the_env_var_nothing_changes(mp_logger):
    assert verbose.configure({}) is False
    assert verbose.configure({"MP_VERBOSE": "0"}) is False
    assert mp_logger.level == logging.NOTSET


class _ListHandler(logging.Handler):
    def __init__(self) -> None:
        super().__init__(level=logging.DEBUG)  # takes everything; the logger level decides
        self.lines: list[str] = []

    def emit(self, record: logging.LogRecord) -> None:
        if record.levelno == logging.DEBUG and record.name == "mp.workflow":
            self.lines.append(record.getMessage())


def test_a_debug_line_from_apply_overrides_reaches_the_handler_only_when_verbose(mp_logger, tmp_path: Path):
    handler = _ListHandler()
    root = logging.getLogger()
    root_level = root.level
    root.addHandler(handler)
    root.setLevel(logging.INFO)
    try:
        wav = tmp_path / "20260101-120000.wav"
        apply_overrides(Config(), wav)
        assert handler.lines == []

        verbose.configure({"MP_VERBOSE": "1"})
        apply_overrides(Config(), wav)
        assert handler.lines and "global config stands" in handler.lines[0]
    finally:
        root.removeHandler(handler)
        root.setLevel(root_level)
