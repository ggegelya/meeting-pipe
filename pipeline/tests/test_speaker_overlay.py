"""FEAT3-UNDO / FEAT3-SEGMENT: the pipeline-side speaker-label overlay reader.

Mirrors the Swift `SpeakerLabelStore` resolution so a regenerate reflects in-app
namings and reassignments in the summary. Pure functions, no I/O except the file reads.
"""
from __future__ import annotations

from mp.speaker_overlay import apply_overlay, read_overlay


def _segs() -> list[dict]:
    return [
        {"start": 0.0, "end": 1.0, "text": "hi", "speaker": "THEM-A"},
        {"start": 1.0, "end": 2.0, "text": "yo", "speaker": "THEM-A"},
        {"start": 2.0, "end": 3.0, "text": "me", "speaker": "Me"},
    ]


def test_apply_overlay_names_a_cluster():
    segs = _segs()
    assert apply_overlay(segs, {"labels": {"THEM-A": "Alice"}, "segments": {}})
    assert [s["speaker"] for s in segs] == ["Alice", "Alice", "Me"]


def test_segment_override_wins_over_cluster():
    segs = _segs()
    overlay = {"labels": {"THEM-A": "Alice"}, "segments": {"1": "Me"}}
    assert apply_overlay(segs, overlay)
    # segment 0 -> Alice (cluster); segment 1 -> Me (override); segment 2 -> Me.
    assert [s["speaker"] for s in segs] == ["Alice", "Me", "Me"]


def test_segment_override_chains_through_cluster_name():
    # Reassign segment 2 to the THEM-A cluster, which is named Alice -> shows Alice,
    # matching the Swift resolution (base label mapped through the name table).
    segs = _segs()
    apply_overlay(segs, {"labels": {"THEM-A": "Alice"}, "segments": {"2": "THEM-A"}})
    assert segs[2]["speaker"] == "Alice"


def test_empty_overlay_is_a_noop():
    segs = _segs()
    assert not apply_overlay(segs, {"labels": {}, "segments": {}})
    assert [s["speaker"] for s in segs] == ["THEM-A", "THEM-A", "Me"]


def test_read_overlay_missing_or_malformed_is_empty(tmp_path):
    md = tmp_path / "20260101-0900.md"
    md.write_text("x", encoding="utf-8")
    assert read_overlay(md) == {"labels": {}, "segments": {}}
    (tmp_path / "20260101-0900.speaker_labels.json").write_text("not json", encoding="utf-8")
    assert read_overlay(md) == {"labels": {}, "segments": {}}


# The composed transcript view (`overlaid_markdown`, speaker labels + text
# corrections) moved to `transcript_corrections`; see test_transcript_corrections.py.
