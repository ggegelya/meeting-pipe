"""SEC18: zero egress used to clamp only network calls. These pin the file-side halves:
a synced sink target at publish, the BYO bundle, and a backup to a synced destination.

A fake home under `tmp_path` with a `Library/CloudStorage/Dropbox-x` folder is a synced
root by `cloudsync`'s first rule, so no xattr stub is needed; `HOME` is pointed at it so
`detect_sync_provider`'s default home is the fake one.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from mp import backup as backup_mod
from mp.backup import BackupError, create_backup
from mp.config import Config
from mp.orchestrate import _check_byo
from mp.publish_router import (
    SYNCED_TARGET_REASON,
    all_sinks_failed,
    build_publishers,
    fanout,
    publish_state,
)
from mp.schemas import MeetingSummary


@pytest.fixture
def home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    h = tmp_path / "home"
    (h / "Library" / "CloudStorage" / "Dropbox-acme").mkdir(parents=True)
    monkeypatch.setenv("HOME", str(h))
    return h


def _synced(home: Path, *parts: str) -> Path:
    return home / "Library" / "CloudStorage" / "Dropbox-acme" / Path(*parts)


def _local(home: Path, *parts: str) -> Path:
    return home / "Meetings" / Path(*parts)


def _fs_cfg(target: Path, **modes: bool) -> Config:
    return Config.model_validate({
        "output": {"sinks": ["filesystem"]},
        "filesystem": {"output_dir": str(target)},
        "modes": modes,
    })


def _write_summary_json(path: Path) -> None:
    summary = MeetingSummary(
        title="Standup", summary=["a"], decisions=[], actions=[],
        questions=[], attendees=[], detected_language="en",
    )
    path.write_text(summary.model_dump_json(), encoding="utf-8")


# --- item 2: the synced-target gate -------------------------------------------------

def test_a_synced_filesystem_sink_is_not_built_under_zero_egress(home: Path) -> None:
    pubs = build_publishers(_fs_cfg(_synced(home, "published"), regulated_mode=True))
    assert [p.name for p in pubs] == ["filesystem"]
    with pytest.raises(RuntimeError, match=SYNCED_TARGET_REASON) as err:
        pubs[0].upsert()
    assert "Dropbox" in str(err.value)


def test_a_synced_sink_is_recorded_as_failed_with_the_reason(home: Path, tmp_path: Path) -> None:
    cfg = _fs_cfg(_synced(home, "published"), workflow_nda_mode=True)
    summary_json = tmp_path / "m.summary.json"
    _write_summary_json(summary_json)

    res = fanout(summary_json=summary_json, cfg=cfg, transcript_md=None)

    entry = res["sinks"]["filesystem"]
    assert entry["reason"] == SYNCED_TARGET_REASON
    assert entry["error_type"] == "SyncedTargetError"
    assert all_sinks_failed(res), "the exit-3 contract applies unchanged"
    assert publish_state(res) == "none"
    assert not (_synced(home, "published")).exists() or not any(_synced(home, "published").iterdir())
    on_disk = json.loads((tmp_path / "m.publish.json").read_text())
    assert on_disk["sinks"]["filesystem"]["reason"] == SYNCED_TARGET_REASON


def test_a_local_filesystem_sink_still_builds_under_zero_egress(home: Path) -> None:
    pubs = build_publishers(_fs_cfg(_local(home, "published"), regulated_mode=True))
    assert [p.name for p in pubs] == ["filesystem"]
    assert pubs[0].__class__.__name__ == "FilesystemPublisher"


def test_a_synced_filesystem_sink_publishes_as_before_outside_zero_egress(home: Path, tmp_path: Path) -> None:
    target = _synced(home, "published")
    cfg = _fs_cfg(target)
    pubs = build_publishers(cfg)
    assert pubs[0].__class__.__name__ == "FilesystemPublisher"
    summary_json = tmp_path / "m.summary.json"
    _write_summary_json(summary_json)
    res = fanout(summary_json=summary_json, cfg=cfg, transcript_md=None)
    assert not res["failures"]
    assert "reason" not in res["sinks"]["filesystem"]


# --- item 4: BYO under zero egress ---------------------------------------------------

def _byo_inputs(tmp_path: Path) -> tuple[Path, dict[str, Path], str]:
    wav = tmp_path / "20260716-100000.wav"
    wav.write_bytes(b"")
    md = tmp_path / "20260716-100000.md"
    md.write_text("transcript", encoding="utf-8")
    return wav, {"md": md, "json": tmp_path / "20260716-100000.json"}, "transcript"


@pytest.mark.parametrize("modes", [{"regulated_mode": True}, {"workflow_nda_mode": True}])
def test_byo_is_declined_under_zero_egress(tmp_path: Path, modes: dict[str, bool], monkeypatch) -> None:
    emitted: list[tuple] = []
    monkeypatch.setattr("mp.orchestrate.events.emit", lambda *a, **k: emitted.append((a, k)))
    wav, t, md_text = _byo_inputs(tmp_path)

    skip = _check_byo(wav, t, md_text, True, Config.model_validate({"modes": modes}))

    assert skip is None, "falls through to the on-device summary"
    assert not list(tmp_path.glob("*READY_FOR_MANUAL*"))
    assert emitted and emitted[0][0] == ("pipeline", "byo_refused")
    assert emitted[0][1]["reason"] == "byo_refused_zero_egress"


def test_byo_still_writes_the_bundle_outside_zero_egress(tmp_path: Path) -> None:
    wav, t, md_text = _byo_inputs(tmp_path)
    skip = _check_byo(wav, t, md_text, True, Config())
    assert skip is not None and skip["skipped"] == "byo"
    assert list(tmp_path.glob("*READY_FOR_MANUAL*"))


# --- item 5: backup to a synced destination -------------------------------------------

def _library(home: Path, *, nda: bool, plain: bool = True) -> Config:
    lib = _local(home, "raw")
    lib.mkdir(parents=True)
    if plain:
        (lib / "20260101-100000.md").write_text("# plain")
        (lib / "20260101-100000.meta.json").write_text("{}")
    if nda:
        (lib / "20260102-100000.md").write_text("# nda")
        (lib / "20260102-100000.meta.json").write_text('{"workflow_nda_mode": true}')
    return Config.model_validate({"recording": {"output_dir": str(lib)}})


def test_backup_to_a_synced_destination_is_refused_with_an_nda_meeting(home: Path) -> None:
    cfg = _library(home, nda=True)
    dest = _synced(home, "backups")
    with pytest.raises(BackupError, match="Dropbox"):
        create_backup(cfg, dest, home=home)
    assert not dest.exists(), "nothing was written"


def test_a_regulated_sidecar_also_triggers_the_refusal(home: Path) -> None:
    cfg = _library(home, nda=False)
    (Path(cfg.recording.output_dir) / "20260103-100000.md").write_text("# reg")
    (Path(cfg.recording.output_dir) / "20260103-100000.meta.json").write_text('{"regulated_mode": true}')
    with pytest.raises(BackupError, match="Dropbox"):
        create_backup(cfg, _synced(home, "backups"), home=home)


def test_backup_to_a_synced_destination_proceeds_with_no_confidential_meeting(home: Path) -> None:
    cfg = _library(home, nda=False)
    archive = create_backup(cfg, _synced(home, "backups"), home=home)
    assert archive.exists()


def test_backup_to_a_local_destination_proceeds_with_an_nda_meeting(home: Path, tmp_path: Path) -> None:
    cfg = _library(home, nda=True)
    archive = create_backup(cfg, tmp_path / "plain-drive", home=home)
    assert archive.exists()


def test_check_synced_destination_ignores_no_sidecar_meetings(home: Path) -> None:
    lib = _local(home, "raw")
    lib.mkdir(parents=True)
    (lib / "20260101-100000.md").write_text("# unknown posture, no sidecar")
    cfg = Config.model_validate({"recording": {"output_dir": str(lib)}})
    backup_mod.check_synced_destination(cfg, _synced(home, "backups"))


# --- item 1: one sink rule on both paths ------------------------------------------------

_SINK_FIXTURE = (
    Path(__file__).resolve().parents[2]
    / "daemon" / "Tests" / "MeetingPipeTests" / "Fixtures" / "sink-rule-golden.json"
)


def _cases() -> list[dict]:
    return json.loads(_SINK_FIXTURE.read_text())["cases"]


@pytest.mark.parametrize("case", _cases(), ids=lambda c: f"{c['configured']}-reg{c['regulated']}-nda{c['nda']}")
def test_the_sink_rule_matches_the_shared_table_on_both_paths(case: dict, tmp_path: Path) -> None:
    from mp.config import effective_sinks
    from mp.workflow import apply_overrides

    # Path 1: no sidecar, `effective_sinks` over the config as written.
    cfg = Config.model_validate({
        "output": {"sinks": case["configured"]},
        "modes": {"regulated_mode": case["regulated"], "workflow_nda_mode": case["nda"]},
    })
    assert effective_sinks(cfg) == case["expected"]

    # Path 2: the sidecar every recorded meeting takes, through `apply_overrides`. An NDA workflow
    # arrives as `workflow_nda_mode`, a regulated recording as `regulated_mode`.
    stem = "20260716-120000"
    meta: dict = {"workflow_sinks": case["configured"]}
    if case["regulated"]:
        meta["regulated_mode"] = True
    if case["nda"]:
        meta["workflow_nda_mode"] = True
    (tmp_path / f"{stem}.meta.json").write_text(json.dumps(meta), encoding="utf-8")
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    overlay = apply_overrides(Config(), wav)
    assert overlay.output.sinks == case["expected"]


def test_an_obsidian_only_workflow_under_regulated_mode_lands_in_the_filesystem_sink(tmp_path: Path) -> None:
    # G034: the Preferences copy named Notion and nothing else, while an Obsidian-only workflow
    # stopped reaching its vault. Pinned on both paths by the table above; named here for the case.
    from mp.config import effective_sinks

    cfg = Config.model_validate({"output": {"sinks": ["obsidian"]}, "modes": {"regulated_mode": True}})
    assert effective_sinks(cfg) == ["filesystem"]


def test_a_wav_only_nda_meeting_still_blocks_a_synced_backup(home: Path) -> None:
    # A recording whose transcription has not finished has audio and a sidecar but no `.md` or
    # `.summary.json`, so `visibility.library_stems` never lists it, and the archive still carries it.
    lib = _local(home, "raw")
    lib.mkdir(parents=True)
    (lib / "20260104-100000.wav").write_bytes(b"RIFF" + b"\0" * 64)
    (lib / "20260104-100000.meta.json").write_text('{"workflow_nda_mode": true}')
    cfg = Config.model_validate({"recording": {"output_dir": str(lib)}})
    with pytest.raises(BackupError, match="Dropbox"):
        create_backup(cfg, _synced(home, "backups"), home=home)


def test_only_a_synced_target_error_adds_a_reason_to_publish_json(tmp_path: Path) -> None:
    # `ssl.SSLError`, `URLError` and friends carry a `.reason` of their own; none of them is ours.
    class Boom(RuntimeError):
        reason = "something_else"

    class P:
        name = "filesystem"

        def upsert(self, **_kw):
            raise Boom("nope")

    summary_json = tmp_path / "m.summary.json"
    _write_summary_json(summary_json)
    res = fanout(summary_json=summary_json, cfg=Config(), transcript_md=None, publishers=[P()])
    assert "reason" not in res["sinks"]["filesystem"]
