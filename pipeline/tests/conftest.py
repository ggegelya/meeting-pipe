"""Shared pytest fixtures for the pipeline suite."""
from __future__ import annotations

import ipaddress
import json
import os
import signal
import socket
import tempfile
from pathlib import Path
from typing import Any

import pytest

from mp import egress_guard, resource_guard
from mp.config import MANAGED_SECRET_KEYS, Config
from mp.providers import Provider
from mp.schemas import MeetingSummary

# T6: the suite owns its log isolation; production `events.logs_dir` no longer asks
# whether pytest is imported. This session-wide default covers anything that writes
# outside a test body (collection, session fixtures, a child process they spawn);
# `_isolated_logs_dir` below gives each test its own directory over it.
os.environ["MEETINGPIPE_LOGS_DIR"] = str(Path(tempfile.gettempdir()) / "MeetingPipe-test-logs")


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "guard_proof: an egress-guard test that aims at a public address on purpose, with "
        "the guard's downstream connect stubbed to fail; `_no_network` stands aside (T12)",
    )
    config.addinivalue_line(
        "markers",
        "content_floor: keep PIPE43's content floor live; every other test runs with it off",
    )


@pytest.hookimpl(wrapper=True)
def pytest_runtest_makereport(item, call):
    """Keeps the call phase's report on the item, so `_no_network` reports a blocked
    connect once: at teardown only when the test swallowed the in-call failure."""
    report = yield
    if report.when == "call":
        item._t12_call_report = report
    return report


def _loopback_host(host: object) -> bool:
    """True for a host a test may reach: loopback, unspecified, `localhost`, or no
    host at all. A name is refused, since resolving it already leaves the machine."""
    if host is None or host in ("", "localhost", b"localhost"):
        return True
    if isinstance(host, bytes):
        host = host.decode("ascii", "replace")
    if not isinstance(host, str):
        return False
    try:
        ip = ipaddress.ip_address(host.split("%", 1)[0])
    except ValueError:
        return False
    mapped = getattr(ip, "ipv4_mapped", None)
    return ip.is_loopback or ip.is_unspecified or bool(mapped and mapped.is_loopback)


# T12: the suite never leaves the machine. One wrapper over `getaddrinfo` and INET
# `connect` / `connect_ex`, installed once at import and never removed: the egress
# guard also patches `socket.connect` once per process and keeps what it captured,
# so a per-test install-and-restore pulled the guard out from under every later test.
# The wrapper consults `_NETWORK`, which `_no_network` points at the running test.
_NETWORK: dict = {"node": None, "blocked": None}
_REAL_GETADDRINFO = socket.getaddrinfo
_REAL_CONNECT = socket.socket.connect
_REAL_CONNECT_EX = socket.socket.connect_ex


def _refuse(what: str) -> None:
    node, blocked = _NETWORK["node"], _NETWORK["blocked"]
    if node is None:
        return
    blocked.append(what)
    pytest.fail(f"{node}: {what} leaves the machine; tests are loopback-only (T12)", pytrace=False)


def _suite_getaddrinfo(host, *args, **kwargs):
    if not _loopback_host(host):
        _refuse(f"getaddrinfo({host!r})")
    return _REAL_GETADDRINFO(host, *args, **kwargs)


def _check_connect(sock: socket.socket, address) -> None:
    if sock.family in (socket.AF_INET, socket.AF_INET6) and not _loopback_host(address[0]):
        _refuse(f"connect to {address!r}")


def _suite_connect(self, address):
    _check_connect(self, address)
    return _REAL_CONNECT(self, address)


def _suite_connect_ex(self, address):
    _check_connect(self, address)
    return _REAL_CONNECT_EX(self, address)


socket.getaddrinfo = _suite_getaddrinfo
socket.socket.connect = _suite_connect  # type: ignore[method-assign]
socket.socket.connect_ex = _suite_connect_ex  # type: ignore[method-assign]


