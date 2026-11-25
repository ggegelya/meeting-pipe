"""UX107: one reachability table for `mp doctor` and the Finish setup checklist.

`reachability-golden.json` is generated from `mp.reachability` (see
`test_ci4_contracts.py` for the regeneration check) and replayed by Swift's
`SetupChecklistTests`. Here the same cases run through doctor's real check
functions, and its FAIL lines must name exactly the case's gaps.
"""
from __future__ import annotations

import json
import typing
import uuid
from pathlib import Path

import httpx
import pytest

from mp import doctor, reachability, workflows
from mp.config import BACKENDS, Config, SinkName

_FIXTURE = (
    Path(__file__).resolve().parents[2]
    / "daemon" / "Tests" / "MeetingPipeTests" / "Fixtures" / "reachability-golden.json"
)
_CASES = json.loads(_FIXTURE.read_text(encoding="utf-8"))["cases"]

# A substring of the FAIL line doctor prints for each gap.
_FAIL_MARKERS = {
    "anthropic_key": "ANTHROPIC_API_KEY not in Keychain",
    "openai_key": "OPENAI_API_KEY not in Keychain",
    "notion_token": "NOTION_TOKEN not in Keychain",
    "claude_binary": "`claude` not found but a workflow summarizes with Claude CLI",
    "notion_database": "publishes to Notion but has no database id",
    "local_model": "on-device model not downloaded yet",
}


def test_the_table_covers_every_backend_and_sink() -> None:
    assert set(reachability.BACKEND_NEEDS) == set(BACKENDS) == set(workflows.KNOWN_BACKENDS)
    assert set(reachability.SINK_NEEDS) == set(typing.get_args(SinkName))
    used = {g for needs in (*reachability.BACKEND_NEEDS.values(), *reachability.SINK_NEEDS.values()) for g in needs}
    assert used == set(reachability.GAP_ORDER)


def test_the_fixture_is_not_vacuous() -> None:
    assert len(_CASES) >= 10
    assert any(c["gaps"] == [] for c in _CASES)
    assert {g for c in _CASES for g in c["gaps"]} == set(reachability.GAP_ORDER)


def _write_workflows(directory: Path, docs: list[dict]) -> None:
    directory.mkdir()
    for doc in docs:
        lines = [f'id = "{uuid.uuid4()}"', f'name = "{doc["name"]}"']
        if doc["backend"] is not None:
            lines.append(f'backend = "{doc["backend"]}"')
        if doc["nda"]:
            lines += ["", "[flags]", "nda_mode = true"]
        for sink in doc["sinks"]:
            lines += ["", "[[sinks]]"] + [f'{k} = "{v}"' for k, v in sink.items()]
        (directory / f"{doc['name']}.toml").write_text("\n".join(lines) + "\n", encoding="utf-8")


def _notion_ok(monkeypatch) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/users/me"):
            return httpx.Response(200, json={"name": "test"})
        return httpx.Response(200, json={"title": [{"plain_text": "db"}]})

    client = httpx.Client(transport=httpx.MockTransport(handler))
    monkeypatch.setattr(httpx, "get", client.get)


