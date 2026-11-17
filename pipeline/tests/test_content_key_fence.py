"""SEC38: the event-log content-key fence in `scripts/truth_fences.py events`.

Loaded by path (the `test_link_fence.py` precedent) and run over scratch sources, so the real
tree cannot make these pass or fail by accident. Synthetic placeholder text only.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

_FENCES = Path(__file__).resolve().parents[2] / "scripts" / "truth_fences.py"
_spec = importlib.util.spec_from_file_location("truth_fences_content_keys", _FENCES)
assert _spec and _spec.loader
fences = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fences)


def test_a_planted_title_attribute_in_a_swift_emit_fails():
    src = 'Log.event(category: "signal", action: "x", attributes: [\n    "bundle_id": b,\n    "title": t,\n])\n'
    hits = fences.content_key_hits({"Foo.swift": src}, {})
    assert hits == ["Foo.swift:1: event attribute `title`"]


def test_a_shape_attribute_and_a_ternary_value_pass():
    src = (
        'eventLog.emit(category: "signal", action: "x", attributes: [\n'
        '    "shape": s,\n    "matched_on": m ? "title" : "bundle",\n])\n'
    )
    assert fences.content_key_hits({"Foo.swift": src}, {}) == []


def test_an_attributes_subscript_assignment_fails():
    src = 'attributes["page_url"] = url\n'
    assert fences.content_key_hits({"Foo.swift": src}, {}) == ["Foo.swift:1: event attribute `page_url`"]


def test_a_python_page_url_kwarg_fails_and_sinks_pass():
    bad = 'events.emit("pipeline", "run_completed",\n            page_url=pub.get("page_url"))\n'
    good = 'events.emit("pipeline", "run_completed", sinks=landed)\n'
    assert fences.content_key_hits({}, {"a.py": bad}) == ["a.py:1: event attribute `page_url`"]
    assert fences.content_key_hits({}, {"b.py": good}) == []


def test_a_writeline_interpolating_a_title_or_page_url_fails():
    src = (
        'Log.writeLine("daemon", "title=\\(source?.meetingTitle ?? "")")\n'
        'Log.writeLine("daemon", "pipeline OK -> \\(pageURL?.absoluteString ?? "")")\n'
        'Log.writeLine("daemon", "title_known=\\(titleKnown)")\n'
    )
    hits = fences.content_key_hits({"Foo.swift": src}, {})
    assert hits == [
        "Foo.swift:1: daemon log line interpolates `meetingTitle`",
        "Foo.swift:2: daemon log line interpolates `pageURL`",
    ]


def test_the_allowlisted_keys_are_not_denied():
    assert not set(fences.CONTENT_KEY_ALLOWLIST) & set(fences.CONTENT_KEY_DENYLIST)


def test_a_title_suffixed_key_in_a_prebuilt_attributes_literal_fails():
    """END28's `from_title` / `to_title` shape: built before the call, and not an exact denylist key."""
    src = (
        'var attributes: [String: Any] = [\n'
        '    "bundle_id": b,\n    "from_title": f,\n]\n'
        'Log.event(category: "coordinator", action: "x", attributes: attributes)\n'
    )
    hits = fences.content_key_hits({"Foo.swift": src}, {})
    assert hits == ["Foo.swift:1: event attribute `from_title`"]


def test_a_title_suffixed_python_kwarg_fails():
    src = 'events.emit("pipeline", "x", meeting_titles=t)\n'
    assert fences.content_key_hits({}, {"a.py": src}) == ["a.py:1: event attribute `meeting_titles`"]