@pytest.fixture(autouse=True)
def _no_network(request):
    """T12: fails any `getaddrinfo` of a name or IP that is not loopback, and any
    INET `connect` to one, naming the test. `test_cli_out_writes_cluster_ids` and
    eight `test_ask.py` cases resolved huggingface.co through an unpinned embedder
    before this existed.

    Raised as `pytest.fail` (a BaseException, so a library `except Exception` cannot
    swallow it) and also recorded, so a caller that catches BaseException still fails
    the test at teardown. A `guard_proof` or `live` test stands it aside. A test that stubs
    `socket.getaddrinfo` itself replaces that half for its own duration."""
    # T10: a `live` test exists to reach the real API, and skips itself unless the
    # owner opted in with a key, so it is the one other case that stands aside.
    if any(request.node.get_closest_marker(m) is not None for m in ("guard_proof", "live")):
        yield
        return
    blocked: list[str] = []
    node = request.node.nodeid
    _NETWORK.update(node=node, blocked=blocked)
    try:
        yield
    finally:
        _NETWORK.update(node=None, blocked=None)
    call = getattr(request.node, "_t12_call_report", None)
    if blocked and not (call is not None and call.failed):
        pytest.fail(f"{node}: blocked network access was swallowed: {blocked}", pytrace=False)


@pytest.fixture(autouse=True)
def _isolated_logs_dir(monkeypatch, tmp_path_factory) -> Path:
    """T6: every test writes its events, `pipeline.log` and model-server marker into a
    logs directory of its own, which is the whole of the suite's log isolation now that
    `events.logs_dir` has no pytest sniff. Before any isolation the suite owned 21% of
    the real `pipeline_events.jsonl`. A fresh directory rather than `tmp_path` itself,
    because many tests treat `tmp_path` as a library folder and compare its listing.

    A test that sets the variable itself wins; one that clears it and then writes reaches
    the real logs folder, so don't (see `pipeline/docs/gotchas.md`). Request this fixture
    by name to read back the events a test emitted."""
    logs = tmp_path_factory.mktemp("logs")
    monkeypatch.setenv("MEETINGPIPE_LOGS_DIR", str(logs))
    return logs


def _no_keychain(_key: str) -> None:
    return None


@pytest.fixture(autouse=True)
def _keychain_unreachable(monkeypatch):
    """T12: `config.load_secrets` reads the developer's Keychain through
    `/usr/bin/security` for every managed token missing from the environment, and
    any test reaching `entry.prepare(..., secrets=True)` (`run_all`, `summarize`,
    `doctor`) did so with a live token in `os.environ` for its duration. Its reader
    is a default bound at definition time, so `config._keychain_get` cannot be
    patched; the default itself is. A test passing `reader=` is unaffected, and
    `test_keychain_secrets.py` restores the real default to test it over a faked
    `subprocess.run`."""
    from mp import config

    monkeypatch.setattr(config.load_secrets, "__defaults__", (_no_keychain,))


@pytest.fixture(autouse=True)
def _no_developer_config(monkeypatch, tmp_path):
    """T12: `Config.load()` with no path reads `~/.config/meeting-pipe/config.toml`,
    so a malformed developer config failed tests and one with `regulated_mode` on
    armed the egress guard inside them. Point it at a per-test path that does not
    exist; a test that writes one there, or passes a path, gets exactly that."""
    from mp import config, doctor

    missing = tmp_path / "no-config-home" / "config.toml"
    monkeypatch.setattr(config, "CONFIG_PATH", missing)
    monkeypatch.setattr(doctor, "CONFIG_PATH", missing)
    # WF11: `load_glossary` now reads the workflows directory whenever a meeting's sidecar
    # carries a `workflow_id`; its default was computed from the real CONFIG_PATH at import.
    from mp import workflows

    monkeypatch.setattr(workflows, "WORKFLOWS_DIR", missing.parent / "workflows")
    # STOR6: a config naming no library path keeps the old ~/Documents default when it holds
    # files, which on a developer's Mac it does. Point the old defaults somewhere empty too.
    monkeypatch.setattr(config, "LEGACY_OUTPUT_DIR", str(tmp_path / "no-legacy" / "raw"))
    monkeypatch.setattr(config, "LEGACY_PUBLISHED_DIR", str(tmp_path / "no-legacy" / "published"))


@pytest.fixture(autouse=True)
def _known_encryption(monkeypatch):
    """STOR8: `mp backup` asks `df` and `diskutil` about the destination's volume.
    Stubbed for the whole suite so no test shells out to them (`diskutil` does not
    exist on the Linux runner); the probe's own tests in `test_backup_restore.py`
    call the real function with an injected runner."""
    from mp import backup

    monkeypatch.setattr(backup, "destination_encrypted", lambda _d: True)


