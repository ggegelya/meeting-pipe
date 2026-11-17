"""`mp backup <dir>`: archive the state that cannot be recreated (STOR2).

meeting-pipe accumulates an irreplaceable corpus across four roots, and until now
had no backup story at all. What goes in:

- the library (`recording.output_dir`): recordings and every sidecar
- `digests/`, the generated weekly reviews
- `~/.config/meeting-pipe/`: config, workflows, voiceprint, roster, glossary
- the corrections corpus in `~/Library/Application Support/MeetingPipe/corrections/`

What deliberately stays out:

- **`originals/`**, the kept pre-redaction recordings. ADR 0016 makes them mode
  0600 and excludes them from Time Machine precisely because they are the most
  sensitive thing on disk. Writing them into a tarball the owner copies to a NAS
  would defeat the property that ADR establishes. The redacted recording in the
  library is the canonical artifact, and it is backed up.
- **`secrets.env`**, the legacy plaintext file SEC8 migrated into the Keychain.
- **Keychain values.** The manifest names the managed items to re-create (from
  `MANAGED_SECRET_KEYS`, four of them today); the secrets themselves are never
  exported. `mp restore` prints the commands.
- **`published/`** (republish regenerates it) and the caches (waveform peaks,
  HuggingFace models), which rebuild on demand.

STOR4 schedules this command as a launch agent, so it also has to fail loudly when
the destination drive is not mounted rather than quietly filling the boot disk;
`check_destination` is that guard.

Stdlib `tarfile`, no new dependency. Compression is `gzip` at level 1 on purpose:
JSON sidecars compress well even at level 1, and WAV barely compresses at any
level, so the default level 6 would burn minutes of CPU on a multi-gigabyte
library for almost nothing.

That same fact makes every archive about the library's size, and STOR4 runs this
daily, so a destination would fill unless something removed old ones (STOR12).
After a successful run `prune_old_backups` keeps the owner's chosen set (the
newest `KEEP_RECENT` plus one per ISO week for `KEEP_WEEKS` weeks before them),
and before writing anything `check_free_space` refuses a destination too full to
take the archive. The archive is written as `<name>.partial` and renamed into
place only once complete (STOR8 item 2), so a killed run never leaves a
truncated file under a name restore or retention would trust.
"""
from __future__ import annotations

import argparse
import io
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tarfile
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from . import egress_guard, entry, events, storage
from .config import KEYCHAIN_SERVICE, MANAGED_SECRET_KEYS, Config

MANIFEST_NAME = "manifest.json"
MANIFEST_SCHEMA_VERSION = 1

#: Where macOS mounts external and network volumes. See `check_destination`.
VOLUMES_ROOT = Path("/Volumes")

#: `meeting-pipe-backup-YYYYMMDD-HHMMSS.tar.gz`, exactly. Retention only ever
#: considers names matching this; a renamed archive is the owner keeping it.
ARCHIVE_TIMESTAMP_FORMAT = "%Y%m%d-%H%M%S"
ARCHIVE_NAME_RE = re.compile(r"meeting-pipe-backup-(\d{8}-\d{6})\.tar\.gz")
PARTIAL_SUFFIX = ".partial"

#: The owner's retention policy, chosen 2026-11-12 (STOR12 owner walkthrough):
#: keep the newest 7 archives, plus the newest archive of each of the 4 most
#: recent ISO weeks before the oldest of those 7. A daily schedule holds at most 11.
KEEP_RECENT = 7
KEEP_WEEKS = 4

#: A `.partial` is an archive still being written, or one a SIGKILL stranded
#: (no handler can clean that up). Past this age, by the timestamp in its name,
#: it is the latter.
STALE_PARTIAL_AGE = timedelta(hours=24)

#: Slack on top of the archive estimate for a destination on its own volume:
#: tar's 512-byte header and padding per file, and gzip's few bytes of framing.
BACKUP_HEADROOM_BYTES = 256 * 1024 * 1024

