"""STOR9 (the Python stores): missing is empty, unreadable is not.

A store a writer cannot read was read as empty and then saved over: one
"Name this speaker" wiped every named voice, and one finalize reset a
twelve-meeting self-voiceprint to a single sample. Each case here reproduces
that loss against a scratch file.
"""
from __future__ import annotations

import json
import os
import threading
from pathlib import Path

import pytest

from mp import doctor, orchestrate, storage, summarize as summarize_mod
from mp.config import Config, Recording
from mp.roster import EMBEDDING_DIM, RosterStore
from mp.voiceprint import VoiceprintStore

STEM = "20260722-140312"
_ROOT = os.geteuid() == 0


def _axis(i: int) -> list[float]:
    v = [0.0] * EMBEDDING_DIM
    v[i] = 1.0
    return v


@pytest.fixture
def emitted(monkeypatch: pytest.MonkeyPatch) -> list[dict]:
    rows: list[dict] = []
    from mp import events

    monkeypatch.setattr(
        events, "emit",
        lambda c, a, **kw: rows.append(kw) if (c, a) == ("pipeline", "store_unreadable") else None,
    )
    return rows


def _corrupt(path: Path, text: str) -> bytes:
    path.write_text(text, encoding="utf-8")
    return path.read_bytes()


# ---------- roster ----------------------------------------------------------


@pytest.mark.parametrize("text", [
    "{ not json", "[1, 2]", '"x"', '{"people": [1]}', '{"schema_version": 1}',
    '{"schema_version": 2, "people": []}',
])
def test_enroll_over_an_unparseable_roster_quarantines_it_then_writes(
    tmp_path: Path, emitted: list[dict], text: str
) -> None:
    path = tmp_path / "roster.json"
    before = _corrupt(path, text)
    roster = RosterStore(path)

    roster.enroll("Ann", _axis(0))

    corrupt = sorted(tmp_path.glob("roster.json.corrupt-*"))
    assert len(corrupt) == 1 and corrupt[0] == roster.quarantined_to
    assert corrupt[0].read_bytes() == before
    assert RosterStore(path).names() == ["Ann"]
    assert emitted == [{"store": "roster", "path_kind": "config", "reason": "unparseable",
                        "outcome": "quarantined"}]


@pytest.mark.skipif(_ROOT, reason="root reads a mode-000 file anyway")
def test_enroll_over_an_unreadable_roster_refuses_and_leaves_it(
    tmp_path: Path, emitted: list[dict]
) -> None:
    path = tmp_path / "roster.json"
    RosterStore(path).enroll("Ann", _axis(0))
    before = path.read_bytes()
    path.chmod(0)
    try:
        with pytest.raises(storage.StoreUnreadable):
            RosterStore(path).enroll("Bea", _axis(1))
    finally:
        path.chmod(0o600)
    assert path.read_bytes() == before
    assert list(tmp_path.glob("*.corrupt-*")) == []
    assert [r["outcome"] for r in emitted] == ["refused"]
    assert emitted[0]["reason"] == "EACCES"


@pytest.mark.parametrize("text", ["[1, 2]", '"x"'])
def test_a_non_object_roster_names_nobody_instead_of_crashing(
    tmp_path: Path, emitted: list[dict], text: str
) -> None:
    """F093: `names()` raised AttributeError, which failed finalize."""
    path = tmp_path / "roster.json"
    _corrupt(path, text)
    roster = RosterStore(path)
    assert roster.names() == []
    assert roster.match(_axis(0)) is None
    assert [r["outcome"] for r in emitted] == ["skipped"]


def test_rename_and_forget_over_an_unparseable_roster_refuse(tmp_path: Path) -> None:
    path = tmp_path / "roster.json"
    before = _corrupt(path, "{ not json")
    with pytest.raises(storage.StoreUnreadable):
        RosterStore(path).rename("Ann", "Anna")
    with pytest.raises(storage.StoreUnreadable):
        RosterStore(path).forget("Ann")
    assert path.read_bytes() == before


def test_the_cli_says_nothing_was_changed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    from mp import roster_cmd

    path = tmp_path / "roster.json"
    before = _corrupt(path, "{ not json")
    monkeypatch.setattr("mp.roster.ROSTER_PATH", path)
    assert roster_cmd.main(["rename", "--old", "Ann", "--new", "Anna"]) == 1
    assert "nothing was changed" in capsys.readouterr().err
    assert path.read_bytes() == before