@pytest.fixture(autouse=True)
def _disable_memory_guard(monkeypatch):
    """LOCAL16: the memory guard reads the REAL machine (physical RAM, and free
    RAM via `vm_stat`), so leaving it live would let an unrelated local-client
    test fail because the developer's Mac happened to be under pressure, or
    because a CI runner is smaller than the model the fixture names.

    Off for the suite by default, and the two files that exist to test it
    (`test_resource_guard.py`, the LOCAL16 cases in `test_summarize_local.py`)
    turn it back on deliberately and pass an explicit `ram_gb`.
    """
    monkeypatch.setenv(resource_guard.OVERRIDE_ENV, "0")


@pytest.fixture(autouse=True)
def _content_floor_off(request, monkeypatch):
    """PIPE43: `run_all` skips a transcript under 150 words or 120 s of speech, and the run-all
    fixtures across the suite are one-line transcripts written to exercise everything after that
    gate. Off by default, the way `_disable_memory_guard` handles the memory guard; the tests of
    the floor itself opt back in with `@pytest.mark.content_floor`."""
    if request.node.get_closest_marker("content_floor") is not None:
        return
    from mp import transcript_quality

    monkeypatch.setattr(transcript_quality, "_FLOOR_MIN_WORDS", 0)
    monkeypatch.setattr(transcript_quality, "_FLOOR_MIN_SPAN_SEC", 0.0)


@pytest.fixture(autouse=True)
def _reset_egress_guard():
    """The egress guard is process-global state (TECH-SEC3). Disarm it after
    every test so a test that arms it (directly or through an entry point that
    resolves a regulated/NDA config) cannot block httpx for later tests.

    SEC13 gave `arm()` a second global effect: it pops the managed cloud tokens
    out of `os.environ` and forces the HF offline flags in. Snapshot and restore
    those too, or one armed test strips the developer's exported
    ANTHROPIC_API_KEY for every test that runs after it.

    SEC19 added a third: it drops every `*_proxy` variable and sets `NO_PROXY=*`,
    so those are snapshotted by pattern (the names present differ per machine).
    """
    def proxy_keys() -> set[str]:
        return {k for k in os.environ if k.lower().endswith("_proxy")}

    watched = {*MANAGED_SECRET_KEYS, "HF_HUB_OFFLINE", "HF_HUB_DISABLE_TELEMETRY", *proxy_keys()}
    before = {k: os.environ.get(k) for k in watched}
    yield
    for key in proxy_keys() - watched:
        os.environ.pop(key, None)
    egress_guard.disarm()
    for key, value in before.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value


@pytest.fixture(autouse=True)
def _restore_sigterm_disposition():
    """`mp.__main__.main` installs a process-wide SIGTERM handler (PIPE22), and
    in-process tests call `main()`. Put back whatever pytest had, so a test that
    drove the router cannot leave the whole suite turning SIGTERM into a
    `SystemExit` in whichever test happens to be running when one arrives."""
    before = signal.getsignal(signal.SIGTERM)
    yield
    signal.signal(signal.SIGTERM, before)


@pytest.fixture(autouse=True)
def _private_server_marker(monkeypatch, tmp_path_factory):
    """`local_server.marker_path()` used to default to the real `~/Library/Logs/
    MeetingPipe/mlx-server.json`, and `LocalSummaryClient` calls it with no
    `home`, so any test that spawns, closes, or reuses a server through the
    client wrote, rewrote or deleted the developer's live marker, the one the
    daemon's reaper acts on (PIPE22). Since T9 the default follows
    `events.logs_dir`, which conftest points at each test's own logs dir (T6);
    this also keeps the marker out of it. A test that passes `home` explicitly
    still gets exactly the path it asked for."""
    from mp import local_server

    home = tmp_path_factory.mktemp("marker-home")
    real = local_server.marker_path
    monkeypatch.setattr(local_server, "marker_path", lambda h=None: real(h or home))


@pytest.fixture(autouse=True)
def _private_attempt_markers(monkeypatch, tmp_path_factory):
    """STOR10: `mp backup` and `mp digest` write their attempt markers under the real
    `~/.config/meeting-pipe/` when called without a `home`, which every `main` test does.
    Keep each test's markers private; a test that passes `home` gets that path."""
    from mp import run_attempt

    home = tmp_path_factory.mktemp("attempt-home")
    real = run_attempt.marker_path
    monkeypatch.setattr(run_attempt, "marker_path", lambda name, h=None: real(name, h or home))


