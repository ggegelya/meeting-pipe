"""SEC28: model-written free text is inert in every Markdown sink."""
from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from mp.markdown import render_summary_md
from mp.prompt_safety import clean_language, clean_text
from mp.publish_notion import apply_meeting_title
from mp.publish_obsidian import ObsidianPublisher, _yaml_quoted
from mp.schemas import MeetingSummary

IMG = "![](https://attacker.example/t.png?q=1)"
HTML = "<img src=https://attacker.example/p.png onerror=alert(1)>"
FENCE = "ok\n```dataviewjs\ndv.view('x')\n```"
TILDE = "~~~dataviewjs\ndv.view('x')"
LINK = "[click](javascript:alert(1))"


# ----- clean_text -----


@pytest.mark.parametrize("raw,expected", [
    ("![](x)", "(`x`)"),
    ("![alt](https://a.example/i.png)", "alt (`https://a.example/i.png`)"),
    ("<img src=x>hello", "hello"),
    ("[a](javascript:x)", "a (`javascript:x`)"),
    ("[a](https://x)", "a (`https://x`)"),
    ("one\ntwo\r\nthree\tfour", "one two three four"),
    ("plain text stays", "plain text stays"),
    ("Ship v2 (by Friday) [urgent]", "Ship v2 (by Friday) [urgent]"),
    ("![a][ref]", "!\\[a][ref]"),
])
def test_clean_text_table(raw: str, expected: str) -> None:
    assert clean_text(raw) == expected


@pytest.mark.parametrize("raw", [IMG, HTML, FENCE, LINK, "<script>x</script>", "a <b>bold</b> c",
                                 "x<y then", "[a](https://x) and ![b](https://y)", "`$= dv.x()`"])
def test_clean_text_leaves_nothing_a_renderer_can_act_on(raw: str) -> None:
    out = clean_text(raw)
    assert "![" not in out.replace("!\\[", "")
    assert "](" not in out
    assert not re.search(r"<\s*[/!A-Za-z]", out)
    assert "\n" not in out and "\r" not in out
    assert clean_text(out) == out                          # idempotent: a stored summary re-validates unchanged


def test_a_backtick_in_a_link_target_cannot_break_out_of_the_code_span() -> None:
    out = clean_text("[a](https://x`![](https://evil/p.png))")
    assert "](" not in out and "![" not in out.replace("!\\[", "")


@pytest.mark.parametrize("raw,expected", [
    ("en", "en"), ("uk", "uk"), ("UK", "uk"), ("pt-BR", "pt-BR"), ("zh-Hans", "zh-Hans"),
    ("en\ncssclasses: x", "en"), ("english", "en"), ("", "en"), ("e", "en"),
    ("en\ntags: [pwned]", "en"),
])
def test_clean_language(raw: str, expected: str) -> None:
    assert clean_language(raw) == expected


# ----- the schema is where every backend and reader inherits it -----


def _hostile() -> dict:
    return {
        "title": f"Sync {IMG}",
        "summary": [f"Point {IMG}", FENCE, HTML, TILDE, "```js\nx"],
        "decisions": [f"Decide {HTML}", LINK],
        "actions": [{"task": f"Do it {IMG}", "owner": "Alice"}, {"task": FENCE}],
        "questions": [f"Why {IMG}?", FENCE],
        "attendees": ["Alice"],
        "detected_language": "en\ncssclasses: evil\ntags: [pwned]",
        "extra_sections": [{"name": f"Risks {IMG}", "content": [IMG, HTML, FENCE]}],
    }


def _all_text(s: MeetingSummary) -> list[str]:
    out = [s.title, *s.summary, *s.decisions, *s.questions, *(a.task for a in s.actions)]
    for sec in s.extra_sections:
        out += [sec.name, *sec.content]
    return out


def test_a_hostile_summary_round_trips_inert() -> None:
    s = MeetingSummary.model_validate(_hostile())
    for text in _all_text(s):
        assert "![" not in text.replace("!\\[", ""), text
        assert "](" not in text and "\n" not in text, text
        assert not re.search(r"<\s*[/!A-Za-z]", text), text
    assert s.detected_language == "en"
    # Stored and reloaded: nothing changes, so a digest/MCP read of old files is stable.
    again = MeetingSummary.model_validate(json.loads(s.model_dump_json()))
    assert again == s