#: When the destination shares the library's volume, the space the next
#: recording needs stays free instead (REC20's figure): two hours of capture
#: intermediates (system 384,000 B/s plus mic 192,000 B/s) plus the 16 kHz
#: stereo final the stop-time merge writes beside them (64,000 B/s), about 4.6 GB.
RECORDING_RESERVE_BYTES = 2 * 3600 * (384_000 + 192_000 + 64_000)

#: STOR13: retention is skipped when the library holds fewer than this fraction
#: of the files the previous backup archived (same `audio_included`). Half is
#: far past anything the owner's own deletions do between two nightly runs, and
#: well short of the collapse an unplugged drive or a re-pointed recordings
#: folder causes, which is the case that would otherwise let a week of small
#: archives prune every archive that still held the recordings.
PRUNE_SHRINK_RATIO = 0.5

#: How many unreadable folders a refusal names before it only counts the rest.
UNREADABLE_NAMED = 5


class BackupError(Exception):
    """A refusal the caller can print, not a traceback."""

#: Never archived, whatever root it is found under. `secrets.env` is the legacy
#: plaintext file; `.last-backup.json` is a fact about *this* Mac, and restoring a
#: stale one would make doctor report a backup that never happened here.
EXCLUDED_NAMES = {"secrets.env", ".last-backup.json"}

#: `config.toml` names this machine's library path, so a restore must not clobber
#: the one the user just wrote on the new Mac. Everything else under `config/`
#: (workflows, roster, voiceprint, glossary) is machine-independent and restores.
CONFIG_PRESERVED = "config.toml"

#: Recording extensions, skipped under `--no-audio`. Mirrors Swift's
#: `MeetingStore.finalRecordingExtensions`.
AUDIO_SUFFIXES = {".wav", ".flac"}

EXCLUSIONS = [
    {
        "path": "originals/",
        "reason": "sensitive pre-redaction recordings; ADR 0016 excludes them from backups",
    },
    {"path": "secrets.env", "reason": "legacy plaintext secrets; superseded by the Keychain"},
    {"path": "published/", "reason": "regenerated by republish"},
    {"path": "caches", "reason": "waveform peaks and downloaded models rebuild on demand"},
]


@dataclass(frozen=True)
class Root:
    """One source directory and the prefix it takes inside the archive."""

    name: str
    prefix: str
    source: Path
    #: Only the library holds recordings, so only it honours `--no-audio`.
    holds_audio: bool = False


def backup_roots(cfg: Config, home: Path | None = None) -> list[Root]:
    library = cfg.recording.output_dir
    return [
        Root("library", "library", library, holds_audio=True),
        Root("digests", "digests", storage.digests_dir(library)),
        Root("config", "config", storage.config_dir(home)),
        Root("corrections", "corrections", storage.corrections_dir(home)),
    ]


def _should_include(path: Path, *, holds_audio: bool, include_audio: bool) -> bool:
    if path.name in EXCLUDED_NAMES:
        return False
    if holds_audio and not include_audio and path.suffix.lower() in AUDIO_SUFFIXES:
        return False
    return True


