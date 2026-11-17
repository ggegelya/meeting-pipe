"""TECH-VALID1: the acceptance helper's pure reads.

The script lives in scripts/ (stdlib-only, runs on a clean Mac without uv), so
it is loaded by path rather than imported as a package. Running it here is also
the only CI coverage a repo-root script gets: ruff and pyright are scoped to
pipeline/src + pipeline/tests, and because CI runs this on Linux, a non-stdlib
import in the script breaks this file immediately.
"""
from __future__ import annotations

import importlib.util
import json as _json
import signal as _signal
import subprocess as _subprocess
from pathlib import Path

import pytest

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
    assert valid1_check.classify_speaker("Avery") == "named"
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
        _seg(90, 95, "Avery"),
        _seg(95, 100, "THEM-A"),
    ]})]
    r = valid1_check.build_attribution_report(transcripts)
    assert r["meetings"] == 1
    assert r["unattributed_share"] == 0.9
    assert r["by_class_share"]["named"] == 0.05


def test_attribution_ignores_zero_and_negative_duration_segments():
    transcripts = [("m1", {"segments": [
        _seg(0, 10, "Avery"),
        _seg(10, 10, "speaker_unknown"),
        _seg(20, 5, "speaker_unknown"),
        {"start": "x", "end": "y", "speaker": "THEM-A"},
    ]})]
    r = valid1_check.build_attribution_report(transcripts)
    assert r["unattributed_share"] == 0.0
    assert r["speech_hours"] == 0.0


def test_attribution_ranks_the_worst_meetings_first():
    transcripts = [
        ("good", {"segments": [_seg(0, 100, "Avery")]}),
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
                 segments={"1": "Casey"})
    r = valid1_check.build_corrections_report([m])
    # 10 s of 100 s was on the wrong person.
    assert r["der_lower_bound"] == 0.1


def test_der_ignores_a_cluster_rename_which_is_naming_not_a_correction():
    """Naming THEM-A "Emery" resolves every THEM-A line to Emery, but the diarizer
    was not wrong about who spoke; nothing was reassigned."""
    m = _meeting("m1", [_seg(0, 100, "THEM-A")], labels={"THEM-A": "Emery"})
    r = valid1_check.build_corrections_report([m])
    assert r["der_lower_bound"] == 0.0


def test_der_ignores_a_no_op_override_to_the_same_person():
    # An override that names the same person the raw label already did.
    m = _meeting("m1", [_seg(0, 100, "Avery")], segments={"0": "Avery"})
    r = valid1_check.build_corrections_report([m])
    assert r["der_lower_bound"] == 0.0


def test_der_ignores_an_override_that_only_renames_through_the_cluster():
    # Assigning a line to THEM-A when it already showed as Emery (== labels[THEM-A])
    # changes the label but not the person.
    m = _meeting("m1", [_seg(0, 100, "THEM-A")],
                 labels={"THEM-A": "Emery"}, segments={"0": "THEM-A"})
    r = valid1_check.build_corrections_report([m])
    assert r["der_lower_bound"] == 0.0


def test_der_reports_a_cluster_the_diarizer_merged_several_people_into():
    """A merged cluster: THEM-A held Blake and several others, so much of the
    meeting was misattributed and the user split it by hand."""
    segs = [_seg(0, 10, "THEM-A"), _seg(10, 20, "THEM-A"),
            _seg(20, 30, "THEM-A"), _seg(30, 40, "THEM-A")]
    m = _meeting("m1", segs, labels={"THEM-A": "Blake"},
                 segments={"1": "Casey", "2": "Drew", "3": "Avery"})
    r = valid1_check.build_corrections_report([m])
    assert len(r["merged_clusters"]) == 1
    merged = r["merged_clusters"][0]
    assert merged["cluster"] == "THEM-A"
    assert merged["resolved_as"] == "Blake"
    assert merged["people"] == ["Avery", "Casey", "Drew"]


