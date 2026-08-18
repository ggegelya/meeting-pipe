"""FEAT17: the spike probe's two pure functions.

The probe itself needs the owner's library and roster, so it cannot be tested end
to end here. Its binning and its verdict mapping need neither, and they are the two
places a mistake would be silent: a mis-binned decline points the next task at the
wrong constant, and a mis-mapped count reports the wrong verdict off a correct
measurement. Both are pinned.

The probe lives in `docs/spikes/` beside its analysis doc, following the four
existing Python probes, so it is loaded by path rather than imported as a module.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

from mp.roster import MATCH_MIN, SUGGEST_MIN, MatchResult

_PROBE = Path(__file__).resolve().parents[2] / "docs" / "spikes" / "feat17_roster_near_miss.py"


def _load():
    spec = importlib.util.spec_from_file_location("feat17_probe", _PROBE)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


probe = _load()


# --- binning -----------------------------------------------------------------

def test_a_named_voice_is_not_a_decline():
    assert probe.classify(MatchResult("Anisha", None, 0.91)) == "named"


def test_no_candidates_is_its_own_bin():
    """An empty roster or a voice with no embedding is not a decline for score, and
    counting it as one would inflate the denominator the secondary reading divides by."""
    assert probe.classify(MatchResult(None, None, None)) == "no_candidates"


def test_a_near_miss_is_a_suggestion():
    assert probe.classify(MatchResult(None, "Ivan", 0.58)) == "suggested"


def test_a_score_under_the_floor_is_below_floor():
    assert probe.classify(MatchResult(None, None, SUGGEST_MIN - 0.01)) == "below_floor"


def test_a_decline_over_the_floor_with_no_suggestion_is_margin_blocked():
    """The bin that matters most. The margin gate gates the suggestion too, so a
    decline can sit well above the floor and still offer nothing; calling that
    `below_floor` would blame the wrong constant (FEAT17's third a-priori closure)."""
    assert probe.classify(MatchResult(None, None, MATCH_MIN - 0.01)) == "margin_blocked"
    assert probe.classify(MatchResult(None, None, 0.99)) == "margin_blocked"


def test_the_bins_are_exhaustive_and_exclusive():
    cases = [
        MatchResult("Rana", None, 0.9),
        MatchResult(None, None, None),
        MatchResult(None, "Yash", 0.55),
        MatchResult(None, None, 0.2),
        MatchResult(None, None, 0.7),
    ]
    seen = {probe.classify(c) for c in cases}
    assert seen == {"named", "no_candidates", "suggested", "below_floor", "margin_blocked"}


# --- the verdict mapping ------------------------------------------------------

@pytest.mark.parametrize(
    "count, expected",
    [
        (0, "CLOSE"),
        (2, "CLOSE"),
        (3, "MARGINAL"),
        (20, "MARGINAL"),
        (21, "GO"),
        (31, "GO"),
        (207, "GO"),
    ],
)
def test_the_verdict_reads_straight_off_the_pre_registered_table(count, expected):
    """The thresholds were registered 2026-08-18 before any number existed. Pinning
    the boundaries is what stops a later edit quietly moving one to meet a
    measurement, which is the failure a pre-registration exists to prevent."""
    assert probe.verdict(count) == expected


def test_the_thresholds_are_the_ones_the_doc_publishes():
    assert probe.GO_MIN_MEETINGS == 21
    assert probe.CLOSE_MAX_MEETINGS == 2
