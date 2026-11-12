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
import re
import shutil
import tarfile
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from . import entry, events, storage
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
    estimate walks the same iterator, so the two cannot disagree on what goes in."""
    if not root.source.is_dir():
        return
    for path in sorted(root.source.rglob("*")):
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


def _existing_ancestor(path: Path) -> Path:
    """`path`, or the nearest ancestor that exists: what a new destination will
    be created inside, and so the volume it will land on."""
    path = path.expanduser().absolute()
    while not path.exists() and path != path.parent:
        path = path.parent
    return path


def _same_volume(a: Path, b: Path) -> bool:
    return _existing_ancestor(a).stat().st_dev == _existing_ancestor(b).stat().st_dev


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
    free = shutil.disk_usage(_existing_ancestor(destination)).free
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
    check_destination(destination)
    check_free_space(
        destination,
        needed=estimate_backup_bytes(cfg, include_audio=include_audio, home=home),
        library=cfg.recording.output_dir,
    )
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / f"meeting-pipe-backup-{now.strftime(ARCHIVE_TIMESTAMP_FORMAT)}.tar.gz"
    partial = archive.with_name(archive.name + PARTIAL_SUFFIX)

    entries: list[dict[str, object]] = []
    # "x": never write into another run's `.partial`. Opened outside the `try` so
    # a collision cannot delete the file this run did not create.
    raw = open(partial, "xb")
    try:
        with raw:
            # compresslevel=1: see the module docstring. `name` is the final one,
            # so the gzip header never records `.partial`.
            with tarfile.open(name=str(archive), mode="w:gz", fileobj=raw, compresslevel=1) as tar:
                for root in backup_roots(cfg, home):
                    entries.append(_add_root(tar, root, include_audio=include_audio))

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
        }, indent=2),
    )

    try:
        pruned, pruned_bytes = prune_old_backups(destination, written=archive, now=now)
    except OSError:  # the backup itself is done; retention retries next run
        pruned, pruned_bytes = 0, 0
    if pruned:
        events.emit("pipeline", "backup_pruned", count=pruned, bytes=pruned_bytes)
    return BackupResult(archive, manifest, pruned, pruned_bytes)


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
        print(f"[FAIL] {exc}")
        return 1

    # STOR12: printed from the manifest this run built. Reading it back out of
    # the archive meant decompressing the whole thing again for a summary.
    archive, manifest = result.archive, result.manifest
    print(f"wrote {archive}  ({storage.human_bytes(archive.stat().st_size)})")
    for root in manifest["roots"]:
        print(f"  {root['name']:12} {root['files']:>6} files  {storage.human_bytes(root['bytes'])}")
    if not include_audio:
        print("  recordings were skipped (--no-audio)")
    print(f"  pruned {result.pruned} older backups ({storage.human_bytes(result.pruned_bytes)})")
    print()
    print("Keychain items are named in the manifest but never exported. Re-create them by hand:")
    keychain = manifest["keychain"]
    for account in keychain["accounts"]:
        print(f"  security add-generic-password -U -s {keychain['service']} -a {account} -w '<value>'")
    return 0
