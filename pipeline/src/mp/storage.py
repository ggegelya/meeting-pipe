"""Where meeting-pipe's state lives on disk, and how big it is.

One module owns the root paths so `mp doctor`, `mp backup`, and `mp restore`
cannot drift apart on what "the library" means. Every function takes an optional
`home` so tests can point the whole tree at a `tmp_path` without touching `$HOME`,
matching the injectable-path convention the roster and voiceprint stores use.
"""
from __future__ import annotations

import errno as errno_mod
import json
import logging
import os
import secrets
import shutil
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Literal

log = logging.getLogger(__name__)


def ensure_private_dir(path: Path, mode: int = 0o700) -> Path:
    """Create `path` (and parents) and make sure the directory itself is `mode`,
    tightening one that already exists looser, e.g. the 0755 `~/.config/meeting-pipe`
    an older installer made (SEC22). Only the leaf is touched: parents keep whatever
    the OS gave them. A directory we cannot chmod (not ours) is left as it is."""
    path = Path(path)
    path.mkdir(parents=True, exist_ok=True, mode=mode)
    try:
        if (path.stat().st_mode & 0o777) != mode:
            os.chmod(path, mode)
    except OSError:
        pass
    return path


def atomic_write_text(path: Path, text: str, *, mode: int = 0o600) -> None:
    """Write `text` to `path` atomically: a sibling temp file, chmod, then
    `os.replace` (an atomic same-directory rename).

    A crash mid-write leaves the previous file intact rather than a truncated
    one, so a reader (or a retry) never parses a half-written transcript/summary.
    Mirrors the Swift stores and the embeddings sidecar, which all rename into
    place. `mode` defaults to 0600 because the files this guards (transcripts,
    summaries) carry meeting content and stay user-private (SEC14)."""
    path = Path(path)
    # PIPE30: created at `mode` (O_EXCL, so never an existing file and never a
    # planted symlink), so the temp is not wider than `mode` for even an instant;
    # a random tail keeps two writers in one process apart. `fchmod` because
    # O_CREAT's mode is filtered by the umask.
    tmp = path.with_name(f".{path.name}{TEMP_MARK}{os.getpid()}-{secrets.token_hex(4)}")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        with os.fdopen(fd, "wb") as fh:
            os.fchmod(fh.fileno(), mode)
            fh.write(text.encode("utf-8"))
            fh.flush()
            full_sync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise


#: Every temp `atomic_write_text` makes is named `.<name>` + this + `<pid>-<hex>`.
TEMP_MARK = ".tmp-"

#: A temp older than this is a writer a SIGKILL stopped, not one still writing.
STALE_TEMP_AGE_S = 3600


def full_sync(fd: int) -> None:
    """Force `fd`'s data to stable storage before a rename publishes it (PIPE30).

    On macOS `fsync` only reaches the drive's cache; `F_FULLFSYNC` is what
    survives a power loss, so a rename cannot outlive the bytes it points at.
    A filesystem that refuses it (some network shares) falls back to `fsync`.
    """
    if sys.platform == "darwin":
        import fcntl

        try:
            fcntl.fcntl(fd, fcntl.F_FULLFSYNC)
            return
        except OSError:
            pass
    os.fsync(fd)


def sweep_stale_temps(directory: Path, stem: str, *, now: float | None = None) -> int:
    """Delete `atomic_write_text` temps for `stem` that a killed writer left (PIPE30).

    Only `.<stem>*.tmp-*` files older than `STALE_TEMP_AGE_S` go: the age guard
    keeps a writer that is mid-write right now. Returns how many were removed.
    Called at the start of `run-all` and `summarize` for their stem.
    """
    clock = time.time() if now is None else now
    removed = 0
    try:
        candidates = list(Path(directory).glob(f".{stem}*{TEMP_MARK}*"))
    except OSError:
        return 0
    for path in candidates:
        try:
            if path.is_symlink() or not path.is_file():
                continue
            if clock - path.stat().st_mtime <= STALE_TEMP_AGE_S:
                continue
            path.unlink()
        except OSError:
            continue
        removed += 1
    return removed