def test_a_leading_fence_marker_is_dropped_but_the_words_stay() -> None:
    assert clean_text("~~~dataviewjs\ndv.view('x')") == "dataviewjs dv.view('x')"
    assert clean_text("```js\nx") == "js x"
    assert clean_text("use ~~~ sparingly") == "use ~~~ sparingly"      # mid-line is inert


def test_the_readable_part_of_a_scrubbed_field_survives() -> None:
    s = MeetingSummary.model_validate({**_hostile(), "summary": ["Budget is [here](https://wiki/x)"]})
    assert s.summary == ["Budget is here (`https://wiki/x`)"]


# ----- both renderers -----


def _no_live_content(rendered: str) -> None:
    assert "attacker.example/t.png" not in rendered.replace("(`https://attacker.example/t.png?q=1`)", "")
    assert not re.search(r"!\[[^\]]*\]\(", rendered)
    assert "<img" not in rendered and "<script" not in rendered
    # No line may open a code fence (a bullet's content starts a line, so `- ~~~js` would).
    assert not re.search(r"(?m)^\s*(?:[-*]\s+|\d+\.\s+)?(?:```|~~~)", rendered)


def test_render_summary_md_is_inert_for_the_hostile_payload() -> None:
    _no_live_content(render_summary_md(MeetingSummary.model_validate(_hostile())))


def test_the_obsidian_note_is_inert_and_has_no_extra_front_matter_key(tmp_path: Path) -> None:
    pub = ObsidianPublisher(vault_path=tmp_path / "vault", attach_audio=False)
    transcript = tmp_path / "20260506-1500.md"
    transcript.write_text("# Transcript\n", encoding="utf-8")
    res = pub.upsert(
        summary=MeetingSummary.model_validate(_hostile()),
        transcript_md=transcript, sidecar_path=tmp_path / "s.json",
    )
    note = Path(res["page_id"]).read_text(encoding="utf-8")
    _no_live_content(note)
    front = note.split("---")[1]
    keys = [line.split(":")[0] for line in front.strip().splitlines() if re.match(r"^[A-Za-z_]+:", line)]
    assert "cssclasses" not in keys and "tags" in keys
    assert "language: en\n" in front


def test_a_hostile_meeting_title_is_scrubbed_before_it_reaches_any_sink(tmp_path: Path) -> None:
    """No model involved: a Zoom host sets the topic, the daemon stores it in
    `meta.json`, and `model_copy` would skip the schema's validators."""
    summary_json = tmp_path / "x.summary.json"
    summary_json.write_text("{}", encoding="utf-8")
    (tmp_path / "x.meta.json").write_text(
        json.dumps({"meeting_title": f"Weekly {IMG} <b>sync</b>"}), encoding="utf-8"
    )
    s = MeetingSummary.model_validate({"title": "t", "summary": ["a"]})
    title = apply_meeting_title(s, summary_json).title
    assert "![" not in title and "<b>" not in title
    assert title.startswith("Weekly")
    # An override that scrubs to nothing falls back to the summary's own title.
    (tmp_path / "x.meta.json").write_text(json.dumps({"meeting_title": "<b></b>"}), encoding="utf-8")
    assert apply_meeting_title(s, summary_json).title == "t"


# ----- Obsidian attendees (SEC28 item 4) -----


def test_every_attendee_is_one_quoted_element(tmp_path: Path) -> None:
    assert _yaml_quoted("Bob, Eve") == '"Bob, Eve"'
    assert _yaml_quoted('a]"b') == '"a]\\"b"'
    pub = ObsidianPublisher(vault_path=tmp_path / "vault", attach_audio=False)
    transcript = tmp_path / "20260506-1500.md"
    transcript.write_text("# T\n", encoding="utf-8")
    res = pub.upsert(
        summary=MeetingSummary.model_validate(
            {"title": "t", "summary": ["a"], "attendees": ["Bob, Eve", "Alice"]}
        ),
        transcript_md=transcript, sidecar_path=tmp_path / "s.json",
    )
    assert 'attendees: ["Bob, Eve", "Alice"]' in Path(res["page_id"]).read_text(encoding="utf-8")
