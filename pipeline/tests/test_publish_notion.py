"""Tests for Notion publishing — uses an httpx MockTransport so we don't hit
the real API. Covers create, idempotent update, and regulated-mode skip.
"""
from __future__ import annotations

import json
import os
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


def test_nda_workflow_skips_notion_and_arms_guard(tmp_path: Path, monkeypatch):
    # SEC review regression: an NDA workflow (sidecar workflow_nda_mode=true) must
    # skip the Notion publish on this legacy publish() path too, even when
    # NOTION_TOKEN is set, and the egress guard must arm on the resolved config as
    # the structural backstop. Covers `mp publish-notion` and `mp publish-from-paste`.
    from mp import egress_guard

    summary_path = _write_summary(tmp_path)
    stem = summary_path.name.removesuffix(".summary.json")
    (tmp_path / f"{stem}.meta.json").write_text(
        json.dumps({"workflow_nda_mode": True}), encoding="utf-8"
    )
    monkeypatch.setenv("NOTION_TOKEN", "ntn-must-not-be-used")

    result = publish(summary_path, cfg=_cfg())
    assert result["page_id"] is None, "NDA must skip the Notion publish"
    assert not (tmp_path / f"{stem}.notion.json").exists()
    assert egress_guard.is_armed(), "the egress guard must arm on the resolved NDA config"


def test_nda_workflow_scrubs_the_notion_token(tmp_path: Path, monkeypatch):
    """SEC13: arming does not just block the socket, it takes the credential away,
    so a regression in the skip above fails closed on a missing token rather than
    POSTing the summary."""
    summary_path = _write_summary(tmp_path)
    stem = summary_path.name.removesuffix(".summary.json")
    (tmp_path / f"{stem}.meta.json").write_text(
        json.dumps({"workflow_nda_mode": True}), encoding="utf-8"
    )
    monkeypatch.setenv("NOTION_TOKEN", "ntn-must-not-be-used")

    publish(summary_path, cfg=_cfg())
    assert "NOTION_TOKEN" not in os.environ


def test_explicit_publish_notion_ignores_the_configured_sink_list(tmp_path: Path, monkeypatch):
    """SEC13(c): the skip keys off `config.zero_egress`, not `effective_sinks`.
    `mp publish-notion <summary.json>` names its sink, so an `output.sinks` that
    omits notion (a routing preference, not an egress rule) must not silently
    turn the command into a no-op."""
    summary_path = _write_summary(tmp_path)
    monkeypatch.setenv("NOTION_TOKEN", "ntn-test")
    cfg = _cfg()
    cfg.output.sinks = ["obsidian"]

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "POST" and request.url.path == "/v1/pages":
            return httpx.Response(200, json={"id": "page-1", "url": "https://www.notion.so/page-1"})
        return httpx.Response(404, json={"message": "unexpected route"})

    _install_mock_transport(monkeypatch, handler)
    result = publish(summary_path, cfg=cfg)
    assert result["page_id"] == "page-1"


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


