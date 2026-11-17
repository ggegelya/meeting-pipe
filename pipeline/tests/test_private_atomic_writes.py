"""PIPE30: every writer of a library file (or a sink's copy of one) goes through
`storage.atomic_write_text`, so it lands 0600 under any umask and a kill mid-write
leaves the previous file whole. Plus the helper's own legs: the temp is created
at its final mode, the data is synced before the rename, and a killed writer's
temp is swept."""
from __future__ import annotations

import json
import os
import stat
import sys
import time
from datetime import date
from pathlib import Path

import pytest

from mp import corrections, digest, local_server, orchestrate, storage
from mp.config import Config
from mp.engine import EngineResult
from mp.publish_from_paste import publish_from_paste
from mp.publish_fs import FilesystemPublisher
from mp.publish_lan import LanPublisher, LanUnreachableError
from mp.publish_obsidian import ObsidianPublisher
from mp.publish_router import _write_publish_sidecar
from mp.schemas import MeetingSummary

STEM = "20260722-140312"

_PASTED = """# Weekly sync

## Summary
- We met.

## Decisions
- Ship it.

## Action Items
- [ ] **Alice**: send the doc

## Open Questions
- None.
"""


@pytest.fixture(autouse=True)
def _umask_022():
    old = os.umask(0o022)
    try:
        yield
    finally:
        os.umask(old)


def _mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def _summary() -> MeetingSummary:
    return MeetingSummary(title="Sync", summary=["s"], decisions=["Ship."], detected_language="en")


def _transcript(root: Path) -> Path:
    md = root / f"{STEM}.md"
    md.write_text("# Transcript\n\n**A**: hi\n", encoding="utf-8")
    return md


# ---------- each writer in scope item 1 lands 0600 ---------------------------


def test_the_corrections_writers_are_private(tmp_path: Path) -> None:
    run = corrections.write_run_sidecar(
        recordings_dir=tmp_path, stem=STEM, transcript_path=tmp_path / "t.md", transcript_chars=1,
        summary_json_path=tmp_path / "s.json", backend="local", model="m",
    )
    empty = corrections.write_empty_marker(recordings_dir=tmp_path, stem=STEM, reason="no_speech")
    run.chmod(0o644)
    corrections.set_publish_state(run, "full")
    assert (_mode(run), _mode(empty)) == (0o600, 0o600)
    assert json.loads(run.read_text())["publish_state"] == "full"


def test_the_publish_result_sidecar_is_private(tmp_path: Path) -> None:
    summary_json = tmp_path / f"{STEM}.summary.json"
    summary_json.write_text("{}")
    _write_publish_sidecar(summary_json, {"page_url": None, "sinks": {"filesystem": {}}})
    assert _mode(tmp_path / f"{STEM}.publish.json") == 0o600


def test_the_local_server_records_are_private(tmp_path: Path) -> None:
    local_server.write_marker(pid=4242, port=8765, model="some/model", home=tmp_path)
    local_server.write_token(8765, "t" * 43, 4242, tmp_path)
    assert _mode(local_server.marker_path(tmp_path)) == 0o600
    assert _mode(local_server.token_path(tmp_path)) == 0o600


def test_a_pasted_summary_is_written_private(tmp_path: Path) -> None:
    transcript = _transcript(tmp_path)
    (tmp_path / f"{STEM}.summary.md").write_text(_PASTED)
    cfg = Config()
    cfg.output.sinks = []
    publish_from_paste(transcript, cfg=cfg)
    assert _mode(tmp_path / f"{STEM}.summary.json") == 0o600
    assert _mode(tmp_path / f"{STEM}.summary.md") == 0o600


