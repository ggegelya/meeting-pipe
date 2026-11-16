"""SEC23: a Keychain read that fails is "could not be read", not "not set"."""

from __future__ import annotations

import subprocess

import pytest

from mp import config
from mp.config import (
    MANAGED_SECRET_KEYS,
    KeychainUnreadableError,
    MissingSecretError,
    _keychain_get,
    load_secrets,
    require_env,
)


def _fake_run(returncode: int, stdout: str = "", stderr: str = ""):
    def run(*args, **kwargs):
        return subprocess.CompletedProcess(args, returncode, stdout, stderr)

    return run


@pytest.fixture(autouse=True)
def _clean(monkeypatch: pytest.MonkeyPatch):
    for key in MANAGED_SECRET_KEYS:
        monkeypatch.delenv(key, raising=False)
    config._UNREADABLE_SECRETS.clear()
    monkeypatch.setattr("mp.egress_guard.is_armed", lambda: False)
    yield
    config._UNREADABLE_SECRETS.clear()


def test_status_44_is_absent(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(subprocess, "run", _fake_run(44, stderr="could not be found"))
    assert _keychain_get("NOTION_TOKEN") is None


def test_found_and_empty_values(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(subprocess, "run", _fake_run(0, stdout="ntn-x\n"))
    assert _keychain_get("NOTION_TOKEN") == "ntn-x"
    monkeypatch.setattr(subprocess, "run", _fake_run(0, stdout="\n"))
    assert _keychain_get("NOTION_TOKEN") is None


@pytest.mark.parametrize("status", [36, 51, 1])
def test_any_other_status_is_unreadable(monkeypatch: pytest.MonkeyPatch, status: int) -> None:
    monkeypatch.setattr(subprocess, "run", _fake_run(status, stderr="User interaction is not allowed."))
    with pytest.raises(KeychainUnreadableError) as caught:
        _keychain_get("NOTION_TOKEN")
    assert caught.value.status == status
    assert caught.value.name == "NOTION_TOKEN"


def test_a_spawn_failure_or_timeout_is_unreadable(monkeypatch: pytest.MonkeyPatch) -> None:
    def boom(*args, **kwargs):
        raise OSError("no security")

    monkeypatch.setattr(subprocess, "run", boom)
    with pytest.raises(KeychainUnreadableError):
        _keychain_get("NOTION_TOKEN")

    def slow(*args, **kwargs):
        raise subprocess.TimeoutExpired("security", 10)

    monkeypatch.setattr(subprocess, "run", slow)
    with pytest.raises(KeychainUnreadableError):
        _keychain_get("NOTION_TOKEN")


def test_a_locked_keychain_does_not_fail_a_run_that_needs_no_token(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(subprocess, "run", _fake_run(36, stderr="locked"))
    load_secrets()  # must not raise: nothing has asked for a token yet
    assert set(config._UNREADABLE_SECRETS) == set(MANAGED_SECRET_KEYS)


def test_the_token_a_stage_asks_for_reports_could_not_be_read_not_not_set(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(subprocess, "run", _fake_run(36, stderr="locked"))
    load_secrets()
    with pytest.raises(KeychainUnreadableError) as caught:
        require_env("ANTHROPIC_API_KEY")
    message = str(caught.value)
    assert "not set" not in message
    assert "could not be read" in message
    assert "security unlock-keychain" in message
    assert isinstance(caught.value, MissingSecretError)  # every PIPE16 handler still catches it


def test_load_secrets_with_an_injected_reader_records_the_unreadable_status() -> None:
    def reader(key: str):
        raise KeychainUnreadableError(key, 36, "locked")

    load_secrets(reader=reader)
    assert config._UNREADABLE_SECRETS["NOTION_TOKEN"].status == 36


def test_a_truly_absent_token_still_says_not_set(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(subprocess, "run", _fake_run(44))
    load_secrets()
    with pytest.raises(MissingSecretError) as caught:
        require_env("NOTION_TOKEN")
    assert not isinstance(caught.value, KeychainUnreadableError)
    assert "is not set" in str(caught.value)


def test_a_later_good_read_clears_the_unreadable_mark(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(subprocess, "run", _fake_run(36))
    load_secrets()
    monkeypatch.setattr(subprocess, "run", _fake_run(0, stdout="ntn-x\n"))
    load_secrets()
    assert require_env("NOTION_TOKEN") == "ntn-x"


def test_doctor_says_could_not_be_read_not_not_in_keychain(monkeypatch: pytest.MonkeyPatch, capsys) -> None:
    from mp import doctor

    monkeypatch.setattr(subprocess, "run", _fake_run(36, stderr="locked"))
    presence = doctor.check_secrets()
    out = capsys.readouterr().out + capsys.readouterr().err
    assert not any(presence.values())
    assert "could not be read" in out
    assert "not in Keychain" not in out
