"""CI4: the three remaining Swift-Python contracts, pinned by shared fixtures.

`<stem>.publish.json`, the `mp prefetch-model` progress JSONL, and the
`<stem>.speaker_labels.json` resolution each had two independent sets of
expectations (Python tests asserting Python-authored values, Swift tests
asserting Swift-authored string literals), so a coordinated rename passed both
suites. The fixtures under `daemon/Tests/MeetingPipeTests/Fixtures/` are now the
single checked-in copy both trees read, and they are GENERATED from the shipping
Python writers by `scripts/gen_contract_fixtures.py`.

This side asserts the committed files still match what the generator produces
right now, so changing a writer without regenerating is a red build here. The
Swift side (`CI4ContractFixtureTests`) parses the same files with the real
readers, so regenerating a shape Swift does not understand is a red build there.
Together that is the CI2/CI3 property extended to the last three surfaces: a
deliberate writer change breaks the other tree's test.
"""
from __future__ import annotations

import importlib.util
import json
from datetime import datetime
from pathlib import Path

import pytest

_REPO = Path(__file__).resolve().parents[2]
_FIXTURES = _REPO / "daemon" / "Tests" / "MeetingPipeTests" / "Fixtures"
_GENERATOR = _REPO / "scripts" / "gen_contract_fixtures.py"


def _generator():
    spec = importlib.util.spec_from_file_location("gen_contract_fixtures", _GENERATOR)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _committed(name: str) -> str:
    return (_FIXTURES / name).read_text(encoding="utf-8")


def _cases(name: str) -> list:
    doc = json.loads(_committed(name))
    return [pytest.param(c, id=c["name"]) for c in doc["cases"]]


# --------------------------------------------------------------------------
# The fixtures are current
# --------------------------------------------------------------------------


def test_publish_fixture_matches_the_live_writer(tmp_path: Path) -> None:
    assert _generator().gen_publish(tmp_path) == _committed("publish-result-golden.json"), (
        "publish_router._write_publish_sidecar changed; regenerate with "
        "`cd pipeline && uv run python ../scripts/gen_contract_fixtures.py`"
    )


def test_prefetch_fixture_matches_the_live_emitter() -> None:
    assert _generator().gen_prefetch() == _committed("prefetch-progress-golden.json"), (
        "prefetch_model's _emit call sites changed; regenerate with "
        "`cd pipeline && uv run python ../scripts/gen_contract_fixtures.py` and "
        "check ModelDownloadSupervisor.handleEvent still covers every event"
    )


def test_overlay_fixture_matches_the_live_resolver(tmp_path: Path) -> None:
    assert _generator().gen_overlay(tmp_path) == _committed("speaker-overlay-golden.json"), (
        "speaker_overlay.read_overlay/apply_overlay changed; regenerate with "
        "`cd pipeline && uv run python ../scripts/gen_contract_fixtures.py` and "
        "mirror the change in Swift's SpeakerLabelStore"
    )


# --------------------------------------------------------------------------
# Guard the guards: a vacuously-empty fixture must not read as agreement
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    "name,minimum",
    [
        ("publish-result-golden.json", 4),
        ("prefetch-progress-golden.json", 4),
        ("speaker-overlay-golden.json", 10),
    ],
)
def test_fixtures_are_not_vacuous(name: str, minimum: int) -> None:
    doc = json.loads(_committed(name))
    assert len(doc["cases"]) >= minimum
    assert doc["_comment"]


# --------------------------------------------------------------------------
# <stem>.publish.json
# --------------------------------------------------------------------------


@pytest.mark.parametrize("case", _cases("publish-result-golden.json"))
def test_publish_payload_shape(case: dict) -> None:
    """Every key Swift may read is present with the type it expects. Swift's
    `PublishResult.load` uses only `state` and `page_url`, but the other three
    are what a later reader would reach for, so drift in them is still drift."""
    payload = case["payload"]
    assert set(payload) == {"schema_version", "state", "page_url", "ts", "sinks"}
    assert payload["schema_version"] == 1
    assert payload["state"] in {"full", "partial", "none"}
    assert payload["page_url"] is None or isinstance(payload["page_url"], str)
    assert isinstance(payload["sinks"], dict)
    for sink in payload["sinks"].values():
        assert set(sink) == {"ok", "page_url", "error"}
        assert isinstance(sink["ok"], bool)