def test_der_weights_meetings_by_speech_time_not_by_meeting():
    """A short catastrophic meeting must not outvote a long clean one: the rate is
    over speech time. 45 s wrong out of 145 s total."""
    short = _meeting("short", [_seg(0, 45, "THEM-A")], segments={"0": "Casey"})
    long = _meeting("long", [_seg(0, 100, "THEM-A")])
    r = valid1_check.build_corrections_report([short, long])
    assert r["der_lower_bound"] == round(45 / 145, 4)


def test_der_empty_corpus_is_not_a_crash():
    assert valid1_check.build_corrections_report([]) == {"meetings": 0}


def test_attribution_empty_corpus_is_not_a_crash():
    assert valid1_check.build_attribution_report([]) == {"meetings": 0}
    assert valid1_check.build_attribution_report([("m", {"segments": []})]) == {"meetings": 0}


# ------------------------------------------------- DIAR11: the owner-cluster replay


def _vec(cos_to_axis0: float, dim: int = 256) -> list[float]:
    v = [0.0] * dim
    v[0] = cos_to_axis0
    v[1] = (1 - cos_to_axis0 ** 2) ** 0.5
    return v


def _write_meeting(d: Path, stem: str, segments: list[dict], embeddings: dict, wav: bool = False) -> None:
    import json

    (d / f"{stem}.json").write_text(json.dumps({"segments": segments}), encoding="utf-8")
    (d / f"{stem}.embeddings.json").write_text(
        json.dumps({"schema_version": 2, "embeddings": embeddings}), encoding="utf-8")
    if wav:
        (d / f"{stem}.wav").write_bytes(b"")


def test_owner_cluster_before_counts_the_two_field_numbers(tmp_path):
    ref = _vec(1.0)
    # wrong owner: the name sits on a small cluster far from the owner's voice.
    _write_meeting(tmp_path, "20261001-100000",
                   [_seg(0, 5, "Avery"), _seg(5, 100, "THEM-A")],
                   {"Avery": _vec(0.2), "THEM-A": _vec(0.95)})
    # THEM-x matching the owner and holding more than 5 percent of the speech.
    _write_meeting(tmp_path, "20261002-100000",
                   [_seg(0, 50, "Avery"), _seg(50, 100, "THEM-A")],
                   {"Avery": _vec(1.0), "THEM-A": _vec(0.8)})
    # clean.
    _write_meeting(tmp_path, "20261003-100000",
                   [_seg(0, 50, "Avery"), _seg(50, 100, "THEM-A")],
                   {"Avery": _vec(1.0), "THEM-A": _vec(0.1)})
    inputs = valid1_check.load_owner_inputs(tmp_path)
    report = valid1_check.build_owner_cluster_report(
        inputs, ref, lambda it: valid1_check.current_placement(it, "Avery"))
    assert report["wrong_owner"]["stems"] == ["20261001-100000"]
    assert report["them_matching"]["stems"] == ["20261001-100000", "20261002-100000"]
    assert report["stems"] == 3 and report["skipped"] == 0


def test_owner_cluster_reference_is_the_voiceprint_else_the_owner_label_mean(tmp_path):
    _write_meeting(tmp_path, "20261001-100000", [_seg(0, 5, "Avery")], {"Avery": _vec(1.0)})
    inputs = valid1_check.load_owner_inputs(tmp_path)
    # The default yardstick is the field report's own: the owner-labelled centroid, NOT the
    # voiceprint the new pick is fed (measuring against it at the fold's own bar would pass by
    # construction).
    mean = valid1_check.owner_reference(inputs, "Avery", [9.0])
    assert mean is not None and abs(mean[0] - 1.0) < 1e-9
    assert valid1_check.owner_reference(inputs, "Avery", [9.0], mode="voiceprint") == [9.0]
    assert valid1_check.owner_reference(inputs, "Nobody", [9.0]) == [9.0]   # nothing to average
    assert valid1_check.owner_reference(inputs, "Nobody", None) is None


