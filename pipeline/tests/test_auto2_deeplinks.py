"""AUTO2: published-note citation links (`meetingpipe://open?stem=&t=`).

FEAT10 gave a cited point a plain ` [12:34]` tail; this turns it into a link that
opens the Library on that transcript row. Three things are worth pinning: the URL
spelling (Swift's `AutomationCommand.parse` reads it back, and the CI3 golden pins
the render byte-for-byte), which sinks link and which stay plain, and that a
summary with no anchors renders exactly as it did before.
"""
from __future__ import annotations

import json
from pathlib import Path

from mp.markdown import (
    deeplink_seconds,
    deeplink_stem,
    deeplink_url,
    render_summary_md,
)
from mp.publish_fs import FilesystemPublisher
from mp.publish_lan import LanPublisher
from mp.publish_notion import _build_blocks
from mp.publish_obsidian import ObsidianPublisher
from mp.schemas import ActionItem, Evidence, MeetingSummary

STEM = "20260722-140312"


def _cited() -> MeetingSummary:
    return MeetingSummary(
        title="Export sync",
        summary=["Agreed the export ships Friday.", "SOP revision is in flight."],
        decisions=["Ship the export on Friday."],
        actions=[
            ActionItem(
                task="Send revised SOP to QA", owner="Alice", due=None, confidence="high",
                evidence=[Evidence(quote="send the revised SOP to QA", t=40.75)],
            ),
        ],
        questions=["Is the QMS export green?"],
        attendees=["Alice"],
        detected_language="en",
        evidence={
            "summary": [[Evidence(quote="ship the export on Friday", t=12.5)], []],
            "decisions": [[Evidence(quote="ship the export on Friday", t=12.5)]],
            "questions": [[Evidence(quote="Is the QMS export green", t=754.0)]],
        },
    )


def _uncited() -> MeetingSummary:
    return MeetingSummary(
        title="Standup",
        summary=["Status round."],
        decisions=[],
        actions=[ActionItem(task="Ship it", owner="Bob", due=None, confidence="low")],
        questions=[],
        attendees=[],
        detected_language="en",
    )


# --------------------------------------------------------------------------
# URL spelling
# --------------------------------------------------------------------------

def test_seconds_keep_their_fraction_but_drop_trailing_zeros() -> None:
    # The fraction is load-bearing: Swift picks the last segment starting at or
    # before `t`, so a truncated anchor lands on the row before the cited one.
    assert deeplink_seconds(754.0) == "754"
    assert deeplink_seconds(12.5) == "12.5"
    assert deeplink_seconds(40.755) == "40.755"
    assert deeplink_seconds(0) == "0"
    # Clamped like `format_timestamp`, so the link and its label agree.
    assert deeplink_seconds(-3.0) == "0"


def test_stem_is_fully_percent_encoded() -> None:
    # Nothing but the unreserved set survives: the value has to be safe both as a
    # query parameter and inside a Markdown link target, where a bare `)` ends
    # the link early and a bare `&` would forge a second parameter.
    url = deeplink_url("a b&c)d", 1.0)
    assert url == "meetingpipe://open?stem=a%20b%26c%29d&t=1"
    assert deeplink_url("Експорт", 0)  == "meetingpipe://open?stem=%D0%95%D0%BA%D1%81%D0%BF%D0%BE%D1%80%D1%82&t=0"


def test_deeplink_stem_strips_the_summary_infix() -> None:
    assert deeplink_stem(None) is None
    assert deeplink_stem(Path("/r/20260722-140312.md")) == STEM
    assert deeplink_stem(Path("/r/20260722-140312.summary.md")) == STEM


# --------------------------------------------------------------------------
# render_summary_md
# --------------------------------------------------------------------------

def test_render_links_every_timestamp_when_given_a_stem() -> None:
    md = render_summary_md(_cited(), STEM)
    link12 = f"meetingpipe://open?stem={STEM}&t=12.5"
    assert f"- Agreed the export ships Friday. [0:12]({link12})" in md
    assert f"1. Ship the export on Friday. [0:12]({link12})" in md
    assert f"_(confidence: high)_ [0:40](meetingpipe://open?stem={STEM}&t=40.75)" in md
    assert f"- Is the QMS export green? [12:34](meetingpipe://open?stem={STEM}&t=754)" in md
    # An uncited point gains nothing.
    assert "- SOP revision is in flight.\n" in md


