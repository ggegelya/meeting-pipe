"""FEAT10: evidence-grounded summaries.

Three surfaces, in the order the data moves through them: the normalizer that
flattens the model's `{text, evidence}` sections into the stored shape, the
verifier that refuses to let an unresolvable anchor reach disk, and the renderers
(timestamped transcript in, `[mm:ss]` suffix out).
"""
from __future__ import annotations

import json

from mp import evidence as ev
from mp.json_extract import parse_summary
from mp.markdown import render_markdown, render_summary_md
from mp.schemas import Evidence, MeetingSummary, normalize_model_summary
from mp.summary_language import divergent_sections

# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------

SEGMENTS = [
    {"start": 0.0, "end": 12.0, "speaker": "Alice", "text": "Morning everyone, let's start."},
    {"start": 12.0, "end": 40.0, "speaker": "Bob", "text": "We will ship the export on Friday."},
    {"start": 40.0, "end": 75.0, "speaker": "Alice", "text": "I'll send the revised SOP to QA."},
    {"start": 754.0, "end": 800.0, "speaker": "Bob", "text": "Is the QMS export green yet?"},
]


def _model_payload() -> dict:
    """What a backend emits: sections as `{text, evidence}` objects."""
    return {
        "title": "Export sync",
        "summary": [
            {"text": "Agreed the export ships Friday.", "evidence": [
                {"quote": "We will ship the export on Friday", "t": "0:12"},
            ]},
            {"text": "SOP revision is in flight.", "evidence": []},
        ],
        "decisions": [
            {"text": "Ship the export on Friday.", "evidence": [
                {"quote": "ship the export on Friday", "t": 12.0},
            ]},
        ],
        "actions": [
            {
                "task": "Send revised SOP to QA",
                "owner": "Alice",
                "due": None,
                "confidence": "high",
                "evidence": [{"quote": "send the revised SOP to QA", "t": "0:40"}],
            }
        ],
        "questions": [
            {"text": "Is the QMS export green?", "evidence": [
                {"quote": "Is the QMS export green yet", "t": "12:34"},
            ]},
        ],
        "attendees": ["Alice", "Bob"],
        "detected_language": "en",
    }


# --------------------------------------------------------------------------
# Normalizer
# --------------------------------------------------------------------------


def test_normalizer_flattens_all_four_sections():
    s = MeetingSummary.model_validate(_model_payload())

    # The three string sections are stored as plain strings (ADR 0014 intact)...
    assert s.summary == ["Agreed the export ships Friday.", "SOP revision is in flight."]
    assert s.decisions == ["Ship the export on Friday."]
    assert s.questions == ["Is the QMS export green?"]
    # ...with their anchors index-aligned beside them.
    assert s.evidence["summary"][0][0].quote == "We will ship the export on Friday"
    assert s.evidence["summary"][1] == []
    assert s.evidence["decisions"][0][0].t == 12.0
    assert s.evidence["questions"][0][0].t == 754.0
    # The fourth section carries its anchors inline on the item.
    assert s.actions[0].evidence[0].quote == "send the revised SOP to QA"


def test_normalizer_is_a_noop_on_the_stored_shape():
    payload = {
        "title": "Legacy",
        "summary": ["a", "b"],
        "decisions": ["d"],
        "questions": ["q"],
        "actions": [{"task": "t", "owner": None, "due": None, "confidence": "low"}],
        "attendees": [],
        "detected_language": "en",
    }
    assert normalize_model_summary(payload) == payload


def test_legacy_summary_round_trips_unchanged():
    """A `<stem>.summary.json` written before FEAT10 must read back identically."""
    legacy = {
        "title": "Q1 review",
        "summary": ["bullet 1"],
        "decisions": ["We will ship Friday."],
        "actions": [{"task": "Update plan", "owner": "Bob", "due": None, "confidence": "high"}],
        "questions": ["Open?"],
        "attendees": ["Bob"],
        "detected_language": "en",
    }
    s = MeetingSummary.model_validate(legacy)
    assert s.evidence == {}
    assert s.actions[0].evidence == []
    # Every pre-existing field survives, and the render is byte-identical to
    # what it was before the field existed.
    dumped = json.loads(s.model_dump_json())
    for key, value in legacy.items():
        if key == "actions":
            continue
        assert dumped[key] == value
    assert render_summary_md(s) == (
        "# Q1 review\n"
        "\n"
        "**Attendees:** Bob\n"
        "\n"
        "_Language: en_\n"
        "\n"
        "## Summary\n"
        "- bullet 1\n"
        "\n"
        "## Decisions\n"
        "1. We will ship Friday.\n"
        "\n"
        "## Action Items\n"
        "- [ ] **Bob**: Update plan  _(confidence: high)_\n"
        "\n"
        "## Open Questions\n"
        "- Open?\n"
    )