def test_owner_reference_mean_ignores_vectors_of_another_length(tmp_path):
    _write_meeting(tmp_path, "20261001-100000", [_seg(0, 5, "H")], {"H": [1.0, 0.0]})
    _write_meeting(tmp_path, "20261002-100000", [_seg(0, 5, "H")], {"H": [3.0, 0.0]})
    _write_meeting(tmp_path, "20261003-100000", [_seg(0, 5, "H")], {"H": [9.0, 9.0, 9.0]})
    inputs = valid1_check.load_owner_inputs(tmp_path)
    assert valid1_check.owner_reference(inputs, "H", None) == [2.0, 0.0]


def test_owner_cluster_reselect_moves_the_name_to_the_big_mic_cluster(tmp_path, monkeypatch):
    # Before: the name is on a 5 s cluster far from the owner. After the new pick, the 600 s
    # mic-side cluster that matches the voiceprint is the owner and the clip is not.
    ref = _vec(1.0)
    _write_meeting(
        tmp_path, "20261001-100000",
        [_seg(0, 5, "Avery"), _seg(5, 605, "THEM-A")],
        {"Avery": _vec(0.2), "THEM-A": _vec(1.0)}, wav=True)
    from mp import diarize

    monkeypatch.setattr(
        diarize, "analyze_mic_tier",
        lambda segs, wav: diarize.pick_mic_speaker({"Avery": 5.0, "THEM-A": 590.0},
                                                   {"Avery": 5.0, "THEM-A": 600.0}))
    inputs = valid1_check.load_owner_inputs(tmp_path)
    before = valid1_check.build_owner_cluster_report(
        inputs, ref, lambda it: valid1_check.current_placement(it, "Avery"))
    after = valid1_check.build_owner_cluster_report(
        inputs, ref, lambda it: valid1_check.reselect_placement(it, "Avery", ref))
    assert before["wrong_owner"]["count"] == 1
    assert after["wrong_owner"]["count"] == 0
    assert after["moved_onto_roster_named"]["count"] == 0


def test_owner_cluster_reselect_skips_a_stem_whose_audio_is_gone(tmp_path):
    _write_meeting(tmp_path, "20261001-100000", [_seg(0, 5, "Avery")], {"Avery": _vec(1.0)})
    inputs = valid1_check.load_owner_inputs(tmp_path)
    after = valid1_check.build_owner_cluster_report(
        inputs, _vec(1.0), lambda it: valid1_check.reselect_placement(it, "Avery", None))
    assert after["skipped"] == 1


def test_owner_cluster_mode_needs_the_owner_name(capsys):
    assert valid1_check.main(["--owner-cluster"]) == 2


def test_owner_cluster_reselect_never_moves_the_name_onto_a_roster_named_cluster_it_can_see(tmp_path, monkeypatch):
    # "Dana" is a roster-named cluster in the transcript. The replay's roster stand-in keeps her
    # named, so the fold cannot take her, and if a tier picked her the report would count it.
    ref = _vec(1.0)
    _write_meeting(
        tmp_path, "20261001-100000",
        [_seg(0, 300, "Avery"), _seg(300, 600, "Dana")],
        {"Avery": _vec(1.0), "Dana": _vec(0.9)}, wav=True)
    from mp import diarize

    monkeypatch.setattr(
        diarize, "analyze_mic_tier",
        lambda segs, wav: diarize.pick_mic_speaker({"Avery": 300.0, "Dana": 0.0},
                                                   {"Avery": 300.0, "Dana": 300.0}))
    inputs = valid1_check.load_owner_inputs(tmp_path)
    placement = valid1_check.reselect_placement(inputs[0], "Avery", ref)
    assert placement is not None
    assert placement["owner"] == {"Avery"} and placement["moved_onto_roster_named"] is False
    # A tier that does pick her is reported.
    monkeypatch.setattr(
        diarize, "analyze_mic_tier",
        lambda segs, wav: diarize.pick_mic_speaker({"Avery": 10.0, "Dana": 290.0},
                                                   {"Avery": 300.0, "Dana": 300.0}))
    picked = valid1_check.reselect_placement(inputs[0], "Avery", None)
    assert picked is not None and picked["moved_onto_roster_named"] is True


