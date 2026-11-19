"""SEC27: the client side of the local model server's trust boundary.

The server proves it holds the per-spawn token before the client sends it
anything; a listener that cannot is refused, never reused, never killed.
"""
from __future__ import annotations

import json
import stat
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from mp import local_server
from mp.summarize_local import LocalSummaryClient, LocalSummaryError

from .fake_health import TEST_TOKEN, answer_health

# conftest replaces `read_token` for every test; keep the real one for its own tests.
_REAL_READ_TOKEN = local_server.read_token


class _Squatter(BaseHTTPRequestHandler):
    """Whatever grabbed an idle loopback port. Answers 200 to everything, which
    is exactly what the old `GET /v1/models` check accepted as "our server"."""

    def log_message(self, *_a: object) -> None:
        pass

    def do_GET(self) -> None:
        self.server.gets.append(self.path)  # type: ignore[attr-defined]
        body = json.dumps({"status": "ok", "proof": "0" * 64, "data": []}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        self.server.posts.append(self.headers.get("Authorization"))  # type: ignore[attr-defined]
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"{}")


class _Genuine(_Squatter):
    def do_GET(self) -> None:
        self.server.gets.append(self.path)  # type: ignore[attr-defined]
        if not answer_health(self):
            self.send_response(404)
            self.end_headers()


def _serve(handler):
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    server.gets, server.posts = [], []  # type: ignore[attr-defined]
    threading.Thread(target=lambda: server.serve_forever(poll_interval=0.01), daemon=True).start()
    return server


@pytest.fixture
def squatter():
    s = _serve(_Squatter)
    yield s
    s.shutdown()
    s.server_close()


@pytest.fixture
def genuine():
    s = _serve(_Genuine)
    yield s
    s.shutdown()
    s.server_close()


def _client(server, **kw) -> LocalSummaryClient:
    return LocalSummaryClient(host="127.0.0.1", port=server.server_address[1], **kw)


def test_a_listener_that_cannot_prove_the_token_is_foreign(squatter) -> None:
    c = _client(squatter, manage_subprocess=False)
    assert c._probe() == "foreign"
    # The probe sent a nonce and no credential, so a squatter learns no token.
    assert squatter.gets and "nonce=" in squatter.gets[0]
    c.close()


def test_a_server_holding_the_token_is_ok(genuine) -> None:
    c = _client(genuine, manage_subprocess=False)
    assert c._probe() == "ok"
    c.close()


def test_nothing_listening_is_down() -> None:
    c = LocalSummaryClient(host="127.0.0.1", port=1, manage_subprocess=False)
    assert c._probe() == "down"
    c.close()


def test_a_server_we_have_no_token_for_cannot_be_verified(genuine, monkeypatch) -> None:
    monkeypatch.setattr(local_server, "read_token", lambda port, home=None: None)
    c = _client(genuine, manage_subprocess=False)
    assert c._probe() == "foreign"
    c.close()


def test_a_non_http_listener_is_foreign_not_down() -> None:
    import socket

    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)

    def _garbage() -> None:
        conn, _ = srv.accept()
        conn.sendall(b"not http at all\r\n\r\n")
        conn.close()

    threading.Thread(target=_garbage, daemon=True).start()
    c = LocalSummaryClient(host="127.0.0.1", port=srv.getsockname()[1], manage_subprocess=False)
    assert c._probe() == "foreign"
    c.close()
    srv.close()


@pytest.mark.parametrize("manage", [True, False])
def test_a_squatter_on_the_port_gets_nothing_in_any_mode(squatter, manage) -> None:
    """Item 7: the transcript went to whatever answered 200. Now the run is
    refused, whether or not this client could have spawned a server of its own."""
    c = _client(squatter, manage_subprocess=manage)
    spawned: list[str] = []
    c._spawn = lambda: spawned.append("spawn")  # type: ignore[method-assign]
    with pytest.raises(LocalSummaryError, match="did not prove"):
        c.summarize(system_prompt="s", transcript="a transcript", model="m", max_tokens=8)
    assert squatter.posts == []                      # nothing was sent to it
    assert spawned == []                             # and it was not replaced either
    c.close()


def test_the_refusal_names_the_listener_and_never_kills_it(squatter, monkeypatch) -> None:
    ident = local_server.ServedIdentity(
        pid=4242, model=None, adapter_path=None, source="foreign",
        command="/usr/bin/python3 -m http.server 8765",
    )
    monkeypatch.setattr(local_server, "served_identity", lambda port, home=None: ident)
    monkeypatch.setattr(local_server, "terminate_server",
                        lambda *a, **k: pytest.fail("a foreign listener must never be killed"))
    c = _client(squatter)
    with pytest.raises(LocalSummaryError) as exc:
        c._ensure_running()
    assert "pid 4242" in str(exc.value) and "http.server" in str(exc.value)
    c.close()