@dataclass(frozen=True)
class JsonRead:
    """One read of a JSON-object file: `missing` (ENOENT only), `ok` with `data`,
    or `unreadable` with `kind` "io" (any other OSError, `errno` named) or
    "parse" (not JSON, or JSON whose top level is not an object)."""

    state: Literal["missing", "ok", "unreadable"]
    data: dict[str, Any] | None = None
    kind: Literal["io", "parse"] | None = None
    errno: str | None = None
    reason: str = ""
    #: Valid JSON with a non-object top level: the one case nothing used to log.
    not_object: bool = False


def load_json_object(path: Path) -> JsonRead:
    """Read `path` as a JSON object, telling missing from unreadable (PIPE29).

    The seam a writer branches on (STOR9: missing is empty, unreadable is not);
    a reader that only wants the dict calls `read_json_object`. Never raises.
    """
    try:
        raw = Path(path).read_bytes()
    except FileNotFoundError:
        return JsonRead("missing")
    except OSError as e:
        name = errno_mod.errorcode.get(e.errno, str(e.errno)) if e.errno is not None else None
        return JsonRead("unreadable", kind="io", errno=name, reason=str(e))
    try:
        obj = json.loads(raw.decode("utf-8"))
    except ValueError as e:  # JSONDecodeError and UnicodeDecodeError both derive from it
        return JsonRead("unreadable", kind="parse", reason=str(e))
    if not isinstance(obj, dict):
        return JsonRead("unreadable", kind="parse", not_object=True,
                        reason=f"top level is {type(obj).__name__}, not an object")
    return JsonRead("ok", data=obj)


def read_json_object(path: Path) -> dict[str, Any] | None:
    """The JSON object in `path`, or None when the file is missing, unreadable,
    not valid JSON, or valid JSON whose top level is not an object (PIPE29).

    The one reader for per-meeting and config JSON that a caller then `.get`s:
    a list or string there used to reach that `.get` and crash every
    library-wide command over one hand-edited file. Only the not-an-object case
    logs here, since nothing else said so; a caller that already warns about an
    unreadable file keeps its own line.
    """
    read = load_json_object(path)
    if read.not_object:
        log.warning("%s holds JSON whose %s; ignoring it", path, read.reason)
    return read.data


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


#: REC20: the window the library's growth is measured over, and the projection
#: under which `mp doctor` warns. Mirrors Swift's `LibraryGrowth`.
GROWTH_WINDOW_DAYS = 30
GROWTH_WARN_DAYS = 30


#: A recording's working files (capture intermediates, the merge in progress):
#: about 2 GB an hour while a meeting runs and gone minutes after it stops, so
#: not growth. Mirrors `LibraryGrowth.transientSuffixes`.
TRANSIENT_SUFFIXES = (".mic.wav", ".system.wav", ".merging.wav")


def _stem_date(name: str) -> datetime | None:
    """The recording stem a library file belongs to, from the first 15
    characters of its name (`20260722-140312 Export.wav` dates by its prefix),
    or None for a file that is not growth. Mirrors
    `LibraryGrowth.stemDate(ofFileNamed:)`."""
    if name.endswith(TRANSIENT_SUFFIXES):
        return None
    try:
        return datetime.strptime(name[:15], "%Y%m%d-%H%M%S") if len(name) >= 15 else None
    except ValueError:
        return None


def library_growth(library: Path, now: datetime | None = None) -> int:
    """Bytes the library grew by over the last `GROWTH_WINDOW_DAYS` (REC20).

    Every top-level file whose name starts with a recording stem dated inside
    the window, sidecars included; subfolders and anything not named for a stem
    are not growth. The same definition as the daemon's Storage pane, so the two
    surfaces project the same number. Stems are local wall-clock times, so `now`
    is naive local time too.
    """
    now = now or datetime.now()
    cutoff = now - timedelta(days=GROWTH_WINDOW_DAYS)
    if not library.is_dir():
        return 0
    total = 0
    for child in library.iterdir():
        started = _stem_date(child.name)
        if started is None or not (cutoff < started <= now):
            continue
        try:
            if child.is_file() and not child.is_symlink():
                total += child.stat().st_size
        except OSError:
            continue
    return total


def days_of_free_space(growth_bytes: int, free: int | None) -> float | None:
    """Days until `free` is gone at the window's rate; None with no growth or no
    free-space reading. Mirrors `LibraryGrowth.Projection.daysOfFreeSpace`."""
    if growth_bytes <= 0 or not free or free <= 0:
        return None
    return free / (growth_bytes / GROWTH_WINDOW_DAYS)


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