# ----- HYG23: the coldstart run is supervised, stopped SIGTERM-first, and its
# model server and candidate summaries are cleaned up -----


class _Group:
    """A fake process group: alive until `dies_after` signal-0 probes past the
    SIGTERM, or never when that is None. Records every signal."""

    def __init__(self, dies_after: int | None) -> None:
        self.signals: list[tuple[int, int]] = []
        self.dies_after = dies_after
        self.terminated = False
        self.probes_since_term = 0
        self.dead = False

    def killpg(self, pgid: int, sig: int) -> None:
        if self.dead:
            raise ProcessLookupError
        if sig == 0:
            if self.terminated:
                self.probes_since_term += 1
                if self.dies_after is not None and self.probes_since_term > self.dies_after:
                    self.dead = True
                    raise ProcessLookupError
            return
        self.signals.append((pgid, sig))
        if sig == _signal.SIGTERM:
            self.terminated = True
        if sig == _signal.SIGKILL:
            self.dead = True


class _Clock:
    def __init__(self) -> None:
        self.t = 0.0

    def __call__(self) -> float:
        return self.t

    def sleep(self, dt: float) -> None:
        self.t += dt


def _stop(group: _Group, tmp_path, *, marker: dict | None = None, command: str | None = None,
          started_wall: float = 1000.0) -> None:
    marker_path = tmp_path / "mlx-server.json"
    if marker is not None:
        marker_path.write_text(_json.dumps(marker), encoding="utf-8")
    clock = _Clock()
    valid1_check._stop_run(
        4242, started_wall,
        killpg=group.killpg, pid_command=lambda pid: command,
        marker_path=marker_path, getpgid=lambda pid: 4242,
        sleep=clock.sleep, clock=clock,
    )


def test_a_group_that_exits_within_the_grace_gets_no_sigkill(tmp_path):
    group = _Group(dies_after=3)
    _stop(group, tmp_path)
    assert group.signals == [(4242, _signal.SIGTERM)]


def test_a_group_that_outlives_the_grace_gets_sigkill(tmp_path):
    group = _Group(dies_after=None)
    _stop(group, tmp_path)
    assert group.signals == [(4242, _signal.SIGTERM), (4242, _signal.SIGKILL)]
    assert valid1_check.STOP_GRACE_SEC >= 15  # above terminate_server's ~10 s ladder


class _TwoGroups:
    """The run's group (4242) dies on SIGTERM; the server's group is `server`."""

    def __init__(self, server: _Group) -> None:
        self.run = _Group(dies_after=0)
        self.server = server

    def killpg(self, pgid: int, sig: int) -> None:
        (self.run if pgid == 4242 else self.server).killpg(pgid, sig)


def _stop_two(groups: _TwoGroups, tmp_path, marker: dict, command: str | None,
              owner_group=lambda pid: 4242) -> None:
    marker_path = tmp_path / "mlx-server.json"
    marker_path.write_text(_json.dumps(marker), encoding="utf-8")
    clock = _Clock()
    valid1_check._stop_run(
        4242, 1000.0,
        killpg=groups.killpg, pid_command=lambda pid: command,
        marker_path=marker_path, getpgid=owner_group,
        sleep=clock.sleep, clock=clock,
    )


@pytest.mark.parametrize("command", [
    "/venv/bin/python -m mp.local_model_server --model /snap --port 8765",
    "/venv/bin/python -m mlx_lm.server --model x --port 8765",
])
def test_this_runs_model_server_is_reaped_from_the_marker(tmp_path, command):
    groups = _TwoGroups(_Group(dies_after=2))
    _stop_two(groups, tmp_path, {"pid": 777, "owner_pid": 4243, "spawned_at": 1005.0}, command)
    assert groups.server.signals == [(777, _signal.SIGTERM)]