def test_update_paginates_existing_children(tmp_path: Path, monkeypatch):
    """If the previous run left >100 children, the GET must page through all
    of them. Without pagination we'd leak orphan blocks on every update.
    """
    summary_path = _write_summary(tmp_path)
    sidecar = tmp_path / "20260428-1200.notion.json"
    sidecar.write_text(
        json.dumps({"page_id": "page-big", "page_url": "x"}),
        encoding="utf-8",
    )
    monkeypatch.setenv("NOTION_TOKEN", "ntn-test")

    page1 = [f"blk-p1-{i:03d}" for i in range(100)]
    page2 = [f"blk-p2-{i:03d}" for i in range(50)]
    deleted_ids: list[str] = []
    deleted_lock = __import__("threading").Lock()

    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        params = dict(request.url.params)
        if request.method == "PATCH" and path == "/v1/pages/page-big":
            return httpx.Response(200, json={"id": "page-big", "url": "https://x"})
        if request.method == "GET" and path == "/v1/blocks/page-big/children":
            if params.get("start_cursor") == "cursor-2":
                return httpx.Response(
                    200,
                    json={"results": [{"id": b} for b in page2], "has_more": False},
                )
            return httpx.Response(
                200,
                json={
                    "results": [{"id": b} for b in page1],
                    "has_more": True,
                    "next_cursor": "cursor-2",
                },
            )
        if request.method == "DELETE" and path.startswith("/v1/blocks/blk-"):
            with deleted_lock:
                deleted_ids.append(path.rsplit("/", 1)[-1])
            return httpx.Response(200, json={"id": path.rsplit("/", 1)[-1]})
        if request.method == "PATCH" and path == "/v1/blocks/page-big/children":
            return httpx.Response(200, json={})
        return httpx.Response(404, json={"message": f"unexpected {request.method} {path}"})

    _install_mock_transport(monkeypatch, handler)
    publish(summary_path, cfg=_cfg())

    assert sorted(deleted_ids) == sorted(page1 + page2)
    assert len(deleted_ids) == 150


def test_missing_database_id_raises(tmp_path: Path, monkeypatch):
    summary_path = _write_summary(tmp_path)
    monkeypatch.setenv("NOTION_TOKEN", "ntn-test")
    cfg = _cfg(database_id="")
    with pytest.raises(pub_mod.NotionError):
        publish(summary_path, cfg=cfg)