@pytest.fixture(autouse=True)
def _fixed_server_token(monkeypatch, tmp_path_factory):
    """SEC27: the client verifies a model server with the per-spawn token, and
    the real record of it lives in Application Support. Give every test the one
    token the fake servers in `fake_health.py` answer with, so none reads or
    writes the developer's live token file."""
    from mp import local_server

    from .fake_health import TEST_TOKEN

    monkeypatch.setattr(local_server, "read_token", lambda port, home=None: TEST_TOKEN)
    home = tmp_path_factory.mktemp("token-home")
    real_path = local_server.token_path
    monkeypatch.setattr(local_server, "token_path", lambda h=None: real_path(h or home))

    # The fakes listen inside the pytest process, which `lsof` would (correctly)
    # name as a foreign listener (SEC27). Default to "lsof could not say", the
    # situation every fake-server test was written for; the tests of the foreign
    # path and of `served_identity` itself patch their own answers over this.
    monkeypatch.setattr(local_server, "listening_pid", lambda port: None)


@pytest.fixture(autouse=True)
def _fresh_secret_probe_state():
    """`load_secrets` remembers absent and unreadable keys for the life of the process (CONC8, SEC23),
    which is a property of a real run and a leak between tests."""
    from mp import config

    config._ABSENT_SECRETS.clear()
    config._UNREADABLE_SECRETS.clear()
    yield
    config._ABSENT_SECRETS.clear()
    config._UNREADABLE_SECRETS.clear()


@pytest.fixture
def evicted(monkeypatch):
    """PIPE35: make a library file read the way an iCloud-evicted (dataless) one does on the
    owner's Mac, `[Errno 11] Resource deadlock avoided` (EDEADLK), without touching iCloud.
    Returns a function that marks one path; every `Path.read_bytes` of it then raises."""
    import errno as errno_mod
    from pathlib import Path as _Path

    marked: set[_Path] = set()
    real = _Path.read_bytes

    def _read_bytes(self):
        if _Path(self) in marked:
            raise OSError(errno_mod.EDEADLK, "Resource deadlock avoided", str(self))
        return real(self)

    monkeypatch.setattr(_Path, "read_bytes", _read_bytes)
    return lambda path: marked.add(_Path(path))


# ----- T6: in-memory collaborators for `run_all` (the `services.py` protocols) -----


def standup_summary() -> MeetingSummary:
    """A summary with enough content to clear PIPE43's floor and nothing for LANG1 to repair."""
    return MeetingSummary(
        title="Standup", summary=["Agreed the release plan."], decisions=[], actions=[],
        questions=[], attendees=[], detected_language="en",
    )


class FakeSummaryClient:
    """A `services.SummaryClient` that answers a fixed `MeetingSummary`, or raises
    `raises`, and records the `system_prompt` and `transcript` of every call.
    `provider()` wraps it as a `providers.Provider` row, the shape `run_all` takes."""

    def __init__(self, summary: MeetingSummary | None = None, *,
                 raises: BaseException | None = None, backend_id: str = "fake") -> None:
        self.summary = summary if summary is not None else standup_summary()
        self.raises = raises
        self.backend_id = backend_id
        self.calls: list[dict[str, str]] = []
        self.builds = 0  # how many times a provider row built this client

    def summarize(self, *, system_prompt: str, transcript: str, model: str,
                  max_tokens: int) -> MeetingSummary:
        self.calls.append({"system_prompt": system_prompt, "transcript": transcript})
        if self.raises is not None:
            raise self.raises
        return self.summary

    def provider(self) -> Provider:
        def build(_cfg: Config) -> FakeSummaryClient:
            self.builds += 1
            return self

        return Provider(self.backend_id, "on_device", build, None, None)


class RecordingPublisher:
    """A `services.MeetingPublisher` that records each `upsert` and returns `result`,
    or raises `error` (an all-sinks-failed run when it is the only sink)."""

    def __init__(self, name: str = "recording", *, result: dict[str, Any] | None = None,
                 error: Exception | None = None) -> None:
        self.name = name
        self.result = result if result is not None else {
            "page_id": "p", "page_url": "u", "idempotent": False}
        self.error = error
        self.upserts: list[dict[str, Any]] = []

    def upsert(self, *, summary: MeetingSummary, transcript_md: Path | None,
               sidecar_path: Path, transcript_text: str | None = None) -> dict[str, Any]:
        self.upserts.append({"summary": summary, "transcript_md": transcript_md,
                             "sidecar_path": sidecar_path, "transcript_text": transcript_text})
        if self.error is not None:
            raise self.error
        return dict(self.result)


def read_events(logs: Path) -> list[dict[str, Any]]:
    """The rows `events.emit` wrote into a test's `_isolated_logs_dir`."""
    path = logs / "pipeline_events.jsonl"
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