def test_a_server_from_before_the_run_is_left_alone(tmp_path):
    groups = _TwoGroups(_Group(dies_after=2))
    _stop_two(groups, tmp_path, {"pid": 777, "spawned_at": 999.0},
              "/venv/bin/python -m mp.local_model_server")
    assert groups.server.signals == []


def test_a_server_another_mp_started_meanwhile_is_left_alone(tmp_path):
    """Spawned after this run started, but its owner is in another group."""
    groups = _TwoGroups(_Group(dies_after=2))
    _stop_two(groups, tmp_path, {"pid": 777, "owner_pid": 9999, "spawned_at": 1005.0},
              "/venv/bin/python -m mp.local_model_server", owner_group=lambda pid: 31337)
    assert groups.server.signals == []


def test_an_owner_already_gone_falls_back_to_the_time_window(tmp_path):
    def gone(pid):
        raise ProcessLookupError

    groups = _TwoGroups(_Group(dies_after=2))
    _stop_two(groups, tmp_path, {"pid": 777, "owner_pid": 4243, "spawned_at": 1005.0},
              "/venv/bin/python -m mp.local_model_server", owner_group=gone)
    assert groups.server.signals == [(777, _signal.SIGTERM)]


def test_a_malformed_marker_is_ignored(tmp_path):
    groups = _TwoGroups(_Group(dies_after=2))
    _stop_two(groups, tmp_path, {"pid": 1e999, "spawned_at": 1005.0},
              "/venv/bin/python -m mp.local_model_server")
    assert groups.server.signals == []


def test_a_recycled_pid_is_never_signalled(tmp_path):
    groups = _TwoGroups(_Group(dies_after=2))
    _stop_two(groups, tmp_path, {"pid": 777, "spawned_at": 1005.0}, "/usr/bin/vim notes.txt")
    assert groups.server.signals == []


class _FakeProc:
    def __init__(self, *args, **kwargs) -> None:
        self.args, self.kwargs = args, kwargs
        self.pid = 5151
        self.stdin = None
        self.returncode = None

    def poll(self):
        return self.returncode

    def wait(self, timeout=None):
        self.returncode = 0
        raise KeyboardInterrupt


def test_run_timed_supervises_the_child_and_stops_it_on_ctrl_c(monkeypatch):
    made: list[_FakeProc] = []

    def popen(*a, **k):
        made.append(_FakeProc(*a, **k))
        return made[-1]

    stopped: list[tuple[int, dict]] = []
    monkeypatch.setattr(valid1_check.subprocess, "Popen", popen)
    monkeypatch.setattr(valid1_check, "free_memory_pct", lambda: 100.0)
    monkeypatch.setattr(valid1_check, "_stop_run",
                        lambda pgid, started, **k: stopped.append((pgid, k)))
    with pytest.raises(KeyboardInterrupt):
        valid1_check._run_timed(["mp", "summarize", "x.md"], "cold")
    kwargs = made[0].kwargs
    assert kwargs["stdin"] == _subprocess.PIPE
    assert kwargs["env"]["MP_SUPERVISED"] == "1"
    assert kwargs["start_new_session"] is True
    assert [pgid for pgid, _ in stopped] == [5151]
    # The stop closes the supervision pipe and reaps an exited caffeinate.
    assert stopped[0][1]["tick"] == made[0].poll


class _ClosableStdin:
    def __init__(self) -> None:
        self.closed = False

    def close(self) -> None:
        self.closed = True


def test_a_timeout_stops_the_run_instead_of_sigkilling_it(monkeypatch):
    class _Slow(_FakeProc):
        def __init__(self, *a, **k):
            super().__init__(*a, **k)
            self.stdin = _ClosableStdin()

        def wait(self, timeout=None):
            raise _subprocess.TimeoutExpired("caffeinate", timeout)

    made: list[_Slow] = []
    monkeypatch.setattr(valid1_check.subprocess, "Popen",
                        lambda *a, **k: made.append(_Slow(*a, **k)) or made[-1])
    monkeypatch.setattr(valid1_check, "free_memory_pct", lambda: 100.0)
    monkeypatch.setattr(valid1_check.os, "killpg",
                        lambda *a: pytest.fail("the timeout used to SIGKILL the group"))
    stopped: list[dict] = []
    monkeypatch.setattr(valid1_check, "_stop_run", lambda pgid, started, **k: stopped.append(k))
    _elapsed, rc = valid1_check._run_timed(["mp"], "cold")
    assert rc == -1
    assert len(stopped) == 1
    stopped[0]["close_stdin"]()
    assert made[0].stdin.closed


