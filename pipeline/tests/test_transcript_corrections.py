"""PIPE9: the pipeline-side transcript text-correction overlay.

Mirrors Swift's `TranscriptCorrectionStore` so a regenerate / re-index reflects
in-app line edits. Covers the pure primitives, the composed `overlaid_markdown`
view (speaker labels + text corrections), and a golden parity fixture shared
with the Swift suite so the two resolvers cannot drift.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from mp import transcript_corrections as tc

# The parity fixture is owned next to the Swift suite (a test resource of the
# daemon's MeetingPipeTests target) and read here too, so a change to either
# resolver breaks the other tree's test (the CI2/CI3 precedent).
GOLDEN = (
    Path(__file__).resolve().parents[2]
    / "daemon" / "Tests" / "MeetingPipeTests" / "Fixtures" / "transcript-corrections-golden.json"
)


def _segs() -> list[dict]:
    return [
        {"start": 0.0, "end": 1.0, "text": "helo wrld", "speaker": "THEM-A"},
        {"start": 1.0, "end": 2.0, "text": "second line", "speaker": "Me"},
    ]


def _write_corrections(directory: Path, stem: str, *items: dict) -> None:
    (directory / f"{stem}.transcript_corrections.json").write_text(
        json.dumps({"schema_version": 1, "segments": list(items)}), encoding="utf-8"
    )


# --- read_corrections -----------------------------------------------------

def test_read_corrections_maps_index_to_edited_text(tmp_path):
    md = tmp_path / "m.md"
    _write_corrections(tmp_path, "m",
                       {"index": 0, "original_text": "helo wrld", "edited_text": "hello world"})
    assert tc.read_corrections(md) == {0: tc.Correction("helo wrld", "hello world")}


def test_read_corrections_missing_or_malformed_is_empty(tmp_path):
    md = tmp_path / "m.md"
    assert tc.read_corrections(md) == {}
    (tmp_path / "m.transcript_corrections.json").write_text("not json", encoding="utf-8")
    assert tc.read_corrections(md) == {}


def test_read_corrections_skips_malformed_entries(tmp_path):
    md = tmp_path / "m.md"
    _write_corrections(tmp_path, "m",
                       {"index": 0, "original_text": "a", "edited_text": "kept"},
                       {"index": 1, "edited_text": "no original"},     # ASR12: ignored, as Swift does
                       {"index": True, "original_text": "b", "edited_text": "bool index"},
                       {"original_text": "c", "edited_text": "no index"},
                       {"index": 2, "original_text": "d"})             # no edited_text
    assert tc.read_corrections(md) == {0: tc.Correction("a", "kept")}


# --- apply_corrections (pure) ---------------------------------------------

def test_apply_corrections_rewrites_by_index():
    segs = _segs()
    assert tc.apply_corrections(segs, {0: tc.Correction("helo wrld", "hello world")})
    assert segs[0]["text"] == "hello world"
    assert segs[1]["text"] == "second line"  # untouched


def test_apply_corrections_empty_is_noop():
    segs = _segs()
    assert not tc.apply_corrections(segs, {})
    assert [s["text"] for s in segs] == ["helo wrld", "second line"]


def test_apply_corrections_ignores_out_of_range_index():
    segs = _segs()
    assert not tc.apply_corrections(segs, {5: tc.Correction("gone", "ghost")})
    assert [s["text"] for s in segs] == ["helo wrld", "second line"]


def test_apply_corrections_skips_a_drifted_entry_and_warns_once(caplog):
    """ASR12: an entry whose snapshot no longer matches its segment points at a
    different sentence now. It is skipped (and left in the sidecar), while a live
    entry beside it still applies, and one warning names the stem and the count."""
    segs = _segs()
    corrections = {
        0: tc.Correction("helo wrld", "hello world"),
        1: tc.Correction("a sentence that is gone", "edited"),
    }
    with caplog.at_level("WARNING", logger="mp.transcript_corrections"):
        assert tc.apply_corrections(segs, corrections, stem="20260101-090000")
    assert [s["text"] for s in segs] == ["hello world", "second line"]
    warnings = [r for r in caplog.records if r.levelname == "WARNING"]
    assert len(warnings) == 1
    assert "20260101-090000" in warnings[0].getMessage()
    assert "1 of 2" in warnings[0].getMessage()


def test_apply_corrections_compares_the_trimmed_pipeline_text():
    """The pipeline may pad a segment's text; Swift compares the trimmed form, so
    Python has to as well or it would skip every edit Swift applies."""
    segs = [{"text": "  helo wrld \n"}]
    assert tc.apply_corrections(segs, {0: tc.Correction("helo wrld", "hello world")})
    assert segs[0]["text"] == "hello world"


# --- overlaid_markdown (composed view) ------------------------------------

def _write_json(directory: Path, stem: str) -> Path:
    (directory / f"{stem}.json").write_text(
        json.dumps({"language": "en", "segments": _segs()}), encoding="utf-8"
    )
    md = directory / f"{stem}.md"
    md.write_text("raw", encoding="utf-8")
    return md


def test_overlaid_markdown_applies_corrections(tmp_path):
    md = _write_json(tmp_path, "m")
    _write_corrections(tmp_path, "m",
                       {"index": 0, "original_text": "helo wrld", "edited_text": "hello world"})
    out = tc.overlaid_markdown(md)
    assert out is not None
    assert "hello world" in out
    assert "helo wrld" not in out


def test_overlaid_markdown_applies_both_overlays(tmp_path):
    md = _write_json(tmp_path, "m")
    _write_corrections(tmp_path, "m",
                       {"index": 0, "original_text": "helo wrld", "edited_text": "hello world"})
    (tmp_path / "m.speaker_labels.json").write_text(
        json.dumps({"labels": {"THEM-A": "Alice"}, "segments": {}}), encoding="utf-8"
    )
    out = tc.overlaid_markdown(md)
    assert out is not None
    assert "hello world" in out   # text correction
    assert "Alice" in out         # speaker overlay
    assert "THEM-A" not in out


def test_overlaid_markdown_none_without_overlays(tmp_path):
    md = _write_json(tmp_path, "m")
    assert tc.overlaid_markdown(md) is None


# --- golden parity with Swift ---------------------------------------------

def _golden_cases() -> list[dict]:
    return json.loads(GOLDEN.read_text(encoding="utf-8"))["cases"]


@pytest.mark.parametrize("case", _golden_cases(), ids=lambda c: c["name"])
def test_golden_parity_with_swift(case: dict, tmp_path: Path):
    stem = "golden"
    md = tmp_path / f"{stem}.md"
    md.write_text("raw", encoding="utf-8")
    (tmp_path / f"{stem}.transcript_corrections.json").write_text(
        json.dumps(case["corrections"]), encoding="utf-8"
    )
    segments = [dict(s) for s in case["segments"]]
    tc.apply_corrections(segments, tc.read_corrections(md))
    assert [s["text"] for s in segments] == case["expected"]