def test_the_manual_bundle_and_the_apple_sentinel_are_private(tmp_path: Path) -> None:
    md = _transcript(tmp_path)
    bundle = orchestrate._write_manual_bundle(md, char_count=90000, threshold=80000)
    assert _mode(bundle) == 0o600

    cfg = Config.model_validate({"summarization": {"backend": "apple_intelligence"}})
    wav = tmp_path / f"{STEM}.wav"
    t = {"md": md, "json": tmp_path / f"{STEM}.json"}
    assert orchestrate._check_apple_handoff(wav, t, "hi", cfg) is not None
    assert _mode(tmp_path / f"{STEM}.apple_pending.json") == 0o600


def test_the_digest_is_written_private(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    root = tmp_path / "raw"
    root.mkdir()
    stem = f"{date.today().strftime('%Y%m%d')}-120000"
    (root / f"{stem}.summary.json").write_text(json.dumps({
        "title": "M", "summary": ["s"], "decisions": ["a call"], "actions": [], "questions": [],
        "attendees": [], "detected_language": "en",
    }))
    (root / f"{stem}.meta.json").write_text(json.dumps({"schema_version": 1}))
    cfg = Config.model_validate({"summarization": {"backend": "local", "local_model": "fake"}})
    monkeypatch.setattr(digest.Config, "load", classmethod(lambda cls: cfg))
    monkeypatch.setattr(
        digest.engine, "complete_text",
        lambda cfg, **kw: EngineResult(text="- bullet", backend="local", model="fake"),
    )
    out = tmp_path / "digests"
    assert digest.main(["--dir", str(root), "--out-dir", str(out)]) == 0
    written = sorted(out.glob("digest-*"))
    assert written and all(_mode(p) == 0o600 for p in written)


def test_the_file_sinks_write_private_files(tmp_path: Path) -> None:
    md = _transcript(tmp_path)
    fs = FilesystemPublisher(output_dir=tmp_path / "out").upsert(
        summary=_summary(), transcript_md=md, sidecar_path=tmp_path / f"{STEM}.filesystem.json",
    )
    note = ObsidianPublisher(vault_path=tmp_path / "vault", folder="M", attach_audio=False).upsert(
        summary=_summary(), transcript_md=md, sidecar_path=tmp_path / f"{STEM}.obsidian.json",
    )
    share = tmp_path / "share"
    share.mkdir()
    LanPublisher(mount_path=share).upsert(
        summary=_summary(), transcript_md=md, sidecar_path=tmp_path / f"{STEM}.lan.json",
    )
    private = [
        Path(fs["page_id"]), *(tmp_path / "out").iterdir(), tmp_path / f"{STEM}.filesystem.json",
        Path(note["page_id"]), tmp_path / f"{STEM}.obsidian.json", tmp_path / f"{STEM}.lan.json",
    ]
    assert {p.name: _mode(p) for p in private} == {p.name: 0o600 for p in private}


# ---------- a kill between write and rename leaves the old file --------------


def _replace_fails(monkeypatch: pytest.MonkeyPatch) -> None:
    def boom(src, dst):
        raise OSError(28, "No space left on device")

    monkeypatch.setattr(storage.os, "replace", boom)


def test_a_failed_paste_write_leaves_the_previous_summary(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    transcript = _transcript(tmp_path)
    (tmp_path / f"{STEM}.summary.md").write_text(_PASTED)
    previous = tmp_path / f"{STEM}.summary.json"
    previous.write_text('{"title": "the one that was there"}')
    before = previous.read_bytes()
    cfg = Config()
    cfg.output.sinks = []
    _replace_fails(monkeypatch)

    with pytest.raises(OSError):
        publish_from_paste(transcript, cfg=cfg)

    assert previous.read_bytes() == before
    assert [p.name for p in tmp_path.iterdir() if ".tmp-" in p.name] == []


def test_a_failed_publish_state_write_leaves_the_run_sidecar(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    run = tmp_path / f"{STEM}.run.json"
    run.write_text(json.dumps({"stem": STEM}))
    before = run.read_bytes()
    _replace_fails(monkeypatch)

    with pytest.raises(OSError):
        corrections.set_publish_state(run, "full")

    assert run.read_bytes() == before


# ---------- the helper's own legs (performance-review amendment) -------------


def test_the_temp_is_created_at_its_final_mode_and_synced_before_the_rename(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    events: list[str] = []
    seen_modes: list[int] = []
    real_replace = os.replace
    real_fsync = os.fsync

    def replace(src, dst):
        seen_modes.append(stat.S_IMODE(os.stat(src).st_mode))
        events.append("replace")
        return real_replace(src, dst)

    def fsync(fd):
        events.append("fsync")
        return real_fsync(fd)

    monkeypatch.setattr(storage.os, "replace", replace)
    monkeypatch.setattr(storage.os, "fsync", fsync)
    if sys.platform == "darwin":
        import fcntl

        real_fcntl = fcntl.fcntl

        def recording_fcntl(fd, cmd, *args):
            if cmd == fcntl.F_FULLFSYNC:
                events.append("F_FULLFSYNC")
            return real_fcntl(fd, cmd, *args)

        monkeypatch.setattr(fcntl, "fcntl", recording_fcntl)

    storage.atomic_write_text(tmp_path / "a.json", "{}")
    storage.atomic_write_text(tmp_path / "b.md", "x", mode=0o644)

    synced = "F_FULLFSYNC" if sys.platform == "darwin" else "fsync"
    assert events == [synced, "replace", synced, "replace"]
    assert seen_modes == [0o600, 0o644]


def test_the_temp_never_follows_a_planted_symlink(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    victim = tmp_path / "victim.txt"
    victim.write_text("keep me")
    monkeypatch.setattr(storage.secrets, "token_hex", lambda _n: "fixed")
    (tmp_path / f".a.json{storage.TEMP_MARK}{os.getpid()}-fixed").symlink_to(victim)

    with pytest.raises(FileExistsError):
        storage.atomic_write_text(tmp_path / "a.json", "{}")

    assert victim.read_text() == "keep me"


def test_the_sweep_removes_only_a_stale_temp_of_this_stem(tmp_path: Path) -> None:
    stale = tmp_path / ".x.json.tmp-999"
    fresh = tmp_path / ".x.md.tmp-1000-ab12"
    other_stem = tmp_path / ".y.json.tmp-999"
    keeper = tmp_path / "x.json"
    for path in (stale, fresh, other_stem, keeper):
        path.write_text("t")
    two_hours_ago = time.time() - 7200
    for path in (stale, other_stem, keeper):
        os.utime(path, (two_hours_ago, two_hours_ago))

    assert storage.sweep_stale_temps(tmp_path, "x") == 1

    assert sorted(p.name for p in tmp_path.iterdir()) == sorted(
        [fresh.name, other_stem.name, keeper.name]
    )


# ---------- the LAN sink's own helper (security review, finding 9) -----------


def test_the_lan_writer_never_follows_a_planted_temp_symlink(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from mp import publish_lan

    share = tmp_path / "share"
    share.mkdir()
    victim = tmp_path / "victim.txt"
    victim.write_text("keep me")
    monkeypatch.setattr(publish_lan.secrets, "token_hex", lambda _n: "fixed")
    planted = share / f".{STEM}.summary.md.tmp-{os.getpid()}-fixed"
    planted.symlink_to(victim)

    with pytest.raises(FileExistsError):
        publish_lan._atomic_write(share / f"{STEM}.summary.md", "summary")

    assert victim.read_text() == "keep me"
    assert not (share / f"{STEM}.summary.md").exists()


def test_the_lan_writer_refuses_a_symlinked_target_folder(tmp_path: Path) -> None:
    from mp import publish_lan

    real = tmp_path / "elsewhere"
    real.mkdir()
    link = tmp_path / "share"
    link.symlink_to(real)

    with pytest.raises(LanUnreachableError, match="symbolic link"):
        publish_lan._atomic_write(link / f"{STEM}.summary.md", "summary")
    assert list(real.iterdir()) == []