def test_publish_ts_stays_iso8601(tmp_path: Path) -> None:
    """The fixture carries a sentinel `ts` (a wall-clock stamp cannot be golden),
    so the real format is asserted straight off the writer instead."""
    from mp.publish_router import _write_publish_sidecar, publish_sidecar_path

    summary = tmp_path / "m.summary.json"
    summary.write_text("{}", encoding="utf-8")
    _write_publish_sidecar(summary, {"page_url": None, "sinks": {"filesystem": {}}})
    ts = json.loads(publish_sidecar_path(summary).read_text(encoding="utf-8"))["ts"]

    parsed = datetime.fromisoformat(ts)
    assert parsed.tzinfo is not None
    assert parsed.microsecond == 0


def test_publish_state_and_exit_three_stay_distinct() -> None:
    """Zero sinks configured is a clean success. `all_sinks_failed` (the exit-3
    trigger) is deliberately narrower than `state == "none"`, and the fixture
    covers a case where they agree; this pins the case where they do not."""
    from mp.publish_router import EXIT_PUBLISH_FAILED, all_sinks_failed, publish_state

    no_sinks: dict = {"sinks": {}}
    assert publish_state(no_sinks) == "none"
    assert all_sinks_failed(no_sinks) is False
    assert EXIT_PUBLISH_FAILED == 3


# --------------------------------------------------------------------------
# mp prefetch-model progress JSONL
# --------------------------------------------------------------------------


@pytest.mark.parametrize("case", _cases("prefetch-progress-golden.json"))
def test_prefetch_line_is_one_json_object(case: dict) -> None:
    record = json.loads(case["line"])
    assert "\n" not in case["line"]
    assert isinstance(record["event"], str)
    assert isinstance(record["repo_id"], str)


def test_prefetch_events_are_exactly_the_four_swift_handles() -> None:
    """Swift switches on these four strings and drops anything else on the
    floor, which would strand the menu-bar title mid-download."""
    doc = json.loads(_committed("prefetch-progress-golden.json"))
    emitted = {json.loads(c["line"])["event"] for c in doc["cases"]}
    assert emitted == {"started", "progress", "complete", "failed"}


def test_prefetch_byte_fields_cover_the_started_fallback() -> None:
    """`started` carries `cached_bytes` and no `downloaded_bytes`; Swift falls
    back from one to the other. If that fallback is ever removed, a fresh
    download would show 0 bytes on its first event."""
    doc = json.loads(_committed("prefetch-progress-golden.json"))
    by_event = {json.loads(c["line"])["event"]: json.loads(c["line"]) for c in doc["cases"]}
    assert "downloaded_bytes" not in by_event["started"]
    assert "cached_bytes" in by_event["started"]
    assert "downloaded_bytes" in by_event["progress"]


# --------------------------------------------------------------------------
# <stem>.speaker_labels.json resolution
# --------------------------------------------------------------------------


@pytest.mark.parametrize("case", _cases("speaker-overlay-golden.json"))
def test_overlay_resolution_golden(case: dict, tmp_path: Path) -> None:
    """Replay the fixture through the real reader + resolver. This is the same
    assertion the Swift suite makes against the same file."""
    from mp.speaker_overlay import apply_overlay, overlay_path, read_overlay

    md = tmp_path / "meeting.md"
    md.write_text("", encoding="utf-8")
    overlay_path(md).write_text(json.dumps(case["sidecar"], sort_keys=True), encoding="utf-8")

    overlay = read_overlay(md)
    assert overlay["labels"] == case["read_labels"]
    assert overlay["segments"] == case["read_segments"]

    segments = [{"speaker": s} for s in case["speakers"]]
    changed = apply_overlay(segments, overlay)
    assert [s.get("speaker") for s in segments] == case["resolved"]
    assert changed == case["changed"]


def test_overlay_reader_drops_what_swift_drops() -> None:
    """The fail-open shapes are the point: both readers must be fail-open in the
    SAME way. A value Python kept and Swift dropped meant a regenerated summary
    could attribute lines to a speaker the Library never displayed."""
    doc = json.loads(_committed("speaker-overlay-golden.json"))
    dropped = [c for c in doc["cases"] if c["name"].endswith("_is_dropped")]
    assert len(dropped) >= 5
    for case in dropped:
        assert case["read_labels"] == {}
        assert case["read_segments"] == {}
        assert case["changed"] is False