def _run_doctor_sections(case: dict, tmp_path: Path, monkeypatch) -> None:
    """The doctor sections that decide the table's gaps, wired the way `main` wires them."""
    wf_dir = tmp_path / "workflows"
    _write_workflows(wf_dir, case["workflows"])
    monkeypatch.setattr(workflows, "WORKFLOWS_DIR", wf_dir)
    cfg = Config.model_validate({
        "summarization": {"backend": case["global_backend"]},
        "output": {"sinks": case["global_sinks"]},
        "notion": {"database_id": case["global_notion_database_id"]},
        "modes": {"regulated_mode": case["regulated"]},
    })
    present = case["present"]
    for gap, account in reachability.SECRET_ACCOUNT.items():
        if present[gap]:
            monkeypatch.setenv(account, f"sk-test-{gap}-0000")
        else:
            monkeypatch.delenv(account, raising=False)
    monkeypatch.setattr(
        "mp.provider_claude_cli.find_claude",
        lambda: "/usr/local/bin/claude" if present["claude_binary"] else None,
    )
    # The local stack: a pinned snapshot present or missing, everything else ample.
    from mp import local_snapshot
    monkeypatch.setattr("importlib.util.find_spec", lambda _name: object())
    monkeypatch.setattr("mp.resource_guard.physical_ram_gb", lambda: 64.0)
    monkeypatch.setattr("mp.doctor._free_disk_gb", lambda _p: 500.0)
    monkeypatch.setattr("mp.storage.bytes_on_disk", lambda _p: 0)

    def resolve(_model: str) -> Path:
        if present["local_model"]:
            return tmp_path / "snapshot0000000000"
        raise local_snapshot.SnapshotMissing("missing")

    monkeypatch.setattr(local_snapshot, "resolve_for_serving", resolve)
    _notion_ok(monkeypatch)

    routes = reachability.config_routes(cfg, wf_dir)
    needed = reachability.required(routes, cfg.modes.regulated_mode)
    doctor.check_secrets(needed)
    doctor.check_local_stack(cfg, wf_dir)
    doctor.check_claude_cli(cfg, reachability.CLAUDE_BINARY in needed)
    if not cfg.modes.regulated_mode:
        doctor.check_notion(bool(present["notion_token"]), cfg, routes)


@pytest.mark.parametrize("case", _CASES, ids=[c["name"] for c in _CASES])
def test_doctor_fails_on_exactly_the_checklist_gaps(case: dict, tmp_path, monkeypatch, capsys) -> None:
    _run_doctor_sections(case, tmp_path, monkeypatch)
    fails = [line for line in capsys.readouterr().out.splitlines() if line.startswith("[FAIL]")]
    named = sorted(gap for gap, marker in _FAIL_MARKERS.items() if any(marker in f for f in fails))
    assert named == sorted(case["gaps"]), fails
    # One FAIL per gap, and nothing else failing on a case the table calls clean.
    expected_lines = sum(
        len(reachability.notion_routes_without_database(
            reachability.config_routes(Config.model_validate({
                "summarization": {"backend": case["global_backend"]},
                "output": {"sinks": case["global_sinks"]},
                "modes": {"regulated_mode": case["regulated"]},
            }), tmp_path / "workflows"),
            case["regulated"], case["global_notion_database_id"],
        )) if g == "notion_database" else 1
        for g in case["gaps"]
    )
    assert len(fails) == expected_lines, fails


def test_local_mlx_with_a_folder_sink_has_no_fail_lines(tmp_path, monkeypatch, capsys) -> None:
    case = next(c for c in _CASES if c["name"] == "local_mlx_folder_fully_configured")
    _run_doctor_sections(case, tmp_path, monkeypatch)
    out = capsys.readouterr().out
    assert "[FAIL]" not in out
    assert "ANTHROPIC_API_KEY not set; not needed by any workflow" in out
    assert "NOTION_TOKEN not set; not needed by any workflow" in out


def test_a_per_workflow_openai_pin_is_one_fail(tmp_path, monkeypatch, capsys) -> None:
    case = next(c for c in _CASES if c["name"] == "per_workflow_openai_no_key")
    _run_doctor_sections(case, tmp_path, monkeypatch)
    fails = [line for line in capsys.readouterr().out.splitlines() if line.startswith("[FAIL]")]
    assert fails == ["[FAIL] OPENAI_API_KEY not in Keychain; set it in the daemon's Preferences or re-run scripts/install.sh"]


def test_openai_live_check_runs_for_a_per_workflow_pin(monkeypatch, capsys, tmp_path) -> None:
    wf_dir = tmp_path / "workflows"
    _write_workflows(wf_dir, [{"name": "Vendors", "backend": "openai", "nda": False, "sinks": []}])
    monkeypatch.setattr(workflows, "WORKFLOWS_DIR", wf_dir)
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    body = {"data": [{"id": "gpt-4o"}]}
    client = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(200, json=body)))
    monkeypatch.setattr(httpx, "get", client.get)
    cfg = Config.model_validate({"summarization": {"backend": "anthropic", "openai_model": "gpt-9"}})
    doctor.check_openai(True, cfg, needed=True)
    assert "[FAIL] configured model gpt-9 not found" in capsys.readouterr().out