def _interleaved(monkeypatch: pytest.MonkeyPatch, cls: type, method: str) -> None:
    """Make two threads both read before either writes, when nothing stops them."""
    barrier = threading.Barrier(2, timeout=1.0)
    real = getattr(cls, method)

    def waiting(self):
        try:
            barrier.wait()
        except threading.BrokenBarrierError:
            pass  # the other thread is held by the lock: proceed alone
        return real(self)

    monkeypatch.setattr(cls, method, waiting)


def test_two_enrolls_at_once_keep_both_people(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    path = tmp_path / "roster.json"
    _interleaved(monkeypatch, RosterStore, "read_people")
    threads = [
        threading.Thread(target=RosterStore(path).enroll, args=(name, _axis(i)))
        for i, name in enumerate(["Ann", "Bea"])
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(RosterStore(path).names()) == ["Ann", "Bea"]


# ---------- voiceprint ------------------------------------------------------


def _print(path: Path, meetings: int) -> bytes:
    path.write_text(json.dumps({"schema_version": 1, "embedding": _axis(0), "meetings": meetings}))
    return path.read_bytes()


@pytest.mark.parametrize("text", ['"x"', "[1]", '{"embedding": [1.0, 2.0], "meetings": 9}'])
def test_update_over_an_unusable_voiceprint_refuses_and_leaves_it(tmp_path: Path, text: str) -> None:
    path = tmp_path / "vp.json"
    before = _corrupt(path, text)
    store = VoiceprintStore(path)
    assert store.load() == (None, 0)  # display callers stay lenient
    with pytest.raises(storage.StoreUnreadable):
        store.update(_axis(1))
    assert path.read_bytes() == before


def test_two_updates_at_once_count_both(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    path = tmp_path / "vp.json"
    _print(path, 3)
    _interleaved(monkeypatch, VoiceprintStore, "load_checked")
    threads = [threading.Thread(target=VoiceprintStore(path).update, args=(_axis(i),)) for i in (1, 2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert VoiceprintStore(path).load()[1] == 5


class _Tier:
    def owner_pick(self, _voiceprint):
        return "S1"


@pytest.mark.parametrize("text", ['"x"', '{"embedding": [1.0, 2.0], "meetings": 9}'])
def test_finalize_skips_an_unusable_voiceprint_instead_of_resetting_it(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, emitted: list[dict], text: str
) -> None:
    """The enrol step read an unusable print as "not enrolled" and wrote a
    one-sample print over it (a wrong-shape print), or crashed (a string)."""
    path = tmp_path / "vp.json"
    before = _corrupt(path, text)
    monkeypatch.setattr(orchestrate, "analyze_mic_tier", lambda segs, wav: _Tier())

    sig = orchestrate._me_signals([{"speaker": "S1"}], {"S1": _axis(0)}, tmp_path / f"{STEM}.wav",
                                  VoiceprintStore(path))

    assert sig.mic_me == "S1" and sig.voiceprint is None
    assert path.read_bytes() == before
    assert [r["outcome"] for r in emitted] == ["skipped"]
    assert emitted[0]["store"] == "voiceprint"


def test_a_healthy_voiceprint_still_enrolls(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    path = tmp_path / "vp.json"
    _print(path, 3)
    monkeypatch.setattr(orchestrate, "analyze_mic_tier", lambda segs, wav: _Tier())
    orchestrate._me_signals([{"speaker": "S1"}], {"S1": _axis(0)}, tmp_path / f"{STEM}.wav",
                            VoiceprintStore(path))
    assert VoiceprintStore(path).load()[1] == 4


def test_finalize_completes_over_an_unusable_roster_and_voiceprint(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, emitted: list[dict]
) -> None:
    """F093 at the stage level: finalize names nobody from the broken stores,
    leaves both files as they were, and says so, instead of failing."""
    roster_path, vp_path = tmp_path / "roster.json", tmp_path / "vp.json"
    roster_before = _corrupt(roster_path, "[1, 2]")
    vp_before = _corrupt(vp_path, '"x"')
    wav = tmp_path / f"{STEM}.wav"
    wav.write_bytes(b"")
    monkeypatch.setattr("mp.diarize.is_stereo_recording", lambda w: False)
    streamed = {
        "language": "en", "audio_path": str(wav), "audio_seconds": 9.0, "backend": "fluidaudio",
        "diarization": True, "diarization_failed": False, "streaming": False, "finalized": True,
        "segments": [{"start": 0.0, "end": 1.0, "text": "hi", "speaker": "speaker_0"},
                     {"start": 1.0, "end": 9.0, "text": "lots", "speaker": "speaker_1"}],
        "speaker_embeddings": {"speaker_0": _axis(0), "speaker_1": _axis(1)},
    }

    out = orchestrate.finalize_streamed_transcript(
        wav, streamed, user_label="Me",
        voiceprint_store=VoiceprintStore(vp_path), roster_store=RosterStore(roster_path),
    )

    assert out["json"].exists()
    assert roster_path.read_bytes() == roster_before and vp_path.read_bytes() == vp_before
    assert sorted((r["store"], r["outcome"]) for r in emitted) == [
        ("roster", "skipped"), ("voiceprint", "skipped"),
    ]


# ---------- summarize refuses an unreadable overlay -------------------------


class _Client:
    def summarize(self, *, system_prompt, transcript, model, max_tokens):
        raise AssertionError("summarize must not reach the model")


@pytest.mark.parametrize("suffix", [".speaker_labels.json", ".transcript_corrections.json", ".markers.json"])
def test_summarize_refuses_a_present_unreadable_overlay(
    tmp_path: Path, emitted: list[dict], suffix: str
) -> None:
    md = tmp_path / f"{STEM}.md"
    md.write_text("# Transcript\n\n**A**: hi\n")
    (tmp_path / f"{STEM}{suffix}").write_text("{ not json")

    with pytest.raises(summarize_mod.OverlayUnreadable, match="can't be read"):
        summarize_mod.summarize(md, cfg=Config(recording=Recording(output_dir=tmp_path)), client=_Client())

    assert not (tmp_path / f"{STEM}.summary.json").exists()
    assert [(r["outcome"], r["path_kind"]) for r in emitted] == [("refused", "library")]


def test_the_summarize_cli_exits_1_naming_the_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    md = tmp_path / f"{STEM}.md"
    md.write_text("# Transcript\n")
    (tmp_path / f"{STEM}.speaker_labels.json").write_text("[1]")
    monkeypatch.setattr(summarize_mod.entry, "prepare", lambda cfg=None, *a, **k: Config(
        recording=Recording(output_dir=tmp_path)))
    assert summarize_mod.main([str(md)]) == 1
    assert "speaker names file can't be read" in caplog.text


# ---------- doctor ----------------------------------------------------------


def test_doctor_warns_about_each_unusable_store(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    config = storage.config_dir(tmp_path)
    config.mkdir(parents=True)
    (config / "roster.json").write_text("[1]")
    (config / "voiceprint.json").write_text("{ not json")
    (config / "glossary.toml").write_text("[terms\n")
    doctor.check_user_stores(home=tmp_path)
    out = capsys.readouterr().out
    for name in ("roster.json", "voiceprint.json", "glossary.toml"):
        assert f"{name} can't be read" in out


def test_doctor_says_nothing_about_healthy_or_missing_stores(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    config = storage.config_dir(tmp_path)
    config.mkdir(parents=True)
    _print(config / "voiceprint.json", 2)
    doctor.check_user_stores(home=tmp_path)
    assert capsys.readouterr().out == ""



# ---------- the quarantine notice reaches the app (STOR9) ----------------------------


def test_a_cli_quarantine_notice_lands_in_the_notice_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """`mp roster enroll` printed where the old roster went to stdout, which the app never shows.
    The daemon names a per-spawn file in MP_NOTICE_PATH and posts each line it finds there."""
    from mp import roster_cmd

    roster = tmp_path / "roster.json"
    _corrupt(roster, "{ not json")
    monkeypatch.setattr("mp.roster.ROSTER_PATH", roster)
    wav = tmp_path / "20260101-120000.wav"
    wav.write_bytes(b"")
    (tmp_path / "20260101-120000.embeddings.json").write_text(
        json.dumps({"embeddings": {"THEM-A": _axis(0)}}), encoding="utf-8")
    notices = tmp_path / "spawn.notices"
    monkeypatch.setenv("MP_NOTICE_PATH", str(notices))

    assert roster_cmd.main(["enroll", "--name", "Ann", "--label", "THEM-A", "--wav", str(wav),
                            "--no-relabel"]) == 0
    lines = notices.read_text(encoding="utf-8").splitlines()
    assert len(lines) == 1
    assert "roster.json could not be parsed" in lines[0]
    assert ".corrupt-" in lines[0]
    assert str(tmp_path) not in lines[0], "the notice names the file, not the folder"


def test_post_notice_is_a_no_op_without_the_variable(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("MP_NOTICE_PATH", raising=False)
    storage.post_notice("nothing to show this to")
    assert list(tmp_path.iterdir()) == []