def test_the_low_memory_abort_waits_for_its_stop_to_finish(monkeypatch):
    """The abort is the case HYG23 exists for: its SIGTERM makes caffeinate exit
    and the wait return while the stop is still in its grace. Returning then lets
    the script exit and kill the (daemon) watchdog before the reap."""
    import threading as _threading
    import time as _time

    term, done = _threading.Event(), _threading.Event()

    class _Proc(_FakeProc):
        def poll(self):
            return None

        def wait(self, timeout=None):
            term.wait(5)  # caffeinate exits as soon as the group is SIGTERMed
            return 0

    def slow_stop(pgid, started, **k):
        term.set()
        _time.sleep(0.3)  # the grace, the SIGKILL, the reap
        done.set()

    monkeypatch.setattr(valid1_check.subprocess, "Popen", lambda *a, **k: _Proc(*a, **k))
    monkeypatch.setattr(valid1_check, "free_memory_pct", lambda: 1.0)
    monkeypatch.setattr(valid1_check, "_stop_run", slow_stop)
    _elapsed, rc = valid1_check._run_timed(["mp"], "cold")
    assert rc == -2
    assert done.is_set(), "_run_timed returned while the stop was still running"


def _coldstart_fixture(tmp_path, monkeypatch, *, cold_rc: int):
    transcript = tmp_path / "20260101-100000.md"
    transcript.write_text("[00:00] A: hi\n", encoding="utf-8")
    cand_json = tmp_path / "20260101-100000.summary.candidate.json"
    cand_md = tmp_path / "20260101-100000.summary.candidate.md"
    warm = iter([False, True, True])
    monkeypatch.setattr(valid1_check, "endpoint_is_warm", lambda endpoint: next(warm, True))
    monkeypatch.setattr(valid1_check, "free_memory_pct", lambda: 100.0)

    def run_timed(argv, label):
        cand_json.write_text("{}", encoding="utf-8")
        cand_md.write_text("# x", encoding="utf-8")
        return 1.0, cold_rc if label == "cold" else 0

    class _Server:
        pid = 6161

        def poll(self):
            return None

    monkeypatch.setattr(valid1_check, "_run_timed", run_timed)
    monkeypatch.setattr(valid1_check.subprocess, "Popen", lambda *a, **k: _Server())
    monkeypatch.setattr(valid1_check.os, "killpg", lambda pgid, sig: None)
    return transcript, cand_json, cand_md


def test_coldstart_refuses_while_an_in_app_preview_is_pending(tmp_path, monkeypatch):
    transcript, cand_json, _ = _coldstart_fixture(tmp_path, monkeypatch, cold_rc=0)
    cand_json.write_text('{"pending": true}', encoding="utf-8")
    ran: list[str] = []
    monkeypatch.setattr(valid1_check, "_run_timed", lambda argv, label: ran.append(label))
    assert valid1_check.run_coldstart(["mp"], transcript, "http://127.0.0.1:8765", None) is False
    assert ran == []
    assert cand_json.read_text(encoding="utf-8") == '{"pending": true}'


@pytest.mark.parametrize("cold_rc", [0, 1])
def test_coldstart_removes_the_candidates_it_wrote(tmp_path, monkeypatch, cold_rc):
    transcript, cand_json, cand_md = _coldstart_fixture(tmp_path, monkeypatch, cold_rc=cold_rc)
    valid1_check.run_coldstart(["mp"], transcript, "http://127.0.0.1:8765", None)
    assert not cand_json.exists()
    assert not cand_md.exists()