def test_anthropic_ok_line_names_the_probe_model_not_the_configured_one(monkeypatch, capsys) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    client = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(200, json={})))
    monkeypatch.setattr(httpx, "post", client.post)
    monkeypatch.setattr(doctor, "check_anthropic_model", lambda _m, _k: "found")
    doctor.check_anthropic(True, Config(), needed=True)
    out = capsys.readouterr().out
    assert f"probed with {doctor.ANTHROPIC_DOCTOR_PROBE_MODEL}" in out
    assert "model access confirmed" not in out


def test_unused_services_skip_their_live_probe(monkeypatch, capsys) -> None:
    def boom(*_a, **_k):
        raise AssertionError("no live call for an unused service")

    monkeypatch.setattr(httpx, "post", boom)
    monkeypatch.setattr(httpx, "get", boom)
    cfg = Config.model_validate({"summarization": {"backend": "local"}, "output": {"sinks": ["filesystem"]}})
    doctor.check_anthropic(True, cfg, needed=False)
    doctor.check_notion(True, cfg, reachability.routes(cfg, []))
    out = capsys.readouterr().out
    assert "no workflow summarizes with Anthropic" in out
    assert "no workflow publishes to Notion" in out


def test_each_workflow_notion_database_is_probed(monkeypatch, capsys) -> None:
    monkeypatch.setenv("NOTION_TOKEN", "ntn-test")
    seen: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request.url.path)
        if request.url.path.endswith("/users/me"):
            return httpx.Response(200, json={"name": "t"})
        return httpx.Response(404 if "db-gone" in request.url.path else 200, json={"title": []})

    client = httpx.Client(transport=httpx.MockTransport(handler))
    monkeypatch.setattr(httpx, "get", client.get)
    cfg = Config.model_validate({"notion": {"database_id": "db-global"}})
    docs = [
        {"name": "A", "sinks": [{"type": "notion", "database_id": "db-a"}]},
        {"name": "B", "sinks": [{"type": "notion", "database_id": ""}]},
        {"name": "C", "sinks": [{"type": "notion", "database_id": "db-gone"}]},
    ]
    doctor.check_notion(True, cfg, reachability.routes(cfg, docs))
    out = capsys.readouterr().out
    assert [p.rsplit("/", 1)[-1] for p in seen if "/databases/" in p] == ["db-a", "db-global", "db-gone"]
    assert "[FAIL] database db-gone not found" in out


def test_folder_destinations_are_checked_without_writing(tmp_path, capsys) -> None:
    vault = tmp_path / "vault"
    vault.mkdir()
    out_dir = tmp_path / "published" / "new"
    cfg = Config.model_validate({
        "output": {"sinks": ["filesystem", "obsidian", "lan"]},
        "filesystem": {"output_dir": str(out_dir)},
        "obsidian": {"vault_path": str(vault)},
        "lan": {"mount_path": str(tmp_path / "Volumes" / "meetings")},
    })
    doctor.check_sink_destinations(cfg, reachability.routes(cfg, []))
    out = capsys.readouterr().out
    assert f"[ OK ] obsidian: {vault} exists and is writable" in out
    assert "it is created on the first publish" in out
    assert "[FAIL] lan:" in out and "is the share mounted?" in out
    assert not out_dir.exists()


def test_an_unwritable_folder_is_a_fail(tmp_path, capsys) -> None:
    locked = tmp_path / "locked"
    locked.mkdir()
    locked.chmod(0o500)
    try:
        cfg = Config.model_validate({
            "output": {"sinks": ["filesystem"]}, "filesystem": {"output_dir": str(locked)},
        })
        doctor.check_sink_destinations(cfg, reachability.routes(cfg, []))
        assert f"[FAIL] filesystem: {locked} is not writable" in capsys.readouterr().out
    finally:
        locked.chmod(0o700)