def test_normalizer_caps_anchors_at_two():
    payload = _model_payload()
    payload["summary"][0]["evidence"] = [
        {"quote": "one", "t": 1}, {"quote": "two", "t": 2}, {"quote": "three", "t": 3},
    ]
    s = MeetingSummary.model_validate(payload)
    assert len(s.evidence["summary"][0]) == 2


def test_evidence_alignment_is_repaired():
    """More anchor slots than bullets is an off-by-one citation waiting to
    happen, so the model trims rather than trusting the writer."""
    s = MeetingSummary.model_validate({
        "title": "t",
        "summary": ["only bullet"],
        "attendees": [],
        "detected_language": "en",
        "evidence": {
            "summary": [[{"quote": "a", "t": 1}], [{"quote": "b", "t": 2}]],
            "bogus_section": [[{"quote": "c", "t": 3}]],
        },
    })
    assert len(s.evidence["summary"]) == 1
    assert "bogus_section" not in s.evidence


def test_timestamp_decodes_from_mm_ss_and_seconds():
    """The model copies the `[mm:ss]` marker it saw rather than converting it,
    so both spellings have to land on the same float."""
    assert Evidence.model_validate({"quote": "x", "t": "12:34"}).t == 754.0
    assert Evidence.model_validate({"quote": "x", "t": "[12:34]"}).t == 754.0
    assert Evidence.model_validate({"quote": "x", "t": "1:02:03"}).t == 3723.0
    assert Evidence.model_validate({"quote": "x", "t": 754.5}).t == 754.5
    assert Evidence.model_validate({"quote": "x", "t": "754"}).t == 754.0
    # Garbage decodes to 0 rather than sinking the whole summary; the verifier
    # then drops it for not resolving.
    assert Evidence.model_validate({"quote": "x", "t": "later"}).t == 0.0
    assert Evidence.model_validate({"quote": "x", "t": True}).t == 0.0


# --------------------------------------------------------------------------
# Verifier
# --------------------------------------------------------------------------


def test_valid_anchor_is_kept_and_snapped():
    """A quote from the middle of a turn snaps back to that turn's start, so a
    chip click lands on the row that carries it."""
    s = MeetingSummary.model_validate(_model_payload())
    result = ev.verify(s, SEGMENTS)
    assert result.dropped == 0
    assert result.kept == 4
    # The bullet cited t=12 and the segment starts at 12.
    assert result.summary.evidence["summary"][0][0].t == 12.0
    # The action cited 0:40 and its segment starts at 40.
    assert result.summary.actions[0].evidence[0].t == 40.0
    # The question cited 12:34 = 754 s, which is that segment's start.
    assert result.summary.evidence["questions"][0][0].t == 754.0


def test_anchor_time_inside_a_turn_snaps_to_the_turn_start():
    s = MeetingSummary.model_validate({
        "title": "t", "attendees": [], "detected_language": "en",
        "summary": [{"text": "b", "evidence": [{"quote": "ship the export", "t": 35.0}]}],
    })
    # 35 s is inside the 12-40 segment; the anchor resolves to its start.
    assert ev.verify(s, SEGMENTS).summary.evidence["summary"][0][0].t == 12.0


def test_fabricated_quote_is_dropped():
    s = MeetingSummary.model_validate({
        "title": "t", "attendees": [], "detected_language": "en",
        "summary": [{"text": "b", "evidence": [
            {"quote": "we agreed to cancel the project", "t": 12.0},
        ]}],
    })
    result = ev.verify(s, SEGMENTS)
    assert result.kept == 0 and result.dropped == 1
    assert result.summary.evidence == {}


def test_out_of_range_time_is_dropped():
    """The quote is real but the timestamp points somewhere else entirely; a
    citation that sends the reader to the wrong row is the failure this
    prevents."""
    s = MeetingSummary.model_validate({
        "title": "t", "attendees": [], "detected_language": "en",
        "summary": [{"text": "b", "evidence": [
            {"quote": "We will ship the export on Friday", "t": 5000.0},
        ]}],
    })
    result = ev.verify(s, SEGMENTS)
    assert result.kept == 0 and result.dropped == 1


def test_quote_matching_tolerates_case_punctuation_and_whitespace():
    s = MeetingSummary.model_validate({
        "title": "t", "attendees": [], "detected_language": "en",
        "summary": [{"text": "b", "evidence": [
            {"quote": "WE WILL SHIP,  the export... on friday!", "t": 12.0},
        ]}],
    })
    assert ev.verify(s, SEGMENTS).kept == 1


def test_runaway_quote_is_dropped():
    long_quote = " ".join(["word"] * (ev.MAX_QUOTE_WORDS + 1))
    segments = [{"start": 0.0, "end": 10.0, "text": long_quote}]
    s = MeetingSummary.model_validate({
        "title": "t", "attendees": [], "detected_language": "en",
        "summary": [{"text": "b", "evidence": [{"quote": long_quote, "t": 0.0}]}],
    })
    assert ev.verify(s, segments).dropped == 1