def _root_files(root: Root, *, include_audio: bool) -> Iterator[Path]:
    """Every file `_add_root` archives for `root`, in archive order. The free-space
    estimate walks the same iterator, so the two cannot disagree on what goes in.

    STOR13: `rglob` skipped a folder it could not list without a word, so a locked
    library subfolder simply fell out of the archive. `os.walk` reports it instead,
    and an unlistable folder under the library is a `BackupError` naming it. The
    other roots keep the old skip: nothing there has ever been unreadable, and a
    refusal over a cache-like folder would cost the library its backup."""
    if not root.source.is_dir():
        return
    unreadable: list[str] = []

    def note(error: OSError) -> None:
        unreadable.append(str(error.filename or error))

    found: list[Path] = []
    # followlinks=False: a symlinked folder is listed but never entered, as rglob did.
    for folder, _dirs, names in os.walk(root.source, onerror=note):
        found.extend(Path(folder) / name for name in names)
    if unreadable and root.holds_audio:
        named = ", ".join(unreadable[:UNREADABLE_NAMED])
        more = len(unreadable) - UNREADABLE_NAMED
        raise BackupError(
            f"could not read {len(unreadable)} folder(s) in your recordings folder ({named}"
            f"{f', and {more} more' if more > 0 else ''}), so their meetings would be missing "
            "from the backup. Fix their permissions in Finder (Get Info ▸ Sharing & Permissions) "
            "and back up again."
        )
    for path in sorted(found):
        if path.is_symlink() or not path.is_file():
            continue
        if not _should_include(path, holds_audio=root.holds_audio, include_audio=include_audio):
            continue
        yield path


def _add_root(tar: tarfile.TarFile, root: Root, *, include_audio: bool) -> dict[str, object]:
    """Archive one root, returning its manifest entry. A root that does not exist
    contributes an entry with zero files rather than being silently dropped, so a
    restore can tell "you had no digests" from "the backup forgot digests"."""
    files = 0
    total = 0
    for path in _root_files(root, include_audio=include_audio):
        arcname = f"{root.prefix}/{path.relative_to(root.source)}"
        tar.add(path, arcname=arcname, recursive=False)
        files += 1
        total += path.stat().st_size
    return {
        "name": root.name,
        "archive_prefix": root.prefix,
        "source": str(root.source),
        "files": files,
        "bytes": total,
    }


def build_manifest(
    root_entries: list[dict[str, object]], *, include_audio: bool, created_at: str
) -> dict[str, object]:
    from . import __version__

    return {
        "schema_version": MANIFEST_SCHEMA_VERSION,
        "created_at": created_at,
        "tool_version": __version__,
        "audio_included": include_audio,
        "roots": root_entries,
        "keychain": {
            "service": KEYCHAIN_SERVICE,
            "accounts": list(MANAGED_SECRET_KEYS),
            "note": (
                "Secret values are never exported. Re-create each item on the new Mac with: "
                f"security add-generic-password -U -s {KEYCHAIN_SERVICE} -a <ACCOUNT> -w <VALUE>"
            ),
        },
        "excluded": EXCLUSIONS,
    }


def check_library(cfg: Config) -> None:
    """Refuse a library root that is not a folder (STOR13).

    A missing root contributes zero files on purpose (`_add_root`), which is right
    for `digests` and wrong for the library: an unplugged drive or a re-pointed
    recordings folder archived as an empty library, stamped the marker, and let
    retention prune the archives that held the recordings.
    """
    library = Path(cfg.recording.output_dir).expanduser()
    if library.is_dir():
        return
    raise BackupError(
        f"your recordings folder {library} is not there, so this backup would hold no "
        "meetings. If it lives on an external drive, plug the drive in; if the recordings "
        "folder was changed in Preferences, point it back at your library."
    )


def _previous_backup(home: Path | None) -> dict[str, Any]:
    """The last run's marker, or `{}` when there is none or it does not parse.
    Only its `library_files` and `audio_included` are compared (STOR13)."""
    return storage.read_json_object(storage.backup_marker(home)) or {}


def _previous_library_files(previous: dict[str, Any], *, include_audio: bool) -> int | None:
    """The previous run's library count when it is comparable with this run's:
    an int (a pre-STOR13 marker has none) taken with the same `audio_included`."""
    count = previous.get("library_files")
    if isinstance(count, bool) or not isinstance(count, int):
        return None
    if previous.get("audio_included") is not include_audio:
        return None
    return count


