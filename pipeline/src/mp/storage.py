"""Where meeting-pipe's state lives on disk, and how big it is.

One module owns the root paths so `mp doctor`, `mp backup`, and `mp restore`
cannot drift apart on what "the library" means. Every function takes an optional
`home` so tests can point the whole tree at a `tmp_path` without touching `$HOME`,
matching the injectable-path convention the roster and voiceprint stores use.
"""
from __future__ import annotations

import shutil
from pathlib import Path


def config_dir(home: Path | None = None) -> Path:
    """`~/.config/meeting-pipe/`: config.toml, workflows/, voiceprint, roster,
    glossary. Mirrors `config.CONFIG_PATH.parent` with an injectable home."""
    return (home or Path.home()) / ".config" / "meeting-pipe"


def backup_marker(home: Path | None = None) -> Path:
    """Stamped by `mp backup` so `mp doctor` can report the last backup's age."""
    return config_dir(home) / ".last-backup.json"


def app_support_dir(home: Path | None = None) -> Path:
    """`~/Library/Application Support/MeetingPipe/`: the corrections corpus and
    the kept pre-redaction originals."""
    return (home or Path.home()) / "Library" / "Application Support" / "MeetingPipe"


def corrections_dir(home: Path | None = None) -> Path:
    return app_support_dir(home) / "corrections"


def originals_dir(home: Path | None = None) -> Path:
    """Kept full recordings (ADR 0016). Sensitive at rest: 0600, excluded from
    Time Machine, reaped after 30 days, and never included in a backup."""
    return app_support_dir(home) / "originals"


def waveform_cache_dir(home: Path | None = None) -> Path:
    """Rebuildable peak data for the Library's Audio tab. Safe to delete."""
    return (home or Path.home()) / "Library" / "Caches" / "MeetingPipe" / "waveforms"


def hf_hub_root(home: Path | None = None) -> Path:
    """The HuggingFace model cache. Rebuildable via `mp prefetch-model`."""
    return (home or Path.home()) / ".cache" / "huggingface" / "hub"


def digests_dir(library_dir: Path) -> Path:
    """`digests/` sits beside the recordings dir, not inside it (see `digest.py`)."""
    return library_dir.parent / "digests"


def bytes_on_disk(path: Path) -> int:
    """Recursive size, skipping symlinks so HuggingFace snapshot links (which
    point back into `blobs/`) are not counted twice. Missing path reads as 0."""
    if not path.exists():
        return 0
    total = 0
    for child in path.rglob("*"):
        try:
            if child.is_file() and not child.is_symlink():
                total += child.stat().st_size
        except OSError:
            continue
    return total


def free_bytes(path: Path) -> int | None:
    """Free space on the volume holding `path`, walking up to the nearest existing
    ancestor so a not-yet-created library still reports its target volume."""
    probe = path
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    try:
        return shutil.disk_usage(probe).free
    except OSError:
        return None


def human_bytes(n: int | None) -> str:
    """`1.2 GB`, matching the daemon's ByteCountFormatter output closely enough
    that the two surfaces never look like they disagree."""
    if n is None:
        return "unknown"
    size = float(n)
    for unit in ("bytes", "KB", "MB", "GB", "TB"):
        if size < 1000 or unit == "TB":
            if unit == "bytes":
                return f"{int(size)} bytes"
            return f"{size:.1f} {unit}"
        size /= 1000
    return f"{size:.1f} TB"  # pragma: no cover - loop always returns