def test_linked_render_never_opens_with_a_double_bracket() -> None:
    # `[[` is an Obsidian wikilink, and Obsidian is the sink this ships for, so
    # the link syntax eats the brackets rather than nesting inside them.
    assert "[[" not in render_summary_md(_cited(), STEM)


def test_multiple_anchors_each_get_their_own_link() -> None:
    s = _cited()
    s.evidence["decisions"][0].append(Evidence(quote="Friday it is", t=3723.0))
    md = render_summary_md(s, STEM)
    assert (
        f"1. Ship the export on Friday. [0:12](meetingpipe://open?stem={STEM}&t=12.5), "
        f"[1:02:03](meetingpipe://open?stem={STEM}&t=3723)"
    ) in md


def test_without_a_stem_the_render_is_the_plain_feat10_one() -> None:
    md = render_summary_md(_cited())
    assert "- Agreed the export ships Friday. [0:12]" in md
    assert "meetingpipe://" not in md


def test_an_uncited_summary_renders_identically_with_and_without_a_stem() -> None:
    assert render_summary_md(_uncited(), STEM) == render_summary_md(_uncited())


# --------------------------------------------------------------------------
# Sinks: the Markdown-file three link, Notion does not
# --------------------------------------------------------------------------

def _transcript(tmp_path: Path) -> Path:
    p = tmp_path / f"{STEM}.md"
    p.write_text("# Transcript\n", encoding="utf-8")
    return p


def test_obsidian_note_carries_the_links(tmp_path: Path) -> None:
    pub = ObsidianPublisher(vault_path=tmp_path / "vault", folder="Meetings", attach_audio=False)
    res = pub.upsert(
        summary=_cited(),
        transcript_md=_transcript(tmp_path),
        sidecar_path=tmp_path / f"{STEM}.obsidian.json",
    )
    body = Path(res["page_id"]).read_text(encoding="utf-8")
    assert f"- Agreed the export ships Friday. [0:12](meetingpipe://open?stem={STEM}&t=12.5)" in body
    assert f"1. Ship the export on Friday. [0:12](meetingpipe://open?stem={STEM}&t=12.5)" in body
    assert f"_(confidence: high)_ [0:40](meetingpipe://open?stem={STEM}&t=40.75)" in body
    assert f"- Is the QMS export green? [12:34](meetingpipe://open?stem={STEM}&t=754)" in body


def test_obsidian_note_without_anchors_is_unchanged(tmp_path: Path) -> None:
    pub = ObsidianPublisher(vault_path=tmp_path / "vault", folder="Meetings", attach_audio=False)
    res = pub.upsert(
        summary=_uncited(),
        transcript_md=_transcript(tmp_path),
        sidecar_path=tmp_path / f"{STEM}.obsidian.json",
    )
    assert "meetingpipe://" not in Path(res["page_id"]).read_text(encoding="utf-8")


def test_filesystem_sink_summary_carries_the_links(tmp_path: Path) -> None:
    pub = FilesystemPublisher(output_dir=tmp_path / "out")
    res = pub.upsert(
        summary=_cited(),
        transcript_md=_transcript(tmp_path),
        sidecar_path=tmp_path / f"{STEM}.filesystem.json",
    )
    assert f"[0:12](meetingpipe://open?stem={STEM}&t=12.5)" in Path(res["page_id"]).read_text(
        encoding="utf-8"
    )


def test_lan_sink_summary_carries_the_links(tmp_path: Path) -> None:
    mount = tmp_path / "share"
    mount.mkdir()
    pub = LanPublisher(mount_path=mount)
    res = pub.upsert(
        summary=_cited(),
        transcript_md=_transcript(tmp_path),
        sidecar_path=tmp_path / f"{STEM}.lan.json",
    )
    assert f"[0:12](meetingpipe://open?stem={STEM}&t=12.5)" in Path(res["page_id"]).read_text(
        encoding="utf-8"
    )


def test_notion_blocks_stay_plain_text(tmp_path: Path) -> None:
    # Custom URL schemes are not reliably clickable in Notion rich text, so the
    # Notion body is deliberately untouched by AUTO2.
    blocks = _build_blocks(_cited(), transcript_md=None, include_transcript=False)
    assert "meetingpipe://" not in json.dumps(blocks)
