"""`mp restore <archive>`: unpack a backup into this Mac's configured roots (STOR2).

The archive stores each root under a stable prefix (`library/`, `digests/`,
`config/`, `corrections/`) rather than an absolute path, so a new Mac with a
different library location restores correctly: destinations come from *this*
machine's config, not from wherever the backup was taken.

Nothing here touches the Keychain. The manifest names the three items to
re-create; `mp backup` never exported their values and this never asks for them.
Per ADR 0003 a manual `cp -R` of the same roots works just as well, and the README
runbook says so.

Extraction uses tarfile's `data` filter, so a crafted member cannot write outside
its destination.
"""
from __future__ import annotations

import argparse
import json
import tarfile
from pathlib import Path

from . import storage
from .backup import CONFIG_PRESERVED, EXCLUDED_NAMES, MANIFEST_NAME, backup_roots
from .config import Config
from .egress_guard import arm_for_config


class RestoreError(Exception):
    """A refusal, phrased for the person at the terminal."""


#: Files that may already sit in the `config/` destination without it counting as
#: occupied. Restoring onto a new Mac is a catch-22 otherwise: the destination
#: roots come from `config.toml`, so `config.toml` has to exist first, which would
#: make the config root permanently "occupied".
_CONFIG_ALLOWED = {CONFIG_PRESERVED} | EXCLUDED_NAMES


def read_manifest(archive: Path) -> dict:
    with tarfile.open(archive, "r:gz") as tar:
        try:
            member = tar.extractfile(MANIFEST_NAME)
        except KeyError as exc:  # pragma: no cover - tarfile raises on missing member
            raise RestoreError(f"{archive} has no {MANIFEST_NAME}; not a meeting-pipe backup") from exc
        if member is None:
            raise RestoreError(f"{archive} has no {MANIFEST_NAME}; not a meeting-pipe backup")
        return json.loads(member.read())


def _is_occupied(path: Path, prefix: str) -> bool:
    if not path.is_dir():
        return False
    allowed = _CONFIG_ALLOWED if prefix == "config" else set()
    return any(entry.name not in allowed for entry in path.iterdir())


def restore_archive(
    archive: Path,
    cfg: Config,
    *,
    home: Path | None = None,
    force: bool = False,
    dry_run: bool = False,
) -> dict[str, int]:
    """Extract each prefix into its configured root. Returns files-written per root.

    Refuses a non-empty destination unless `force`, because an unpack that merges a
    backup into a live library leaves neither one intact. The `config/` root is the
    exception: a new Mac must already carry a `config.toml` (it is what names these
    destinations), so that one file does not count as occupancy, and the backup's
    copy never overwrites it. Every other config file restores.
    """
    archive = archive.expanduser()
    if not archive.is_file():
        raise RestoreError(f"no archive at {archive}")
    read_manifest(archive)  # validate before touching anything

    destinations = {root.prefix: root.source for root in backup_roots(cfg, home)}
    if not force and not dry_run:
        for prefix, destination in destinations.items():
            if _is_occupied(destination, prefix):
                raise RestoreError(
                    f"{destination} already has files ({prefix}). "
                    "Move it aside, or pass --force to write into it."
                )

    written: dict[str, int] = {prefix: 0 for prefix in destinations}
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar.getmembers():
            if not member.isfile() or member.name == MANIFEST_NAME:
                continue
            prefix, _, relative = member.name.partition("/")
            destination = destinations.get(prefix)
            if destination is None or not relative:
                continue
            # Never repoint this Mac's library at the old Mac's paths.
            if (
                prefix == "config"
                and relative == CONFIG_PRESERVED
                and (destination / CONFIG_PRESERVED).exists()
            ):
                continue
            written[prefix] += 1
            if dry_run:
                continue
            destination.mkdir(parents=True, exist_ok=True)
            # Strip the prefix so `library/a.wav` lands at `<library>/a.wav`. A
            # traversing tail (`library/../../x`) survives that strip, so the
            # `data` filter is what actually rejects absolute paths and `..`
            # escapes. Surface its refusal as a RestoreError, not a traceback.
            member.name = relative
            try:
                tar.extract(member, path=destination, filter="data")
            except tarfile.FilterError as exc:
                raise RestoreError(
                    f"refusing to restore {archive}: a member would write outside "
                    f"{destination} ({exc})"
                ) from exc
    return written


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="mp restore",
        description="Unpack a meeting-pipe backup into this Mac's configured roots.",
    )
    parser.add_argument("archive", type=Path, help="A meeting-pipe-backup-*.tar.gz")
    parser.add_argument(
        "--dry-run", action="store_true", help="Show what would be written, and write nothing."
    )
    parser.add_argument(
        "--force", action="store_true", help="Write into destinations that already have files."
    )
    args = parser.parse_args(argv)

    cfg = Config.load()
    arm_for_config(cfg)

    try:
        manifest = read_manifest(args.archive.expanduser())
        written = restore_archive(
            args.archive, cfg, force=args.force, dry_run=args.dry_run
        )
    except RestoreError as exc:
        print(f"[FAIL] {exc}")
        return 1

    verb = "would restore" if args.dry_run else "restored"
    print(f"{verb} from {args.archive} (taken {manifest['created_at']})")
    for root in backup_roots(cfg):
        print(f"  {root.name:12} {written.get(root.prefix, 0):>6} files -> {root.source}")
    if not manifest.get("audio_included", True):
        print("  this backup carries no recordings (--no-audio); meetings restore without audio")
    if (storage.config_dir() / "config.toml").exists():
        print("  kept your existing config.toml; the backup's copy names the old Mac's paths")

    keychain = manifest["keychain"]
    print()
    print("Secrets were never in the backup. Re-create them now:")
    for account in keychain["accounts"]:
        print(f"  security add-generic-password -U -s {keychain['service']} -a {account} -w '<value>'")
    print()
    print(f"Then run `mp doctor`. Last-backup marker: {storage.backup_marker()}")
    return 0
