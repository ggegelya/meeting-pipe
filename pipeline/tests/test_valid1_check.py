"""TECH-VALID1: the acceptance helper's pure reads.

The script lives in scripts/ (stdlib-only, runs on a clean Mac without uv), so
it is loaded by path rather than imported as a package. Running it here is also
the only CI coverage a repo-root script gets: ruff and pyright are scoped to
pipeline/src + pipeline/tests, and because CI runs this on Linux, a non-stdlib
import in the script breaks this file immediately.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

_SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "valid1_check.py"
_spec = importlib.util.spec_from_file_location("valid1_check", _SCRIPT)
assert _spec and _spec.loader
valid1_check = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(valid1_check)


def _tx(action: str, ts: str, file: str = "m.wav", engine: str = "fluidaudio", **attrs):
    return {"category": "transcription", "action": action, "ts": ts,
            "file": file, "engine": engine, **attrs}


def _seg(start: float, end: float, speaker: str):
    return {"start": start, "end": end, "speaker": speaker}


# --------------------------------------------------------------- DIAR1 latency

def test_diar_pairs_started_and_succeeded_into_a_realtime_factor():
    events = [
        _tx("engine_started", "2026-07-01T10:00:00Z"),
        _tx("engine_succeeded", "2026-07-01T10:00:10Z", audio_seconds=600.0, segments=42),
    ]
    r = valid1_check.build_diar_report(events)
    assert r["runs"] == 1
    assert r["failed"] == 0
    # 600 s of audio in 10 s of wall clock.
    assert r["rtf"]["median"] == 60.0
    assert r["elapsed_sec"]["max"] == 10.0


def test_diar_excludes_the_swift_test_suite_fake_engines():
    """The Swift suite writes `fake`/`pass` transcription events into the same
    events.jsonl, including deliberate failures. Folding those in reported 243
    "failures" that were FakeRunner.Boom, so they are filtered and surfaced."""
    events = [
        _tx("engine_started", "2026-07-01T10:00:00Z"),
        _tx("engine_succeeded", "2026-07-01T10:00:10Z", audio_seconds=600.0),
        _tx("engine_started", "2026-07-01T11:00:00Z", file="clip.wav", engine="fake"),
        _tx("engine_failed", "2026-07-01T11:00:01Z", file="clip.wav", engine="fake"),
        _tx("engine_succeeded", "2026-07-01T11:00:02Z", file="c2.wav", engine="pass",
            audio_seconds=5.0),
    ]
    r = valid1_check.build_diar_report(events)
    assert r["runs"] == 1
    assert r["failed"] == 0, "a fake engine's Boom is not a real transcription failure"
    assert r["other_engines"] == {"fake": 1, "pass": 1}


def test_diar_skips_the_empty_recording_that_succeeds_with_no_audio():
    events = [
        _tx("engine_started", "2026-07-01T10:00:00Z"),
        _tx("engine_succeeded", "2026-07-01T10:00:01Z", audio_seconds=0, segments=0),
    ]
    r = valid1_check.build_diar_report(events)
    assert r["runs"] == 0


def test_diar_fails_when_a_run_is_slower_than_real_time():
    events = [
        _tx("engine_started", "2026-07-01T10:00:00Z"),
        _tx("engine_succeeded", "2026-07-01T10:01:00Z", audio_seconds=30.0),
    ]
    r = valid1_check.build_diar_report(events)
    assert r["slower_than_realtime"] == 1
    assert valid1_check.report_diar(events) is False


def test_diar_counts_a_real_engine_failure():
    events = [
        _tx("engine_started", "2026-07-01T10:00:00Z"),
        _tx("engine_failed", "2026-07-01T10:00:05Z", error="boom"),
    ]
    r = valid1_check.build_diar_report(events)
    assert r["runs"] == 0
    assert r["failed"] == 1


# ------------------------------------------------------- attribution coverage

def test_classify_speaker_buckets():
    assert valid1_check.classify_speaker("Heorhii") == "named"
    assert valid1_check.classify_speaker("THEM-A") == "them_cluster"
    assert valid1_check.classify_speaker("speaker_unknown") == "unattributed"
    # A raw diarization id that never resolved to a cluster is nobody's speech.
    assert valid1_check.classify_speaker("speaker_3") == "unattributed"
    assert valid1_check.classify_speaker("speaker_user") == "channel_fallback"
    assert valid1_check.classify_speaker(None) == "unattributed"


def test_attribution_is_time_weighted_not_segment_counted():
    """One long unattributed segment outweighs several short named ones, which is
    the whole reason the share is computed over duration."""
    transcripts = [("m1", {"segments": [
        _seg(0, 90, "speaker_unknown"),
        _seg(90, 95, "Heorhii"),
        _seg(95, 100, "THEM-A"),
    ]})]
    r = valid1_check.build_attribution_report(transcripts)
    assert r["meetings"] == 1
    assert r["unattributed_share"] == 0.9
    assert r["by_class_share"]["named"] == 0.05


def test_attribution_ignores_zero_and_negative_duration_segments():
    transcripts = [("m1", {"segments": [
        _seg(0, 10, "Heorhii"),
        _seg(10, 10, "speaker_unknown"),
        _seg(20, 5, "speaker_unknown"),
        {"start": "x", "end": "y", "speaker": "THEM-A"},
    ]})]
    r = valid1_check.build_attribution_report(transcripts)
    assert r["unattributed_share"] == 0.0
    assert r["speech_hours"] == 0.0


def test_attribution_ranks_the_worst_meetings_first():
    transcripts = [
        ("good", {"segments": [_seg(0, 100, "Heorhii")]}),
        ("bad", {"segments": [_seg(0, 100, "speaker_unknown")]}),
    ]
    r = valid1_check.build_attribution_report(transcripts)
    assert r["worst_meetings"][0]["stem"] == "bad"
    assert r["worst_meetings"][0]["unattributed_share"] == 1.0
    assert r["meetings"] == 2


# -------------------------------------------------- DER from in-app corrections

def _meeting(stem: str, segs: list[dict], labels=None, segments=None):
    return (stem, {"segments": segs}, {"labels": labels or {}, "segments": segments or {}})


def test_der_counts_a_reassignment_as_a_diarization_error():
    m = _meeting("m1", [_seg(0, 90, "THEM-A"), _seg(90, 100, "THEM-A")],
                 segments={"1": "Anisha"})
    r = valid1_check.build_corrections_report([m])
    # 10 s of 100 s was on the wrong person.
    assert r["der_lower_bound"] == 0.1


def test_der_ignores_a_cluster_rename_which_is_naming_not_a_correction():
    """Naming THEM-A "Rana" resolves every THEM-A line to Rana, but the diarizer
    was not wrong about who spoke; nothing was reassigned."""
    m = _meeting("m1", [_seg(0, 100, "THEM-A")], labels={"THEM-A": "Rana"})
    r = valid1_check.build_corrections_report([m])
    assert r["der_lower_bound"] == 0.0


def test_der_ignores_a_no_op_override_to_the_same_person():
    # The real data had these: raw 'Heorhii' overridden to "Heorhii".
    m = _meeting("m1", [_seg(0, 100, "Heorhii")], segments={"0": "Heorhii"})
    r = valid1_check.build_corrections_report([m])
    assert r["der_lower_bound"] == 0.0


def test_der_ignores_an_override_that_only_renames_through_the_cluster():
    # Assigning a line to THEM-A when it already showed as Rana (== labels[THEM-A])
    # changes the label but not the person.
    m = _meeting("m1", [_seg(0, 100, "THEM-A")],
                 labels={"THEM-A": "Rana"}, segments={"0": "THEM-A"})
    r = valid1_check.build_corrections_report([m])
    assert r["der_lower_bound"] == 0.0


def test_der_reports_a_cluster_the_diarizer_merged_several_people_into():
    """The real 20260716-103024 failure: THEM-A held Sudip + 4 others, so half the
    meeting was misattributed and the user split it by hand."""
    segs = [_seg(0, 10, "THEM-A"), _seg(10, 20, "THEM-A"),
            _seg(20, 30, "THEM-A"), _seg(30, 40, "THEM-A")]
    m = _meeting("m1", segs, labels={"THEM-A": "Sudip"},
                 segments={"1": "Anisha", "2": "Yash", "3": "Heorhii"})
    r = valid1_check.build_corrections_report([m])
    assert len(r["merged_clusters"]) == 1
    merged = r["merged_clusters"][0]
    assert merged["cluster"] == "THEM-A"
    assert merged["resolved_as"] == "Sudip"
    assert merged["people"] == ["Anisha", "Heorhii", "Yash"]


def test_der_weights_meetings_by_speech_time_not_by_meeting():
    """A short catastrophic meeting must not outvote a long clean one: the rate is
    over speech time. 45 s wrong out of 145 s total."""
    short = _meeting("short", [_seg(0, 45, "THEM-A")], segments={"0": "Anisha"})
    long = _meeting("long", [_seg(0, 100, "THEM-A")])
    r = valid1_check.build_corrections_report([short, long])
    assert r["der_lower_bound"] == round(45 / 145, 4)


def test_der_empty_corpus_is_not_a_crash():
    assert valid1_check.build_corrections_report([]) == {"meetings": 0}


def test_attribution_empty_corpus_is_not_a_crash():
    assert valid1_check.build_attribution_report([]) == {"meetings": 0}
    assert valid1_check.build_attribution_report([("m", {"segments": []})]) == {"meetings": 0}