def check_destination(destination: Path, *, volumes_root: Path | None = None) -> None:
    """Refuse a destination on an external volume that is not mounted (STOR4).

    `mkdir(parents=True)` cannot tell "the drive is unplugged" from "the folder is
    new": with the drive away it happily creates `/Volumes/Backups/…` as a plain
    directory on the boot disk, writes gigabytes there, stamps the marker, and
    reports success. Doctor and Preferences then show a fresh backup that is on
    the wrong disk, and the real drive gets mounted at `/Volumes/Backups 1` next
    time it is plugged in. Unattended scheduling is what makes this bite, because
    nobody is watching the run.

    The signature is narrow on purpose: only a *missing* volume root under
    `/Volumes` is refused. A mounted volume, or any path elsewhere, still creates
    its directories as before.
    """
    # Resolved here, not as a default argument, so a test can point the whole
    # check at a scratch tree by monkeypatching the module constant.
    volumes_root = volumes_root or VOLUMES_ROOT
    destination = destination.expanduser()
    if destination.exists() or volumes_root not in destination.parents:
        return
    # `/Volumes/<name>` is the mount point; anything deeper is a folder on it.
    volume = destination
    while volume.parent != volumes_root:
        volume = volume.parent
    if not volume.exists():
        raise BackupError(
            f"{volume} is not mounted, so {destination} would be created on the startup disk "
            "instead of the drive. Plug the drive in, or pick another destination."
        )


def check_synced_destination(cfg: Config, destination: Path) -> None:
    """Refuse a synced destination when the library holds a confidential meeting (SEC18).

    An archive carries every recording, transcript and voiceprint, so a destination a
    sync client owns uploads each NDA or regulated meeting in it, which is exactly what
    those two modes promise never happens. Narrow on purpose: only a meeting the
    visibility gate withholds as `nda` or `regulated` triggers it. `no_sidecar` meetings
    are unknown rather than confidential, and a library with none of either backs up to a
    synced folder as before (the Storage pane already warns about the folder, SEC35).
    """
    from .cloudsync import detect_sync_provider
    from .visibility import WITHHELD_NDA, WITHHELD_REGULATED, withheld_reason

    destination = destination.expanduser()
    provider = detect_sync_provider(destination)
    if provider is None:
        return
    # Every `<stem>.meta.json`, not `library_visibility`'s stem list: that one only finds stems
    # with transcript or summary text, and a recording whose transcription has not finished (or
    # failed) is still in the archive with its audio. The posture lives in the sidecar either way.
    library = Path(cfg.recording.output_dir).expanduser()
    stems = {p.name.removesuffix(".meta.json") for p in library.glob("*.meta.json")} if library.is_dir() else set()
    confidential = sorted(
        stem for stem in stems if withheld_reason(library, stem) in (WITHHELD_NDA, WITHHELD_REGULATED)
    )
    if not confidential:
        return
    raise BackupError(
        f"{destination} is synced by {provider.name}, and the library holds "
        f"{len(confidential)} NDA or regulated meeting(s) that promised nothing leaves this Mac. "
        "Every archive includes their recordings and transcripts, so the sync client would upload them. "
        "Pick a destination outside the synced tree."
    )


def estimate_backup_bytes(
    cfg: Config, *, include_audio: bool = True, home: Path | None = None
) -> int:
    """The bytes the archive will hold. An upper bound in practice: gzip level 1
    barely shrinks WAV, and sidecars shrink a lot (module docstring)."""
    return sum(
        path.stat().st_size
        for root in backup_roots(cfg, home)
        for path in _root_files(root, include_audio=include_audio)
    )


def existing_ancestor(path: Path) -> Path:
    """`path`, or the nearest ancestor that exists: what a new destination will
    be created inside, and so the volume it will land on."""
    path = path.expanduser().absolute()
    while not path.exists() and path != path.parent:
        path = path.parent
    return path


def _same_volume(a: Path, b: Path) -> bool:
    return existing_ancestor(a).stat().st_dev == existing_ancestor(b).stat().st_dev