def test_an_older_model_server_we_have_no_token_for_is_named_as_such(squatter, monkeypatch) -> None:
    ident = local_server.ServedIdentity(
        pid=77, model="a/b", adapter_path=None, source="argv",
        command="/venv/bin/mlx_lm.server --model a/b --port 8765",
    )
    monkeypatch.setattr(local_server, "served_identity", lambda port, home=None: ident)
    c = _client(squatter)
    with pytest.raises(LocalSummaryError, match="older MeetingPipe"):
        c._ensure_running()
    c.close()


def test_a_genuine_server_lsof_names_as_something_else_is_still_refused(genuine, monkeypatch) -> None:
    """Item 3, belt and braces: the proof said ours, but `lsof`/`ps` identify the
    listener as another program (a proxy in front, a spoofed proof)."""
    ident = local_server.ServedIdentity(
        pid=9, model=None, adapter_path=None, source="foreign", command="/usr/bin/socat"
    )
    monkeypatch.setattr(local_server, "served_identity", lambda port, home=None: ident)
    c = _client(genuine, manage_subprocess=False)
    with pytest.raises(LocalSummaryError, match="socat"):
        c._ensure_running()
    c.close()


def test_an_unidentifiable_listener_is_reused_only_when_it_proved_the_token(
    genuine, monkeypatch
) -> None:
    """`lsof` missing keeps today's behaviour, but only because the token check
    passed: the unknown case used to be reused unconditionally."""
    monkeypatch.setattr(local_server, "served_identity", lambda port, home=None: None)
    c = _client(genuine, manage_subprocess=False)
    c._ensure_running()                              # proved the token: reused
    c.close()


def test_the_bearer_is_derived_from_the_token_and_only_after_a_proof(genuine) -> None:
    c = _client(genuine, manage_subprocess=False)
    c._ensure_running()
    header = c._auth_headers()["Authorization"]
    assert header == f"Bearer {local_server.bearer_for(TEST_TOKEN)}"
    assert TEST_TOKEN not in header                       # the proof key never rides the wire
    c.close()


def test_a_spawned_servers_token_beats_the_recorded_one(genuine, monkeypatch) -> None:
    c = _client(genuine)
    c._spawned_token = "s" * 43
    assert c._token() == "s" * 43
    c._spawned_token = None
    assert c._token() == TEST_TOKEN                       # falls back to the record
    c.close()


def test_every_request_re_verifies_the_server(genuine) -> None:
    """The run lasts minutes; a server that dies mid-run frees its port for
    anything, and the next window must not be sent there."""
    c = _client(genuine, manage_subprocess=False)
    genuine.posts_before = len(genuine.posts)
    c._ensure_running()
    genuine.shutdown()
    genuine.server_close()                                # the server goes away mid-run
    squat = ThreadingHTTPServer(("127.0.0.1", genuine.server_address[1]), _Squatter)
    squat.gets, squat.posts = [], []                      # type: ignore[attr-defined]
    threading.Thread(target=lambda: squat.serve_forever(poll_interval=0.01), daemon=True).start()
    try:
        with pytest.raises(LocalSummaryError, match="did not prove"):
            c._chat_completion(messages=[{"role": "user", "content": "x"}], max_tokens=4)
        assert squat.posts == []                          # the window went nowhere
    finally:
        squat.shutdown()
        squat.server_close()
        c.close()


def test_a_server_that_exited_mid_run_is_reported_not_retried_blindly() -> None:
    c = LocalSummaryClient(host="127.0.0.1", port=1, manage_subprocess=False)
    with pytest.raises(LocalSummaryError, match="no longer running"):
        c._chat_completion(messages=[{"role": "user", "content": "x"}], max_tokens=4)
    c.close()


def test_losing_a_spawn_race_attaches_to_the_winner(genuine, monkeypatch) -> None:
    """Two `mp` start at once: ours exits on "address in use" while the winner's
    server (a different token, recorded in the file) serves the port."""
    c = _client(genuine)

    class _Exited:
        returncode = 1

        def poll(self) -> int:
            return 1

    c._proc = _Exited()  # type: ignore[assignment]
    c._spawned_token = "loser-" + "x" * 37                # our own, now-dead server's token
    c._wait_for_health(2.0)                               # must not raise
    assert c._spawned_token is None and c._probe() == "ok"
    c.close()


