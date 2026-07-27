"""Unit tests for the shared JSON recovery helpers.

`largest_balanced_json_object` is pinned against its Swift mirror by
`test_ci3_parity`; this file covers `repair_missing_commas`, the lenient last
resort added after a 7B dropped one comma and cost a whole meeting (2026-07-27).

The bar for the repair is asymmetric on purpose: it only ever runs after a strict
parse has already failed, so failing to fix something is cheap, but corrupting
something that would have parsed is not. Most of these tests are about the second
half of that.
"""
from __future__ import annotations

import json

from mp.json_extract import repair_missing_commas


# ----- It fixes the defect it exists for -----

def test_repairs_the_comma_the_local_model_dropped() -> None:
    """The exact 2026-07-27 shape: a `"text"` value ending in a period, then a
    newline, then the next key with no comma between them."""
    broken = (
        '{\n'
        '  "title": "Stand-up",\n'
        '  "summary": [\n'
        '    {\n'
        '      "text": "Raza should prepare for a question about utilization."\n'
        '      "evidence": [{"quote": "Better to prepare it.", "t": "[9:14]"}]\n'
        '    }\n'
        '  ]\n'
        '}'
    )
    assert json_fails(broken)
    repaired = repair_missing_commas(broken)
    assert repaired is not None
    obj = json.loads(repaired)
    assert obj["summary"][0]["text"].endswith("utilization.")
    assert obj["summary"][0]["evidence"][0]["t"] == "[9:14]"


def test_repairs_missing_comma_between_array_elements() -> None:
    repaired = repair_missing_commas('{"a": [1 2 3]}')
    assert repaired is not None
    assert json.loads(repaired) == {"a": [1, 2, 3]}


def test_repairs_missing_comma_between_sibling_objects() -> None:
    repaired = repair_missing_commas('{"a": [{"x": 1}{"y": 2}]}')
    assert repaired is not None
    assert json.loads(repaired) == {"a": [{"x": 1}, {"y": 2}]}


def test_repairs_missing_comma_after_a_bare_literal() -> None:
    """`true` / `false` / `null` end a value too, so a key following one without a
    comma is the same defect."""
    repaired = repair_missing_commas('{"a": true "b": null "c": false "d": 1}')
    assert repaired is not None
    assert json.loads(repaired) == {"a": True, "b": None, "c": False, "d": 1}


# ----- It leaves well-formed JSON alone -----

def test_returns_none_when_nothing_is_missing() -> None:
    """None, not a copy: the caller uses it to decide whether a fourth candidate
    is worth trying at all."""
    for good in (
        '{"a": 1, "b": [1, 2], "c": {"d": "e"}}',
        '{}',
        '{"a": []}',
        '{"nested": {"deep": [{"x": null}, {"y": true}]}}',
    ):
        assert repair_missing_commas(good) is None, good


def test_never_touches_punctuation_inside_strings() -> None:
    """A transcript quote is full of braces, quotes and newlines. Inserting a comma
    into one would corrupt content that parsed perfectly well."""
    tricky = json.dumps({
        "title": 'He said "ship it" then left',
        "summary": ['a }{ b ", " c', 'looks: like "json" {"k": 1}'],
        "note": "line one\nline two",
        "path": "C:\\\\Users\\\\x",
    })
    assert json.loads(tricky)  # sanity: valid to begin with
    assert repair_missing_commas(tricky) is None


def test_does_not_corrupt_an_exponent() -> None:
    """`1e-5` is a value-ending `e` followed by a `-` that can start a member. The
    literal tracking is what stops that reading, and this is its regression test."""
    good = '{"a": 1e-5, "b": -2.5e+10, "c": 3.0}'
    assert repair_missing_commas(good) is None
    # And when a comma really is missing next to one, it still goes in the right place.
    repaired = repair_missing_commas('{"a": 1e-5 "b": 2}')
    assert repaired is not None
    assert json.loads(repaired) == {"a": 1e-5, "b": 2}


def test_unparseable_input_is_left_unparseable_not_mangled() -> None:
    """Prose in, nothing out. The repair must not invent structure."""
    assert repair_missing_commas("I cannot do that, Dave.") is None


def test_repair_is_idempotent() -> None:
    """Running it on its own output must be a no-op, or the layer would keep
    rewriting a candidate every time it was retried."""
    once = repair_missing_commas('{"a": 1 "b": 2}')
    assert once is not None
    assert repair_missing_commas(once) is None


def json_fails(text: str) -> bool:
    try:
        json.loads(text)
    except json.JSONDecodeError:
        return True
    return False