def list_backups(destination: Path) -> list[tuple[datetime, Path]]:
    """The archives directly in `destination` whose names match the pattern
    exactly, newest first by the timestamp in the name (never mtime, which a copy
    or a restore from another drive rewrites). Anything else is not ours to count."""
    if not destination.is_dir():
        return []
    found: list[tuple[datetime, Path]] = []
    for path in destination.iterdir():
        match = ARCHIVE_NAME_RE.fullmatch(path.name)
        if match is None or not path.is_file():
            continue
        try:
            stamp = datetime.strptime(match.group(1), ARCHIVE_TIMESTAMP_FORMAT)
        except ValueError:  # 20261399-..., digits that are not a date
            continue
        found.append((stamp, path))
    found.sort(reverse=True)
    return found


def retained(stamps: list[datetime]) -> set[datetime]:
    """Which of `stamps` the owner's policy keeps (STOR12, chosen 2026-11-12).

    The newest `KEEP_RECENT`, plus, from the older rest, the newest archive in
    each of the `KEEP_WEEKS` most recent ISO weeks that are strictly before the
    week of the oldest of those `KEEP_RECENT`. A week with no archive does not
    use up a slot, so a drive left unplugged for a fortnight still leaves four
    older keepers. Pure, so the policy is pinned without touching a disk.
    """
    ordered = sorted(set(stamps), reverse=True)
    keep = set(ordered[:KEEP_RECENT])
    if len(ordered) <= KEEP_RECENT:
        return keep
    boundary = tuple(ordered[KEEP_RECENT - 1].isocalendar())[:2]
    weeks: set[tuple[int, ...]] = set()
    for stamp in ordered[KEEP_RECENT:]:
        if len(weeks) == KEEP_WEEKS:
            break
        week = tuple(stamp.isocalendar())[:2]
        if week >= boundary or week in weeks:
            continue
        weeks.add(week)
        keep.add(stamp)
    return keep


def _stamp_of_partial(name: str) -> datetime | None:
    if not name.endswith(PARTIAL_SUFFIX):
        return None
    match = ARCHIVE_NAME_RE.fullmatch(name[: -len(PARTIAL_SUFFIX)])
    if match is None:
        return None
    try:
        return datetime.strptime(match.group(1), ARCHIVE_TIMESTAMP_FORMAT)
    except ValueError:
        return None


def prune_old_backups(destination: Path, *, written: Path, now: datetime) -> tuple[int, int]:
    """Apply the retention policy to `destination` after a successful run.

    Never removes `written` (the archive this run just renamed into place), and
    also removes `.partial` leftovers whose name is older than
    `STALE_PARTIAL_AGE`. A file that will not delete is left for the next run
    rather than failing a backup that already succeeded. Returns the count and
    bytes of the archives removed.
    """
    archives = list_backups(destination)
    keep = retained([stamp for stamp, _ in archives])
    count = 0
    freed = 0
    for stamp, path in archives:
        if stamp in keep or path == written:
            continue
        try:
            size = path.stat().st_size
            path.unlink()
        except OSError:
            continue
        count += 1
        freed += size

    # The names carry the run's own clock, so compare against it the same way.
    clock = now.replace(tzinfo=None)
    for path in destination.iterdir():
        stamp = _stamp_of_partial(path.name)
        if stamp is None or clock - stamp <= STALE_PARTIAL_AGE:
            continue
        try:
            path.unlink()
        except OSError:
            continue
    return count, freed