def test_no_segments_drops_everything():
    """A BYO-paste meeting has no structured transcript, so nothing is
    verifiable and absence beats a guess."""
    s = MeetingSummary.model_validate(_model_payload())
    result = ev.verify(s, [])
    assert result.kept == 0
    assert result.summary.evidence == {}
    assert result.summary.actions[0].evidence == []


def test_verify_leaves_an_evidence_free_summary_untouched():
    s = MeetingSummary.model_validate({
        "title": "t", "summary": ["a"], "attendees": [], "detected_language": "en",
    })
    result = ev.verify(s, SEGMENTS)
    assert (result.kept, result.dropped) == (0, 0)
    assert result.summary == s


def test_gap_markers_are_not_quotable():
    """A FEAT9 recording-gap note is a divider the pipeline wrote, not something
    a person said, so it can never back a summary point."""
    segments = [{"start": 0.0, "end": 5.0, "kind": "gap", "text": "recording gap of 4 minutes"}]
    s = MeetingSummary.model_validate({
        "title": "t", "attendees": [], "detected_language": "en",
        "summary": [{"text": "b", "evidence": [{"quote": "recording gap of 4 minutes", "t": 0.0}]}],
    })
    assert ev.verify(s, segments).dropped == 1


# --------------------------------------------------------------------------
# Renderers
# --------------------------------------------------------------------------


def test_timestamped_transcript_render_prefixes_each_turn():
    structured = {"audio_path": "m.wav", "language": "en", "segments": SEGMENTS}
    plain = render_markdown(structured)
    timed = render_markdown(structured, timestamps=True)

    assert "[0:00] **Alice**: Morning everyone, let's start." in timed
    assert "[0:12] **Bob**: We will ship the export on Friday." in timed
    assert "[12:34] **Bob**: Is the QMS export green yet?" in timed
    # The stored `<stem>.md` render is untouched.
    assert "[0:12]" not in plain


def test_timestamped_render_marks_the_turn_start_not_the_last_segment():
    structured = {"segments": [
        {"start": 100.0, "end": 110.0, "speaker": "Alice", "text": "First part."},
        {"start": 110.0, "end": 120.0, "speaker": "Alice", "text": "Second part."},
    ]}
    assert "[1:40] **Alice**: First part. Second part." in render_markdown(
        structured, timestamps=True
    )


def test_published_markdown_carries_timestamp_suffixes():
    s = ev.verify(MeetingSummary.model_validate(_model_payload()), SEGMENTS).summary
    md = render_summary_md(s)

    assert "- Agreed the export ships Friday. [0:12]" in md
    assert "- SOP revision is in flight.\n" in md  # uncited bullet keeps no tail
    assert "1. Ship the export on Friday. [0:12]" in md
    assert "_(confidence: high)_ [0:40]" in md
    assert "- Is the QMS export green? [12:34]" in md
    # Owner's call 2026-07-22: timestamps only, never the quote.
    assert "We will ship the export on Friday" not in md


def test_multiple_anchors_render_as_one_bracket():
    s = MeetingSummary.model_validate({
        "title": "t", "attendees": [], "detected_language": "en",
        "summary": [{"text": "b", "evidence": [
            {"quote": "ship the export", "t": 12.0},
            {"quote": "Is the QMS export green", "t": 754.0},
        ]}],
    })
    assert "- b [0:12, 12:34]" in render_summary_md(ev.verify(s, SEGMENTS).summary)


# --------------------------------------------------------------------------
# Interplay
# --------------------------------------------------------------------------


def test_lang1_ignores_evidence_quotes():
    """A forced-English summary over a Ukrainian meeting keeps Ukrainian quotes.
    If the detector saw them it would flag every section and repair a summary
    that was already right."""
    s = MeetingSummary.model_validate({
        "title": "Weekly export sync",
        "summary": [{"text": "The team agreed to ship the export on Friday.", "evidence": [
            {"quote": "ми відвантажимо експорт у пʼятницю", "t": 12.0},
        ]}],
        "attendees": [],
        "detected_language": "en",
    })
    assert divergent_sections(s, "en") == []


def test_evidence_survives_json_recovery():
    """The PROV1 providers and the local backend recover their JSON from prose
    with `parse_summary`; anchors have to come through that path too."""
    payload = json.dumps(_model_payload(), ensure_ascii=False)
    noisy = f"Here is the summary you asked for:\n\n```json\n{payload}\n```\nHope that helps!"
    s = parse_summary(noisy, error=ValueError, message="unparseable")
    assert s.evidence["summary"][0][0].t == 12.0
    assert s.actions[0].evidence[0].quote == "send the revised SOP to QA"
