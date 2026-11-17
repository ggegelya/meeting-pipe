"""Disk-root resolution and sizing (STOR1).

Every root takes an injectable `home` so the whole tree can be pointed at a
`tmp_path`, which is how the backup/restore round-trip tests stay hermetic.
"""
from __future__ import annotations

import stat
from pathlib import Path

import pytest

from mp import storage


def test_atomic_write_text_writes_private_content(tmp_path: Path) -> None:
    target = tmp_path / "t.json"
    storage.atomic_write_text(target, '{"ok": true}')
    assert target.read_text(encoding="utf-8") == '{"ok": true}'
    assert stat.S_IMODE(target.stat().st_mode) == 0o600  # SEC14: user-private
    # No temp file left behind after the rename.
    assert not [p for p in tmp_path.iterdir() if ".tmp-" in p.name]


def test_atomic_write_text_leaves_prior_file_intact_on_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    target = tmp_path / "t.json"
    target.write_text("ORIGINAL", encoding="utf-8")

    def _boom(src, dst):
        raise OSError("simulated crash during rename")

    monkeypatch.setattr(storage.os, "replace", _boom)
    with pytest.raises(OSError):
        storage.atomic_write_text(target, "NEW")
    # The previous file survives untouched; no partial write, no temp orphan.
    assert target.read_text(encoding="utf-8") == "ORIGINAL"
    assert not [p for p in tmp_path.iterdir() if ".tmp-" in p.name]


def test_roots_are_derived_from_the_injected_home(tmp_path: Path) -> None:
    assert storage.app_support_dir(tmp_path) == tmp_path / "Library" / "Application Support" / "MeetingPipe"
    assert storage.corrections_dir(tmp_path).name == "corrections"
    assert storage.originals_dir(tmp_path).name == "originals"
    assert storage.waveform_cache_dir(tmp_path).parts[-2:] == ("MeetingPipe", "waveforms")
    assert storage.hf_hub_root(tmp_path) == tmp_path / ".cache" / "huggingface" / "hub"


def test_digests_sit_beside_the_recordings_dir_not_inside_it(tmp_path: Path) -> None:
    library = tmp_path / "Meetings" / "raw"
    assert storage.digests_dir(library) == tmp_path / "Meetings" / "digests"


def test_bytes_on_disk_sums_files_recursively(tmp_path: Path) -> None:
    (tmp_path / "nested").mkdir()
    (tmp_path / "a.bin").write_bytes(b"x" * 100)
    (tmp_path / "nested" / "b.bin").write_bytes(b"x" * 50)
    assert storage.bytes_on_disk(tmp_path) == 150


def test_bytes_on_disk_skips_symlinks(tmp_path: Path) -> None:
    # HuggingFace snapshots symlink back into blobs/; counting both double-counts.
    (tmp_path / "a.bin").write_bytes(b"x" * 100)
    (tmp_path / "link.bin").symlink_to(tmp_path / "a.bin")
    assert storage.bytes_on_disk(tmp_path) == 100


def test_bytes_on_disk_of_a_missing_path_is_zero(tmp_path: Path) -> None:
    assert storage.bytes_on_disk(tmp_path / "nope") == 0


def test_free_bytes_walks_up_to_an_existing_ancestor(tmp_path: Path) -> None:
    # A library dir that does not exist yet still reports its target volume.
    free = storage.free_bytes(tmp_path / "not" / "created" / "yet")
    assert free is not None and free > 0


def test_human_bytes_reads_like_the_daemons_formatter() -> None:
    assert storage.human_bytes(0) == "0 bytes"
    assert storage.human_bytes(999) == "999 bytes"
    assert storage.human_bytes(1_500) == "1.5 KB"
    assert storage.human_bytes(2_400_000_000) == "2.4 GB"
    assert storage.human_bytes(None) == "unknown"


# ---------- read_json_object (PIPE29) -----------------------------------------


def test_read_json_object_returns_the_object(tmp_path: Path) -> None:
    path = tmp_path / "x.json"
    path.write_text('{"a": 1}')
    assert storage.read_json_object(path) == {"a": 1}


@pytest.mark.parametrize("text", ["", "{not json", "\udcff"])
def test_read_json_object_is_none_for_a_file_that_does_not_parse(tmp_path: Path, text: str) -> None:
    path = tmp_path / "x.json"
    path.write_bytes(text.encode("utf-8", "surrogateescape"))
    assert storage.read_json_object(path) is None


def test_read_json_object_is_none_for_a_missing_file(tmp_path: Path) -> None:
    assert storage.read_json_object(tmp_path / "absent.json") is None


@pytest.mark.parametrize("text", ["[1]", '"x"', "5", "true", "null"])
def test_read_json_object_is_none_for_json_that_is_not_an_object_and_says_so(
    tmp_path: Path, text: str, caplog: pytest.LogCaptureFixture
) -> None:
    path = tmp_path / "x.json"
    path.write_text(text)
    with caplog.at_level("WARNING", logger="mp.storage"):
        assert storage.read_json_object(path) is None
    warnings = [r for r in caplog.records if r.levelname == "WARNING"]
    assert len(warnings) == 1
    assert str(path) in warnings[0].getMessage()


def test_load_json_object_tells_missing_from_unreadable(tmp_path: Path) -> None:
    """The tri-state STOR9's writers branch on; `read_json_object` collapses it."""
    assert storage.load_json_object(tmp_path / "absent.json").state == "missing"
    bad = tmp_path / "bad.json"
    bad.write_text("[1]")
    read = storage.load_json_object(bad)
    assert (read.state, read.kind) == ("unreadable", "parse")
    assert "list" in read.reason
    good = tmp_path / "good.json"
    good.write_text('{"k": 2}')
    assert storage.load_json_object(good).data == {"k": 2}