def test_meta_sidecar_overrides_llm_title(tmp_path: Path, monkeypatch):
    """When the daemon writes a `<stem>.meta.json` with `meeting_title`,
    that name should win over the LLM-derived `summary.title` in the
    Notion page properties — the whole point of the meta sidecar.
    """
    summary_path = _write_summary(tmp_path)
    meta = tmp_path / "20260428-1200.meta.json"
    meta.write_text(
        json.dumps(
            {
                "meeting_title": "Sprint Retrospective",
                "source_bundle_id": "com.google.Chrome",
                "source_display_name": "Google Chrome",
                "source_kind": "browser",
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setenv("NOTION_TOKEN", "ntn-test")

    captured: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "POST" and request.url.path == "/v1/pages":
            captured.append(json.loads(request.content))
            return httpx.Response(
                200,
                json={"id": "page-meta-1", "url": "https://www.notion.so/page-meta-1"},
            )
        return httpx.Response(404, json={"message": "unexpected route"})

    _install_mock_transport(monkeypatch, handler)
    publish(summary_path, cfg=_cfg())

    assert len(captured) == 1
    title_runs = captured[0]["properties"]["Name"]["title"]
    assert title_runs[0]["text"]["content"] == "Sprint Retrospective"


def test_meta_sidecar_blank_title_falls_back(tmp_path: Path, monkeypatch):
    """An empty or whitespace `meeting_title` must not clobber the
    LLM-derived title; the sidecar exists for many other reasons.
    """
    summary_path = _write_summary(tmp_path)
    meta = tmp_path / "20260428-1200.meta.json"
    meta.write_text(
        json.dumps({"meeting_title": "  ", "source_bundle_id": "us.zoom.xos"}),
        encoding="utf-8",
    )
    monkeypatch.setenv("NOTION_TOKEN", "ntn-test")

    captured: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "POST" and request.url.path == "/v1/pages":
            captured.append(json.loads(request.content))
            return httpx.Response(
                200, json={"id": "page-x", "url": "https://www.notion.so/page-x"}
            )
        return httpx.Response(404, json={"message": "unexpected"})

    _install_mock_transport(monkeypatch, handler)
    publish(summary_path, cfg=_cfg())

    title_runs = captured[0]["properties"]["Name"]["title"]
    assert title_runs[0]["text"]["content"] == "Test meeting"  # LLM-derived


def test_post_pages_does_not_retry_on_502(tmp_path: Path, monkeypatch):
    """Regression: pre-2026-05-11 the @retry on _request would retry
    POST /v1/pages after a 502. Notion's edge sometimes returns 502
    AFTER the backend has already committed the write, so retrying
    creates a duplicate page in the user's database. We must fail
    loudly on the first 502 instead.

    Trace from the live incident:
        10:56:19  POST /v1/pages -> 502 Bad Gateway   (page already saved)
        10:56:21  POST /v1/pages -> 200 OK            (second page!)
    User opens Notion and sees two identical pages."""
    summary_path = _write_summary(tmp_path)
    monkeypatch.setenv("NOTION_TOKEN", "ntn-test")

    post_calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "POST" and request.url.path == "/v1/pages":
            post_calls.append(request.url.path)
            # Always 502, never recovers; if retry-on-POST is on this
            # will fire ~4 times and Notion-equivalent would create
            # ~4 duplicates. The assertion below catches that.
            return httpx.Response(502, text="Bad Gateway")
        return httpx.Response(404, json={"message": "unexpected"})

    _install_mock_transport(monkeypatch, handler)

    with pytest.raises(Exception):
        publish(summary_path, cfg=_cfg())

    assert len(post_calls) == 1, (
        f"POST /v1/pages must NOT retry on 5xx (would create duplicate pages); "
        f"got {len(post_calls)} calls"
    )


def test_post_pages_does_not_retry_on_transport_error(tmp_path: Path, monkeypatch):
    """Companion to the 502 test: a network blip mid-POST is also
    non-recoverable for a non-idempotent verb. The first request may
    have reached Notion's backend; retrying would re-create."""
    summary_path = _write_summary(tmp_path)
    monkeypatch.setenv("NOTION_TOKEN", "ntn-test")

    post_calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "POST" and request.url.path == "/v1/pages":
            post_calls.append(request.url.path)
            raise httpx.ConnectTimeout("simulated network blip")
        return httpx.Response(404, json={"message": "unexpected"})

    _install_mock_transport(monkeypatch, handler)

    with pytest.raises(Exception):
        publish(summary_path, cfg=_cfg())

    assert len(post_calls) == 1, (
        f"POST /v1/pages must NOT retry on TransportError; got {len(post_calls)}"
    )


def test_patch_pages_still_retries_on_502(tmp_path: Path, monkeypatch):
    """The retry policy split must NOT regress idempotent operations.
    PATCH /v1/pages/{id} (property update) is idempotent and should
    still retry through transient 5xx so the user does not see flaky
    failures on update."""
    summary_path = _write_summary(tmp_path)
    # Drop a sidecar so publish() takes the update path.
    sidecar = tmp_path / "20260428-1200.notion.json"
    sidecar.write_text(json.dumps({"page_id": "page-existing-1", "page_url": "u"}),
                       encoding="utf-8")
    monkeypatch.setenv("NOTION_TOKEN", "ntn-test")

    patch_pages_calls: list[int] = []

    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if request.method == "PATCH" and path == "/v1/pages/page-existing-1":
            patch_pages_calls.append(1)
            # 502 the first attempt, succeed the second so the retry
            # wrapper has a chance to demonstrate it kicked in.
            if len(patch_pages_calls) == 1:
                return httpx.Response(502, text="Bad Gateway")
            return httpx.Response(200, json={"id": "page-existing-1", "url": "u"})
        if request.method == "GET" and path == "/v1/blocks/page-existing-1/children":
            return httpx.Response(200, json={"results": [], "has_more": False})
        if request.method == "PATCH" and path == "/v1/blocks/page-existing-1/children":
            return httpx.Response(200, json={})
        return httpx.Response(404, json={"message": f"unexpected {request.method} {path}"})

    _install_mock_transport(monkeypatch, handler)

    publish(summary_path, cfg=_cfg())

    assert len(patch_pages_calls) >= 2, (
        "PATCH /v1/pages/{id} should retry on 502; "
        f"saw {len(patch_pages_calls)} calls"
    )