def check_free_space(destination: Path, *, needed: int, library: Path) -> None:
    """Refuse, before anything is created, a destination without room (STOR12).

    The bar is the archive estimate plus headroom. On the library's own volume
    the headroom is `RECORDING_RESERVE_BYTES`, so a backup never takes the space
    the next recording needs; elsewhere it is `BACKUP_HEADROOM_BYTES`.
    """
    on_library_volume = _same_volume(destination, library)
    headroom = RECORDING_RESERVE_BYTES if on_library_volume else BACKUP_HEADROOM_BYTES
    free = shutil.disk_usage(existing_ancestor(destination)).free
    if free >= needed + headroom:
        return
    held = list_backups(destination)
    held_bytes = sum(path.stat().st_size for _, path in held)
    why = (
        f"and {storage.human_bytes(headroom)} has to stay free for the next recording, "
        "since this folder is on the same disk as your library"
        if on_library_volume
        else f"plus {storage.human_bytes(headroom)} of headroom"
    )
    raise BackupError(
        f"not enough room in {destination}: {storage.human_bytes(free)} free, and this backup "
        f"needs about {storage.human_bytes(needed)} {why}. The folder holds {len(held)} "
        f"backup archive(s) ({storage.human_bytes(held_bytes)}); delete older ones there, "
        "or pick a destination with more room."
    )


@dataclass(frozen=True)
class BackupResult:
    """What one successful run did. `manifest` is the one written into the
    archive, kept so the summary never has to read the archive back."""

    archive: Path
    manifest: dict[str, Any]
    pruned: int
    pruned_bytes: int
    #: STOR8: whether the destination's volume is encrypted; None when the probe
    #: could not tell. Recorded in the marker as `destination_encrypted`.
    destination_encrypted: bool | None = None
    #: STOR8: the mode of a destination folder that already existed and is readable
    #: by other accounts (left alone, but named in the summary); None otherwise.
    destination_open_mode: int | None = None
    #: STOR13: the library root's archived file count, recorded in the marker.
    library_files: int = 0
    #: STOR13: the previous marker's count when comparable, else None.
    previous_library_files: int | None = None
    #: STOR13: retention did not run because the library shrank past the ratio.
    prune_skipped: bool = False


DISKUTIL = "/usr/sbin/diskutil"


#: Filesystems that cannot be encrypted at all, so a volume of one of these types is
#: known not to be (the stick most backups go to is one of them).
UNENCRYPTABLE_FILESYSTEMS = frozenset({"msdos", "exfat", "hfs"})


def parse_diskutil_encryption(plist: bytes) -> bool | None:
    """Whether `diskutil info -plist <mount point>` describes an encrypted volume.

    `FileVault` is the per-volume answer for APFS, external encrypted volumes
    included. `Encryption` alone is not: an Apple Silicon Mac's internal volumes
    report it true from the always-on hardware encryption with FileVault off, which
    protects nothing once the Mac is unlocked, so it is read only when `FileVault`
    is absent. A FAT, exFAT or plain HFS+ volume is known unencrypted. An error
    plist (a network share is no disk to `diskutil`) or bytes that do not parse are
    unknown, never "encrypted".
    """
    try:
        info = plistlib.loads(plist)
    except Exception:  # noqa: BLE001 - any unreadable answer is "could not tell"
        return None
    if not isinstance(info, dict) or info.get("Error"):
        return None
    if isinstance(info.get("FileVault"), bool):
        return info["FileVault"]
    if info.get("FilesystemType") in UNENCRYPTABLE_FILESYSTEMS:
        return False
    if isinstance(info.get("Encryption"), bool):
        return info["Encryption"]
    return None


def destination_encrypted(destination: Path, run: Any = subprocess.run) -> bool | None:
    """Whether the volume `destination` is (or would be) on is encrypted (STOR8).

    `diskutil info` takes a mount point, not an arbitrary path, so `df -P` names
    the mount point of the nearest existing ancestor first. Any failure reads as
    None ("could not tell"), which warns like an unencrypted volume but is not
    claimed as one.
    """
    try:
        target = existing_ancestor(destination.expanduser())
        df = run(["/bin/df", "-P", str(target)], capture_output=True, text=True, timeout=10,
                 env=egress_guard.child_env())
        if df.returncode != 0:
            return None
        # The mount point is everything after the capacity column, so a space in
        # either the device name or the mount point survives.
        match = re.search(r"\s\d+%\s+(.+)$", df.stdout.rstrip("\n").splitlines()[-1])
        if match is None:
            return None
        mount = match.group(1)
        info = run([DISKUTIL, "info", "-plist", mount], capture_output=True, timeout=10,
                   env=egress_guard.child_env())
    except (OSError, subprocess.SubprocessError, IndexError, ValueError):
        return None
    out = info.stdout
    return parse_diskutil_encryption(out if isinstance(out, bytes) else str(out).encode("utf-8"))


