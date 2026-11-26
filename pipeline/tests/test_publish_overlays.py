"""PIPE51: every sink publishes the transcript the Library shows.

The Library's speaker names and line edits live only in
`<stem>.speaker_labels.json` and `<stem>.transcript_corrections.json`; `<stem>.md`
keeps the raw labels and raw text on purpose (FEAT3-UNDO). The sinks used to read
that raw file, so a Republish carried the old words and the raw label. The overlays
here are built from the golden fixture cases the Swift suite shares, rather than
restating the resolution.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import httpx
import pytest

from mp import transcript_corrections as tc
from mp.config import Config
from mp.publish_fs import FilesystemPublisher
from mp.publish_lan import LanPublisher
from mp.publish_notion import NotionRestPublisher, publish
from mp.publish_obsidian import ObsidianPublisher
from mp.publish_router import fanout, publish_failed
from mp.schemas import ActionItem, MeetingSummary
from mp.summarize import OverlayUnreadable, refuse_unreadable_overlays

FIXTURES = Path(__file__).resolve().parents[2] / "daemon" / "Tests" / "MeetingPipeTests" / "Fixtures"
STEM = "20260506-1500"
RAW = "Raw one"
EDITED = "Edited one"


def _golden(name: str, case: str) -> dict:
    cases = json.loads((FIXTURES / name).read_text(encoding="utf-8"))["cases"]
    return next(c for c in cases if c["name"] == case)


def _summary() -> MeetingSummary:
    return MeetingSummary(
        title="Standup", summary=["a"], decisions=[],
        actions=[ActionItem(task="Reply", owner="Bob", due=None, confidence="medium")],
        questions=[], attendees=["Bob"], detected_language="en",
    )


def _meeting(tmp_path: Path, *, overlays: bool) -> Path:
    """A meeting dir whose <stem>.md is the raw render. With `overlays`, the speaker
    sidecar is the golden `names_a_cluster` case (THEM-A is Alice) and the
    corrections sidecar edits segment 0, in the golden `single_edit` shape."""
    from mp.markdown import render_markdown

    data = {"language": "en", "backend": "fluidaudio", "segments": [
        {"start": 0.0, "end": 1.0, "text": RAW, "speaker": "THEM-A"},
        {"start": 1.0, "end": 2.0, "text": "Raw two", "speaker": "THEM-B"},
    ]}
    (tmp_path / f"{STEM}.json").write_text(json.dumps(data), encoding="utf-8")
    md = tmp_path / f"{STEM}.md"
    md.write_text(render_markdown(data), encoding="utf-8")
    if overlays:
        (tmp_path / f"{STEM}.speaker_labels.json").write_text(
            json.dumps(_golden("speaker-overlay-golden.json", "names_a_cluster")["sidecar"]),
            encoding="utf-8")
        corr = _golden("transcript-corrections-golden.json", "single_edit")["corrections"]
        corr = {**corr, "segments": [{"index": 0, "original_text": RAW, "edited_text": EDITED}]}
        (tmp_path / f"{STEM}.transcript_corrections.json").write_text(json.dumps(corr), encoding="utf-8")
    return md


def _write_summary(tmp_path: Path) -> Path:
    p = tmp_path / f"{STEM}.summary.json"
    p.write_text(_summary().model_dump_json(), encoding="utf-8")
    return p


# ----- publish_text ---------------------------------------------------------

def test_publish_text_is_the_raw_file_without_overlays(tmp_path: Path) -> None:
    md = _meeting(tmp_path, overlays=False)
    assert tc.publish_text(md) == md.read_text(encoding="utf-8")


def test_publish_text_applies_both_overlays(tmp_path: Path) -> None:
    text = tc.publish_text(_meeting(tmp_path, overlays=True))
    assert "Alice" in text and EDITED in text
    assert "THEM-A" not in text and RAW not in text
    assert "THEM-B" in text  # the unnamed cluster is untouched


def test_publish_text_missing_file_is_empty(tmp_path: Path) -> None:
    assert tc.publish_text(tmp_path / "nope.md") == ""
    assert tc.publish_text(None) == ""


@pytest.mark.parametrize("suffix", [".speaker_labels.json", ".transcript_corrections.json"])
def test_publish_text_refuses_an_overlay_that_cannot_be_read(tmp_path: Path, suffix: str) -> None:
    # Amendment 2026-11-21: the raw fallback sent lines the owner had corrected in their
    # uncorrected form, while summarize has refused the same file since STOR9.
    md = _meeting(tmp_path, overlays=False)
    (tmp_path / f"{STEM}{suffix}").write_text("{not json", encoding="utf-8")
    with pytest.raises(OverlayUnreadable, match="Nothing was published") as refused:
        tc.publish_text(md)
    assert f"{STEM}{suffix}" in str(refused.value)


def test_an_unreadable_markers_file_does_not_stop_a_publish(tmp_path: Path) -> None:
    # Flagged moments feed the summary, which already exists; no sink reads the markers file.
    md = _meeting(tmp_path, overlays=False)
    (tmp_path / f"{STEM}.markers.json").write_text("{not json", encoding="utf-8")
    assert tc.publish_text(md) == md.read_text(encoding="utf-8")


def test_summarize_and_publish_name_the_same_file(tmp_path: Path) -> None:
    md = _meeting(tmp_path, overlays=False)
    (tmp_path / f"{STEM}.transcript_corrections.json").write_text("[1]", encoding="utf-8")
    with pytest.raises(OverlayUnreadable) as published:
        tc.publish_text(md)
    with pytest.raises(OverlayUnreadable) as summarized:
        refuse_unreadable_overlays(md)
    head = "This meeting's transcript corrections file can't be read"
    for message in (str(published.value), str(summarized.value)):
        assert message.startswith(head)
        assert f"fix or remove {STEM}.transcript_corrections.json" in message
    assert "Nothing was summarized" in str(summarized.value)


# ----- each sink ------------------------------------------------------------

def _assert_overlaid(text: str) -> None:
    assert "Alice" in text and EDITED in text
    assert "THEM-A" not in text and RAW not in text


def test_filesystem_sink_publishes_the_overlaid_transcript(tmp_path: Path) -> None:
    md = _meeting(tmp_path, overlays=True)
    out = tmp_path / "out"
    FilesystemPublisher(output_dir=out).upsert(
        summary=_summary(), transcript_md=md, sidecar_path=tmp_path / f"{STEM}.filesystem.json")
    _assert_overlaid((out / f"{STEM}.transcript.md").read_text(encoding="utf-8"))


def test_filesystem_sink_without_overlays_is_byte_identical(tmp_path: Path) -> None:
    md = _meeting(tmp_path, overlays=False)
    out = tmp_path / "out"
    FilesystemPublisher(output_dir=out).upsert(
        summary=_summary(), transcript_md=md, sidecar_path=tmp_path / f"{STEM}.filesystem.json")
    assert (out / f"{STEM}.transcript.md").read_text(encoding="utf-8") == md.read_text(encoding="utf-8")


def test_a_correction_added_after_a_publish_republishes_instead_of_skipping(tmp_path: Path) -> None:
    md = _meeting(tmp_path, overlays=False)
    out = tmp_path / "out"
    sidecar = tmp_path / f"{STEM}.filesystem.json"
    pub = FilesystemPublisher(output_dir=out)
    assert pub.upsert(summary=_summary(), transcript_md=md, sidecar_path=sidecar)["idempotent"] is False
    assert pub.upsert(summary=_summary(), transcript_md=md, sidecar_path=sidecar)["idempotent"] is True

    (tmp_path / f"{STEM}.transcript_corrections.json").write_text(json.dumps({
        "schema_version": 1,
        "segments": [{"index": 0, "original_text": RAW, "edited_text": EDITED}]}), encoding="utf-8")
    res = pub.upsert(summary=_summary(), transcript_md=md, sidecar_path=sidecar)
    assert res["idempotent"] is False
    assert EDITED in (out / f"{STEM}.transcript.md").read_text(encoding="utf-8")


def test_lan_sink_publishes_the_overlaid_transcript(tmp_path: Path) -> None:
    md = _meeting(tmp_path, overlays=True)
    share = tmp_path / "share"
    share.mkdir()
    LanPublisher(mount_path=share, host="").upsert(
        summary=_summary(), transcript_md=md, sidecar_path=tmp_path / f"{STEM}.lan.json")
    _assert_overlaid((share / f"{STEM}.transcript.md").read_text(encoding="utf-8"))


def test_obsidian_sink_publishes_the_overlaid_transcript(tmp_path: Path) -> None:
    md = _meeting(tmp_path, overlays=True)
    res = ObsidianPublisher(vault_path=tmp_path / "vault", folder="Meetings", attach_audio=False).upsert(
        summary=_summary(), transcript_md=md, sidecar_path=tmp_path / f"{STEM}.obsidian.json")
    note = Path(res["page_id"]).read_text(encoding="utf-8")
    _assert_overlaid(note.split("## Transcript", 1)[1])


def test_obsidian_sink_without_overlays_keeps_the_raw_transcript(tmp_path: Path) -> None:
    md = _meeting(tmp_path, overlays=False)
    res = ObsidianPublisher(vault_path=tmp_path / "vault", folder="Meetings", attach_audio=False).upsert(
        summary=_summary(), transcript_md=md, sidecar_path=tmp_path / f"{STEM}.obsidian.json")
    note = Path(res["page_id"]).read_text(encoding="utf-8")
    assert "## Transcript\n\n" + md.read_text(encoding="utf-8") in note


def _notion_cfg() -> Config:
    cfg = Config()
    cfg.notion.database_id = "db-abc"
    return cfg


def _capture_notion(monkeypatch) -> list[dict[str, Any]]:
    bodies: list[dict[str, Any]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "POST" and request.url.path == "/v1/pages":
            bodies.append(json.loads(request.content))
            return httpx.Response(200, json={"id": "p1", "url": "https://notion.so/p1"})
        return httpx.Response(404, json={"message": "unexpected"})

    real_init = httpx.Client.__init__

    def patched(self, *a, **kw):
        kw["transport"] = httpx.MockTransport(handler)
        real_init(self, *a, **kw)

    monkeypatch.setattr(httpx.Client, "__init__", patched)
    return bodies


def test_notion_sink_publishes_the_overlaid_transcript(tmp_path: Path, monkeypatch) -> None:
    md = _meeting(tmp_path, overlays=True)
    summary_json = _write_summary(tmp_path)
    monkeypatch.setenv("NOTION_TOKEN", "ntn-test")
    bodies = _capture_notion(monkeypatch)
    publish(summary_json, cfg=_notion_cfg(), transcript_md=md)
    _assert_overlaid(json.dumps(bodies[0]["children"]))


def test_notion_sink_without_overlays_sends_the_raw_transcript(tmp_path: Path, monkeypatch) -> None:
    md = _meeting(tmp_path, overlays=False)
    summary_json = _write_summary(tmp_path)
    monkeypatch.setenv("NOTION_TOKEN", "ntn-test")
    bodies = _capture_notion(monkeypatch)
    publish(summary_json, cfg=_notion_cfg(), transcript_md=md)
    sent = json.dumps(bodies[0]["children"])
    assert "THEM-A" in sent and RAW in sent and "Alice" not in sent


# ----- the router -----------------------------------------------------------

class _Spy:
    def __init__(self, name: str) -> None:
        self.name = name
        self.texts: list[str | None] = []

    def upsert(self, *, summary, transcript_md, sidecar_path, transcript_text=None) -> dict[str, Any]:
        self.texts.append(transcript_text)
        return {"page_id": self.name, "page_url": "u", "idempotent": False}


def test_fanout_resolves_the_overlays_once_and_hands_every_sink_the_same_text(
    tmp_path: Path, monkeypatch
) -> None:
    md = _meeting(tmp_path, overlays=True)
    summary_json = _write_summary(tmp_path)
    calls = {"n": 0}
    real = tc.overlaid_markdown

    def counting(path):
        calls["n"] += 1
        return real(path)

    monkeypatch.setattr(tc, "overlaid_markdown", counting)
    a, b = _Spy("a"), _Spy("b")
    fanout(summary_json=summary_json, cfg=Config(), transcript_md=md, publishers=[a, b])
    assert calls["n"] == 1
    assert a.texts == b.texts and a.texts[0] is not None
    _assert_overlaid(a.texts[0])


def test_notion_publisher_class_accepts_the_new_keyword() -> None:
    import inspect
    assert "transcript_text" in inspect.signature(NotionRestPublisher.upsert).parameters


def test_fanout_refuses_an_unreadable_overlay_before_any_sink(tmp_path: Path, monkeypatch) -> None:
    # Amendment 2026-11-21: a publish-only run (Republish, a publish-stage Retry, `mp publish`)
    # never reaches summarize, so the refusal has to happen here, and it is recorded as a failed
    # publish (exit 3, Retry republishes) rather than escaping as a crash.
    from mp import events

    rows: list[tuple[str, str, dict[str, Any]]] = []
    monkeypatch.setattr(events, "emit", lambda cat, action, **attrs: rows.append((cat, action, attrs)))
    md = _meeting(tmp_path, overlays=True)
    (tmp_path / f"{STEM}.transcript_corrections.json").write_text("{not json", encoding="utf-8")
    summary_json = _write_summary(tmp_path)
    a, b = _Spy("a"), _Spy("b")

    result = fanout(summary_json=summary_json, cfg=Config(), transcript_md=md, publishers=[a, b])

    assert a.texts == [] and b.texts == []
    assert publish_failed(result)
    sidecar = json.loads((tmp_path / f"{STEM}.publish.json").read_text(encoding="utf-8"))
    assert sidecar["state"] == "none"
    for name in ("a", "b"):
        sink = sidecar["sinks"][name]
        assert sink["ok"] is False
        assert f"{STEM}.transcript_corrections.json" in sink["error"]
        assert sink["failure"]["cause"] == "overlay_unreadable"
        assert sink["failure"]["operation"] == "publish"
    failed = [attrs for _, action, attrs in rows if action == "sink_failed"]
    assert [r["sink"] for r in failed] == ["a", "b"]
    assert all(r["error_type"] == "OverlayUnreadable" and r["cause"] == "overlay_unreadable" for r in failed)
    # OBS3: no row carries the refusal's text.
    assert not any("can't be read" in json.dumps(attrs) for _, _, attrs in rows)
