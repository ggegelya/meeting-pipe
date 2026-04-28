"""Tests for Notion publishing — uses an httpx MockTransport so we don't hit
the real API. Covers create, idempotent update, and regulated-mode skip.
"""
from __future__ import annotations

import json
from pathlib import Path

import httpx
import pytest

import mp.publish_notion as pub_mod
from mp.config import Config
from mp.publish_notion import publish
from mp.schemas import ActionItem, MeetingSummary


def _summary() -> MeetingSummary:
    return MeetingSummary(
        title="Test meeting",
        summary=["Bullet one", "Bullet two"],
        decisions=["We will ship next week."],
        actions=[
            ActionItem(task="Send doc", owner="Alice", due="2026-05-01", confidence="high"),
        ],
        questions=["Should we cap transcripts?"],
        attendees=["Alice", "Bob"],
        detected_language="en",
    )


def _write_summary(tmp_path: Path) -> Path:
    s = _summary()
    p = tmp_path / "20260428-1200.summary.json"
    p.write_text(s.model_dump_json(), encoding="utf-8")
    return p


def _cfg(database_id: str = "db-abc", regulated: bool = False) -> Config:
    cfg = Config()
    cfg.notion.database_id = database_id
    cfg.modes.regulated_mode = regulated
    return cfg


def _install_mock_transport(monkeypatch, handler):
    """Monkeypatch httpx.Client to use a MockTransport routing to `handler`."""
    real_init = httpx.Client.__init__

    def patched_init(self, *args, **kwargs):
        kwargs["transport"] = httpx.MockTransport(handler)
        real_init(self, *args, **kwargs)

    monkeypatch.setattr(httpx.Client, "__init__", patched_init)


def test_creates_page_when_no_sidecar(tmp_path: Path, monkeypatch):
    summary_path = _write_summary(tmp_path)
    monkeypatch.setenv("NOTION_TOKEN", "ntn-test")

    calls: list[tuple[str, str]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append((request.method, request.url.path))
        if request.method == "POST" and request.url.path == "/v1/pages":
            return httpx.Response(
                200,
                json={
                    "id": "page-new-123",
                    "url": "https://www.notion.so/page-new-123",
                },
            )
        return httpx.Response(404, json={"message": "unexpected route"})

    _install_mock_transport(monkeypatch, handler)

    result = publish(summary_path, cfg=_cfg())

    assert result["page_id"] == "page-new-123"
    assert not result["idempotent"]
    assert calls == [("POST", "/v1/pages")]

    sidecar = tmp_path / "20260428-1200.notion.json"
    assert sidecar.exists()
    persisted = json.loads(sidecar.read_text(encoding="utf-8"))
    assert persisted["page_id"] == "page-new-123"


def test_updates_page_when_sidecar_exists(tmp_path: Path, monkeypatch):
    summary_path = _write_summary(tmp_path)
    sidecar = tmp_path / "20260428-1200.notion.json"
    sidecar.write_text(
        json.dumps({"page_id": "page-existing-999", "page_url": "x"}),
        encoding="utf-8",
    )
    monkeypatch.setenv("NOTION_TOKEN", "ntn-test")

    routes: list[tuple[str, str]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        routes.append((request.method, request.url.path))
        path = request.url.path
        if request.method == "PATCH" and path == "/v1/pages/page-existing-999":
            return httpx.Response(200, json={"id": "page-existing-999", "url": "https://notion/x"})
        if request.method == "GET" and path == "/v1/blocks/page-existing-999/children":
            return httpx.Response(
                200,
                json={"results": [{"id": "blk-1"}, {"id": "blk-2"}]},
            )
        if request.method == "DELETE" and path.startswith("/v1/blocks/blk-"):
            return httpx.Response(200, json={"id": path.rsplit("/", 1)[-1]})
        if request.method == "PATCH" and path == "/v1/blocks/page-existing-999/children":
            return httpx.Response(200, json={})
        return httpx.Response(404, json={"message": f"unexpected {request.method} {path}"})

    _install_mock_transport(monkeypatch, handler)

    result = publish(summary_path, cfg=_cfg())
    assert result["idempotent"]
    assert result["page_id"] == "page-existing-999"

    methods = [m for m, _ in routes]
    assert methods[0] == "PATCH"  # property update first
    assert "DELETE" in methods    # old children wiped
    # POSTs only happen when creating, never on idempotent updates.
    assert "POST" not in methods


def test_regulated_mode_skips_notion(tmp_path: Path, monkeypatch):
    summary_path = _write_summary(tmp_path)
    # Important: regulated_mode must skip even if NOTION_TOKEN is unset.
    monkeypatch.delenv("NOTION_TOKEN", raising=False)

    result = publish(summary_path, cfg=_cfg(regulated=True))
    assert result["regulated"] is True
    assert result["page_id"] is None
    # No sidecar should be written since we never published.
    assert not (tmp_path / "20260428-1200.notion.json").exists()


def test_update_deletes_all_children_in_parallel(tmp_path: Path, monkeypatch):
    """The body-replace path must DELETE every existing child.

    With 50 blocks under a thread pool, sequential and parallel both produce
    50 DELETEs — what we're really testing is correctness under concurrency:
    no skipped IDs, no double-deletes, all unique IDs accounted for.
    """
    summary_path = _write_summary(tmp_path)
    sidecar = tmp_path / "20260428-1200.notion.json"
    sidecar.write_text(
        json.dumps({"page_id": "page-existing", "page_url": "x"}),
        encoding="utf-8",
    )
    monkeypatch.setenv("NOTION_TOKEN", "ntn-test")

    block_ids = [f"blk-{i:03d}" for i in range(50)]
    deleted_ids: list[str] = []
    deleted_lock = __import__("threading").Lock()

    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if request.method == "PATCH" and path == "/v1/pages/page-existing":
            return httpx.Response(200, json={"id": "page-existing", "url": "https://x"})
        if request.method == "GET" and path == "/v1/blocks/page-existing/children":
            return httpx.Response(
                200,
                json={"results": [{"id": bid} for bid in block_ids]},
            )
        if request.method == "DELETE" and path.startswith("/v1/blocks/blk-"):
            with deleted_lock:
                deleted_ids.append(path.rsplit("/", 1)[-1])
            return httpx.Response(200, json={"id": path.rsplit("/", 1)[-1]})
        if request.method == "PATCH" and path == "/v1/blocks/page-existing/children":
            return httpx.Response(200, json={})
        return httpx.Response(404, json={"message": f"unexpected {request.method} {path}"})

    _install_mock_transport(monkeypatch, handler)

    publish(summary_path, cfg=_cfg())

    # Each block ID gets exactly one DELETE.
    assert sorted(deleted_ids) == sorted(block_ids)
    assert len(deleted_ids) == 50


def test_missing_database_id_raises(tmp_path: Path, monkeypatch):
    summary_path = _write_summary(tmp_path)
    monkeypatch.setenv("NOTION_TOKEN", "ntn-test")
    cfg = _cfg(database_id="")
    with pytest.raises(pub_mod.NotionError):
        publish(summary_path, cfg=cfg)
