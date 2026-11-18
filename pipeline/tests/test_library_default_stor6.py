"""STOR6: the library defaults moved out of iCloud's reach, and an existing library at the old
default stays where it is."""

from pathlib import Path

from mp import config
from mp.config import Config


def test_the_default_library_is_outside_documents() -> None:
    cfg = Config()
    assert cfg.recording.output_dir == Path("~/Meetings/raw").expanduser()
    assert cfg.filesystem.output_dir == "~/Meetings/published"
    assert "Documents" not in str(cfg.recording.output_dir)


def test_the_default_matches_the_swift_default() -> None:
    swift = Path(__file__).resolve().parents[2] / "daemon/Sources/MeetingPipe/ConfigDefaults.swift"
    text = swift.read_text(encoding="utf-8")
    assert f'static let outputDirPath = "{config.DEFAULT_OUTPUT_DIR}"' in text
    assert f'static let filesystemOutputDirPath = "{config.DEFAULT_PUBLISHED_DIR}"' in text
    assert 'static let legacyOutputDirPath = "~/Documents/Meetings/raw"' in text


def _write(path: Path, body: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    return path


def test_a_config_without_the_key_keeps_an_old_library_that_holds_files(tmp_path, monkeypatch) -> None:
    legacy = tmp_path / "Documents" / "Meetings" / "raw"
    legacy.mkdir(parents=True)
    (legacy / "20260101-090000.wav").write_bytes(b"")
    monkeypatch.setattr(config, "LEGACY_OUTPUT_DIR", str(legacy))
    cfg = Config.load(_write(tmp_path / "config.toml", "[summarization]\nbackend = \"local\"\n"))
    assert cfg.recording.output_dir == legacy


def test_an_empty_old_default_does_not_pin(tmp_path, monkeypatch) -> None:
    legacy = tmp_path / "Documents" / "Meetings" / "raw"
    legacy.mkdir(parents=True)
    (legacy / ".DS_Store").write_bytes(b"")
    monkeypatch.setattr(config, "LEGACY_OUTPUT_DIR", str(legacy))
    cfg = Config.load(_write(tmp_path / "config.toml", "[recording]\nauto_consent_apps = []\n"))
    assert cfg.recording.output_dir == Path("~/Meetings/raw").expanduser()


def test_a_named_path_always_wins(tmp_path, monkeypatch) -> None:
    legacy = tmp_path / "old"
    legacy.mkdir()
    (legacy / "x.wav").write_bytes(b"")
    monkeypatch.setattr(config, "LEGACY_OUTPUT_DIR", str(legacy))
    cfg = Config.load(_write(tmp_path / "config.toml", f"[recording]\noutput_dir = \"{tmp_path / 'mine'}\"\n"))
    assert cfg.recording.output_dir == tmp_path / "mine"


def test_a_missing_config_file_pins_too(tmp_path, monkeypatch) -> None:
    legacy = tmp_path / "old-published"
    legacy.mkdir()
    (legacy / "note.md").write_text("x", encoding="utf-8")
    monkeypatch.setattr(config, "LEGACY_PUBLISHED_DIR", str(legacy))
    cfg = Config.load(tmp_path / "absent.toml")
    assert cfg.filesystem.output_dir == str(legacy)
    assert cfg.recording.output_dir == Path("~/Meetings/raw").expanduser()
