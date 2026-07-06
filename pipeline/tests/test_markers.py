"""Tests for the flagged-moment markers read side (FEAT8)."""
from __future__ import annotations

import json
from pathlib import Path

from mp.markers import _mmss, _segment_index_at, flagged_moments_block


def _write(tmp_path: Path, stem: str, *, markers=None, segments=None) -> Path:
    if markers is not None:
        (tmp_path / f"{stem}.markers.json").write_text(
            json.dumps({"schema_version": 1, "markers": [{"t_seconds": t} for t in markers]}),
            encoding="utf-8",
        )
    if segments is not None:
        (tmp_path / f"{stem}.json").write_text(
            json.dumps({"segments": segments}), encoding="utf-8"
        )
    return tmp_path / f"{stem}.md"


_SEGMENTS = [
    {"start": 0.0, "end": 10.0, "text": "Intro chatter.", "speaker": "A"},
    {"start": 10.0, "end": 20.0, "text": "We agreed to ship the migration on Friday.", "speaker": "B"},
    {"start": 20.0, "end": 30.0, "text": "Wrap up.", "speaker": "A"},
]


def test_block_contains_spanning_segment_excerpt(tmp_path: Path):
    md = _write(tmp_path, "m1", markers=[12.5], segments=_SEGMENTS)
    block = flagged_moments_block(md)
    assert block is not None
    assert "User-flagged moments" in block
    assert "We agreed to ship the migration on Friday." in block
    assert "[0:12]" in block  # mm:ss of the marker


def test_no_markers_file_is_none(tmp_path: Path):
    md = _write(tmp_path, "m2", segments=_SEGMENTS)  # no markers sidecar
    assert flagged_moments_block(md) is None


def test_markers_but_no_transcript_is_none(tmp_path: Path):
    md = _write(tmp_path, "m3", markers=[5.0])  # no <stem>.json
    assert flagged_moments_block(md) is None


def test_markers_in_same_segment_dedupe_to_one_line(tmp_path: Path):
    md = _write(tmp_path, "m4", markers=[11.0, 13.0, 19.0], segments=_SEGMENTS)
    block = flagged_moments_block(md)
    assert block is not None
    # All three land in segment 1; the excerpt appears once.
    assert block.count("We agreed to ship the migration on Friday.") == 1


def test_marker_in_gap_anchors_to_prior_segment(tmp_path: Path):
    gapped = [
        {"start": 0.0, "end": 5.0, "text": "First.", "speaker": "A"},
        {"start": 30.0, "end": 35.0, "text": "Second.", "speaker": "A"},
    ]
    md = _write(tmp_path, "m5", markers=[12.0], segments=gapped)  # 12s is in the 5-30 gap
    block = flagged_moments_block(md)
    assert block is not None
    assert "First." in block


def test_malformed_markers_file_is_none(tmp_path: Path):
    (tmp_path / "m6.markers.json").write_text("not json", encoding="utf-8")
    (tmp_path / "m6.json").write_text(json.dumps({"segments": _SEGMENTS}), encoding="utf-8")
    assert flagged_moments_block(tmp_path / "m6.md") is None


def test_segment_index_at_prefers_spanning_segment():
    assert _segment_index_at(15.0, _SEGMENTS) == 1
    assert _segment_index_at(0.0, _SEGMENTS) == 0
    assert _segment_index_at(100.0, _SEGMENTS) == 2  # beyond the end -> last


def test_mmss_formats_hours():
    assert _mmss(5) == "0:05"
    assert _mmss(75) == "1:15"
    assert _mmss(3661) == "1:01:01"