def run_backup(
    cfg: Config,
    destination: Path,
    *,
    include_audio: bool = True,
    home: Path | None = None,
    now: datetime | None = None,
) -> BackupResult:
    """Write a dated archive into `destination`, stamp the marker, apply retention."""
    now = now or datetime.now(timezone.utc)
    destination = destination.expanduser()
    check_library(cfg)
    previous = _previous_library_files(_previous_backup(home), include_audio=include_audio)
    check_destination(destination)
    check_synced_destination(cfg, destination)
    check_free_space(
        destination,
        needed=estimate_backup_bytes(cfg, include_audio=include_audio, home=home),
        library=cfg.recording.output_dir,
    )
    encrypted = destination_encrypted(destination)
    # STOR8: the archive holds every transcript, recording and voiceprint, so it is
    # private by construction rather than by umask. A folder this run creates is
    # 0700; one that already exists is the owner's to set, and is only named.
    open_mode: int | None = None
    try:
        destination.mkdir(parents=True)
    except FileExistsError:
        mode = stat.S_IMODE(destination.stat().st_mode)
        open_mode = mode if mode & 0o044 else None
    else:
        try:
            os.chmod(destination, 0o700)
        except OSError:  # a share that refuses modes; the archive's own mode still applies
            pass
    archive = destination / f"meeting-pipe-backup-{now.strftime(ARCHIVE_TIMESTAMP_FORMAT)}.tar.gz"
    partial = archive.with_name(archive.name + PARTIAL_SUFFIX)

    entries: list[dict[str, object]] = []
    # O_EXCL: never write into another run's `.partial`; 0o600 whatever the umask
    # (STOR8). Opened outside the `try` so a collision cannot delete the file this
    # run did not create.
    raw = os.fdopen(os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb")
    try:
        with raw:
            # compresslevel=1: see the module docstring. `name` is the final one,
            # so the gzip header never records `.partial`.
            with tarfile.open(name=str(archive), mode="w:gz", fileobj=raw, compresslevel=1) as tar:
                library_files = 0
                for root in backup_roots(cfg, home):
                    root_entry = _add_root(tar, root, include_audio=include_audio)
                    entries.append(root_entry)
                    if root.holds_audio and isinstance(root_entry["files"], int):
                        library_files = root_entry["files"]

                if library_files == 0 and previous is not None and previous > 0:
                    # STOR13: before the rename, so the marker and every archive
                    # already in the destination stay exactly as they were.
                    raise BackupError(
                        f"your recordings folder {cfg.recording.output_dir} has 0 files, and the "
                        f"last backup had {previous}. Refusing to record an empty library as a "
                        "backup. If you really did delete every meeting, delete "
                        f"{storage.backup_marker(home)} and back up again."
                    )
                manifest = build_manifest(
                    entries, include_audio=include_audio, created_at=now.isoformat()
                )
                payload = json.dumps(manifest, indent=2).encode("utf-8")
                info = tarfile.TarInfo(MANIFEST_NAME)
                info.size = len(payload)
                info.mtime = int(now.timestamp())
                tar.addfile(info, io.BytesIO(payload))
            raw.flush()
            os.fsync(raw.fileno())
        os.replace(partial, archive)
    except BaseException:
        partial.unlink(missing_ok=True)
        raise

    marker = storage.backup_marker(home)
    marker.parent.mkdir(parents=True, exist_ok=True)
    storage.atomic_write_text(
        marker,
        json.dumps({
            "at": now.isoformat(),
            "archive": str(archive),
            "bytes": archive.stat().st_size,
            "audio_included": include_audio,
            "destination_encrypted": encrypted,
            "library_files": library_files,
        }, indent=2),
    )

    # STOR13: a true copy of what exists, so it is written and stamped, but a sharp
    # shrink keeps every older archive: those may be the only copies left.
    prune_skipped = previous is not None and library_files < previous * PRUNE_SHRINK_RATIO
    pruned, pruned_bytes = 0, 0
    if prune_skipped:
        events.emit("pipeline", "backup_prune_skipped",
                    library_files=library_files, previous_library_files=previous)
    else:
        try:
            pruned, pruned_bytes = prune_old_backups(destination, written=archive, now=now)
        except OSError:  # the backup itself is done; retention retries next run
            pass
        if pruned:
            events.emit("pipeline", "backup_pruned", count=pruned, bytes=pruned_bytes)
    return BackupResult(archive, manifest, pruned, pruned_bytes, encrypted, open_mode,
                        library_files, previous, prune_skipped)


def create_backup(
    cfg: Config,
    destination: Path,
    *,
    include_audio: bool = True,
    home: Path | None = None,
    now: datetime | None = None,
) -> Path:
    """`run_backup`, for a caller that wants only the archive's path."""
    return run_backup(
        cfg, destination, include_audio=include_audio, home=home, now=now
    ).archive


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="mp backup",
        description="Archive the meeting library, config, workflows, roster, and corrections.",
    )
    parser.add_argument("directory", type=Path, help="Where to write the dated archive.")
    parser.add_argument(
        "--no-audio",
        action="store_true",
        help="Skip recordings (.wav/.flac). Much smaller, but the restored Library "
             "shows meetings with no audio.",
    )
    args = parser.parse_args(argv)

    # SEC13: local-only work, but the entry contract is the entry contract.
    # `secrets=False`: a backup names the Keychain items, it never reads them.
    cfg = entry.prepare(secrets=False)

    include_audio = not args.no_audio
    try:
        result = run_backup(cfg, args.directory, include_audio=include_audio)
    except BackupError as exc:
        # STOR14: stderr, the only stream `runMP` keeps for the failure text.
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1

    # STOR12: printed from the manifest this run built. Reading it back out of
    # the archive meant decompressing the whole thing again for a summary.
    archive, manifest = result.archive, result.manifest
    # STOR8: said, not refused. The usual destination is an external drive or a
    # share nobody is watching, and the archive holds the whole corpus.
    if result.destination_encrypted is False:
        print(f"[WARN] {archive.parent} is not on an encrypted volume, and this archive holds every "
              "transcript, recording and voiceprint. Back up to a FileVault disk or an encrypted drive.")
    elif result.destination_encrypted is None:
        print(f"[WARN] could not tell whether {archive.parent} is on an encrypted volume. This archive "
              "holds every transcript, recording and voiceprint; keep it on an encrypted disk.")
    if result.destination_open_mode is not None:
        print(f"[WARN] {archive.parent} is readable by other accounts on this Mac "
              f"(mode {result.destination_open_mode:o}); the archive itself is mode 600.")
    print(f"wrote {archive}  ({storage.human_bytes(archive.stat().st_size)})")
    for root in manifest["roots"]:
        print(f"  {root['name']:12} {root['files']:>6} files  {storage.human_bytes(root['bytes'])}")
    if not include_audio:
        print("  recordings were skipped (--no-audio)")
    if result.prune_skipped:
        print(f"  retention skipped: library has {result.library_files} files, "
              f"last backup had {result.previous_library_files}")
    else:
        print(f"  pruned {result.pruned} older backups ({storage.human_bytes(result.pruned_bytes)})")
    print()
    print("Keychain items are named in the manifest but never exported. Re-create them by hand:")
    keychain = manifest["keychain"]
    for account in keychain["accounts"]:
        print(f"  security add-generic-password -U -s {keychain['service']} -a {account} -w '<value>'")
    return 0
