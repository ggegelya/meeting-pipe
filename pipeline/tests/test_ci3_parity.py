"""CI3: golden parity for the two Swift-Python mirror pairs.

The fixtures live next to the Swift suite (a test resource of the daemon's
MeetingPipeTests target) and are read here too, so one checked-in file pins both
implementations. Python is the source of truth (the fixtures were generated from
these functions); a change to either side that drifts from the other breaks one
suite. This mirrors the chunking-golden.json precedent (CI2 / ARCH4).
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from mp.json_extract import largest_balanced_json_object
from mp.markdown import render_summary_md
from mp.schemas import MeetingSummary

_FIXTURES = (
    Path(__file__).resolve().parents[2]
    / "daemon" / "Tests" / "MeetingPipeTests" / "Fixtures"
)


def _cases(name: str) -> list:
    doc = json.loads((_FIXTURES / name).read_text(encoding="utf-8"))
    return [pytest.param(c, id=c["name"]) for c in doc["cases"]]


@pytest.mark.parametrize("case", _cases("json-extract-golden.json"))
def test_largest_balanced_json_object_golden(case: dict) -> None:
    assert largest_balanced_json_object(case["input"]) == case["expected"]


@pytest.mark.parametrize("case", _cases("summary-md-golden.json"))
def test_render_summary_md_golden(case: dict) -> None:
    model = MeetingSummary.model_validate(case["input"])
    assert render_summary_md(model) == case["expected"]