def test_a_busy_server_that_misses_one_window_is_not_a_stranger(monkeypatch) -> None:
    import httpx

    c = LocalSummaryClient(host="127.0.0.1", port=1, manage_subprocess=False)
    calls = {"n": 0}

    def fake_get(url, **kw):
        calls["n"] += 1
        if calls["n"] < 3:
            raise httpx.ReadTimeout("slow")
        nonce = kw["params"]["nonce"]
        return httpx.Response(
            200, json={"proof": local_server.health_proof(TEST_TOKEN, nonce)},
            request=httpx.Request("GET", url),
        )

    monkeypatch.setattr(c._http, "get", fake_get)
    assert c._probe() == "ok" and calls["n"] == 3
    c.close()


# ----- the token record, and the child environment -----


def test_the_token_record_is_owner_only_and_keyed_by_port(tmp_path: Path) -> None:
    local_server.write_token(8765, "t" * 43, 4242, tmp_path)
    path = local_server.token_path(tmp_path)
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert _REAL_READ_TOKEN(8765, tmp_path) == "t" * 43
    assert _REAL_READ_TOKEN(9999, tmp_path) is None            # another port's server
    assert json.loads(path.read_text())["pid"] == 4242


def test_a_stale_loose_temp_file_never_leaks_its_mode_into_the_record(tmp_path: Path) -> None:
    import os

    path = local_server.token_path(tmp_path)
    path.parent.mkdir(parents=True)
    stale = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    stale.write_text("old")
    stale.chmod(0o644)
    local_server.write_token(8765, "t" * 43, 1, tmp_path)
    assert stat.S_IMODE(path.stat().st_mode) == 0o600


def test_the_record_is_cleared_only_for_the_server_that_wrote_it(tmp_path: Path) -> None:
    local_server.write_token(8765, "t" * 43, 4242, tmp_path)
    local_server.clear_token(9999, tmp_path)                   # someone else's pid: untouched
    assert _REAL_READ_TOKEN(8765, tmp_path) == "t" * 43
    local_server.clear_token(4242, tmp_path)
    assert _REAL_READ_TOKEN(8765, tmp_path) is None


def test_a_missing_or_corrupt_token_record_reads_as_none(tmp_path: Path) -> None:
    assert _REAL_READ_TOKEN(8765, tmp_path) is None
    p = local_server.token_path(tmp_path)
    p.parent.mkdir(parents=True)
    p.write_text("{nope")
    assert _REAL_READ_TOKEN(8765, tmp_path) is None


def test_the_proof_depends_on_both_the_token_and_the_nonce() -> None:
    a = local_server.health_proof("k" * 43, "n1" * 12)
    assert a == local_server.health_proof("k" * 43, "n1" * 12)
    assert a != local_server.health_proof("k" * 43, "n2" * 12)
    assert a != local_server.health_proof("j" * 43, "n1" * 12)


def test_server_env_strips_every_managed_token_in_every_mode(monkeypatch) -> None:
    from mp.config import MANAGED_SECRET_KEYS

    env = local_server.server_env(
        "tok", base={**{k: "s" for k in MANAGED_SECRET_KEYS}, "PATH": "/bin"}
    )
    assert not any(k in env for k in MANAGED_SECRET_KEYS)
    assert env["PATH"] == "/bin"
    assert env["HF_HUB_OFFLINE"] == "1" and env["TRANSFORMERS_OFFLINE"] == "1"
    assert env[local_server.TOKEN_ENV] == "tok"


def test_both_our_server_command_lines_are_recognised() -> None:
    assert local_server.is_server_command("/v/bin/python -m mp.local_model_server --port 8765")
    assert local_server.is_server_command("/opt/bin/mlx_lm.server --model a/b")
    assert not local_server.is_server_command("/usr/bin/python3 -m http.server 8765")
    assert not local_server.is_server_command(None)


def test_identity_maps_a_snapshot_path_back_to_its_repo_id() -> None:
    sha = "a" * 40
    cmd = (
        "/v/bin/python -m mp.local_model_server --prompt-cache-size 2 --model "
        f"/Users/me/My Docs/.cache/huggingface/hub/models--mlx-community--Qwen2.5-7B-Instruct-4bit/snapshots/{sha}"
        " --host 127.0.0.1 --port 8765"
    )
    model, adapter = local_server.parse_identity(cmd)
    assert model == "mlx-community/Qwen2.5-7B-Instruct-4bit" and adapter is None


def test_the_shim_command_line_is_the_one_the_server_check_expects() -> None:
    from mp.summarize_local import build_server_command

    cmd = " ".join(build_server_command("/snap", "127.0.0.1", 8765))
    assert local_server.is_server_command(cmd)
