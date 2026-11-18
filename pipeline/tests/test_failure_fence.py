"""OBS1: `Log.failure(` writes an event row, so `scripts/truth_fences.py events` fences its
category, its action and its attribute keys exactly as it fences `Log.event(`.

Loaded by path and run over scratch sources (the `test_content_key_fence.py` precedent).
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

_FENCES = Path(__file__).resolve().parents[2] / "scripts" / "truth_fences.py"
_spec = importlib.util.spec_from_file_location("truth_fences_failure", _FENCES)
assert _spec and _spec.loader
fences = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fences)


def test_a_failure_category_is_seen():
    src = 'Log.failure(category: "nope", action: "x_failed", error: error)\n'
    assert fences.SWIFT_EMIT.findall(src) == ["nope"]


def test_a_failure_action_is_read_with_error_or_reason_after_it():
    error_form = 'Log.failure(category: "daemon", action: "saveFailed", error: error)\n'
    reason_form = 'Log.failure(category: "daemon", action: "mp_missing", reason: "mp not found")\n'
    assert [m.group(1) for m in fences.SWIFT_EMIT_ACTION.finditer(error_form)] == ['"saveFailed"']
    assert [m.group(1) for m in fences.SWIFT_EMIT_ACTION.finditer(reason_form)] == ['"mp_missing"']


def test_a_denied_key_passed_through_the_helper_fails():
    src = 'Log.failure(category: "library", action: "x_failed", error: e, attributes: [\n    "title": t,\n])\n'
    assert fences.content_key_hits({"Foo.swift": src}, {}) == ["Foo.swift:1: event attribute `title`"]
