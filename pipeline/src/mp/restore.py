"""`mp restore <archive>`: unpack a backup into this Mac's configured roots (STOR2).

The archive stores each root under a stable prefix (`library/`, `digests/`,
`config/`, `corrections/`) rather than an absolute path, so a new Mac with a
different library location restores correctly: destinations come from *this*
machine's config, not from wherever the backup was taken.

Nothing here touches the Keychain. The manifest names the managed items to
re-create (`MANAGED_SECRET_KEYS`, four today); `mp backup` never exported their
values and this never asks for them.
Per ADR 0003 a manual `cp -R` of the same roots works just as well, and the README
runbook says so.

Extraction uses tarfile's `data` filter, so a crafted member cannot write outside
its destination.

STOR5 added `--dry-run --json`, the machine-readable plan the in-app restore
(Preferences ▸ Storage) previews before it runs anything. It is the same walk the
real run makes, counting instead of extracting, so the confirm can name the blast
radius exactly rather than scraping it out of the prose report.
"""
from __future__ import annotations

import argparse
import json
import tarfile
from collections.abc import Iterator
from pathlib import Path
from typing import TypedDict

from . import entry, storage
from .backup import CONFIG_PRESERVED, EXCLUDED_NAMES, MANIFEST_NAME, backup_roots
from .config import Config


class RestoreError(Exception):
    """A refusal, phrased for the person at the terminal."""


#: Files that may already sit in the `config/` destination without it counting as
#: occupied. Restoring onto a new Mac is a catch-22 otherwise: the destination
#: roots come from `config.toml`, so `config.toml` has to exist first, which would
#: make the config root permanently "occupied".
_CONFIG_ALLOWED = {CONFIG_PRESERVED} | EXCLUDED_NAMES

#: How many example paths a plan carries per bucket. The counts are exact; the
#: samples are what let a preview *name* what comes back ("this meeting") rather
#: than only counting it, and a library of thousands of files must not turn the
#: payload into a file listing.
PLAN_SAMPLE_LIMIT = 20


class PlannedRoot(TypedDict):
    """One destination root inside a `RestorePlan`."""

    name: str
    prefix: str
    destination: str
    #: Files from the archive that would land here.
    files: int
    #: Of those, the ones with nothing at that path yet.
    added: int
    #: Of those, the ones already on disk, which the restore overwrites.
    replaced: int
    #: Whether this destination already holds files at all, which is what a plain
    #: `mp restore` (no `--force`) refuses over. Distinct from `replaced`: a
    #: library full of *other* meetings is occupied with nothing to replace.
    occupied: bool


class RestorePlan(TypedDict):
    """`mp restore --dry-run --json`: what restoring this archive here would do.

    Read by Swift's `RestorePlan` (daemon `RestoreFlow.swift`), which renders it
    as the confirm the owner presses before anything is written. Keys are a
    cross-language contract; adding or renaming one means touching both sides.
    """

    archive: str
    created_at: str
    audio_included: bool
    #: True when this Mac already has a `config.toml`, so the backup's copy is
    #: skipped and the library stays pointed where it is now.
    keeps_config_toml: bool
    total_files: int
    added: int
    replaced: int
    roots: list[PlannedRoot]
    #: Up to `PLAN_SAMPLE_LIMIT` archive-relative paths per bucket. The counts
    #: above are exact, so a shorter sample than its count means "and N more".
    added_sample: list[str]
    replaced_sample: list[str]


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


def _restorable_members(
    tar: tarfile.TarFile, destinations: dict[str, Path]
) -> Iterator[tuple[tarfile.TarInfo, str, Path, str]]:
    """Yield `(member, prefix, destination, relative)` for every member this Mac would write.

    The one home of the prefix dispatch and the `config.toml` carve-out, so the
    dry-run plan and the real run cannot drift into disagreeing about what a
    restore does.
    """
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
        yield member, prefix, destination, relative


def plan_restore(archive: Path, cfg: Config, *, home: Path | None = None) -> RestorePlan:
    """What restoring `archive` here would do, as the JSON payload the app previews (STOR5).

    Per root: how many files land, how many of those already exist on disk and
    would be replaced, and whether the destination is occupied at all (which is
    what a plain `mp restore` refuses over). Plus a capped sample of each bucket,
    so a preview can say *which* meeting comes back.

    Writes nothing, and refuses nothing: a preview whose whole job is to describe
    a conflict cannot be the thing that refuses one.
    """
    archive = archive.expanduser()
    if not archive.is_file():
        raise RestoreError(f"no archive at {archive}")
    manifest = read_manifest(archive)

    roots = backup_roots(cfg, home)
    destinations = {root.prefix: root.source for root in roots}
    counts = {root.prefix: {"files": 0, "added": 0, "replaced": 0} for root in roots}
    added_sample: list[str] = []
    replaced_sample: list[str] = []

    with tarfile.open(archive, "r:gz") as tar:
        for member, prefix, destination, relative in _restorable_members(tar, destinations):
            bucket = counts[prefix]
            bucket["files"] += 1
            if (destination / relative).exists():
                bucket["replaced"] += 1
                if len(replaced_sample) < PLAN_SAMPLE_LIMIT:
                    replaced_sample.append(member.name)
            else:
                bucket["added"] += 1
                if len(added_sample) < PLAN_SAMPLE_LIMIT:
                    added_sample.append(member.name)

    config_root = destinations["config"]
    return {
        "archive": str(archive),
        "created_at": manifest["created_at"],
        "audio_included": bool(manifest.get("audio_included", True)),
        # The backup's own config.toml is skipped whenever this Mac has one, so a
        # restore never repoints the library at the old Mac's paths.
        "keeps_config_toml": (config_root / CONFIG_PRESERVED).exists(),
        "total_files": sum(bucket["files"] for bucket in counts.values()),
        "added": sum(bucket["added"] for bucket in counts.values()),
        "replaced": sum(bucket["replaced"] for bucket in counts.values()),
        "roots": [
            {
                "name": root.name,
                "prefix": root.prefix,
                "destination": str(root.source),
                "files": counts[root.prefix]["files"],
                "added": counts[root.prefix]["added"],
                "replaced": counts[root.prefix]["replaced"],
                "occupied": _is_occupied(root.source, root.prefix),
            }
            for root in roots
        ],
        "added_sample": added_sample,
        "replaced_sample": replaced_sample,
    }


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
        for member, prefix, destination, relative in _restorable_members(tar, destinations):
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


def _report_plan(plan: RestorePlan, out: Path | None) -> int:
    """Emit the plan: to stdout, or to `out` with a readable trace left on stdout.

    The trace is not decoration. The daemon spawns this with `--out`, and
    everything the subprocess prints lands in `pipeline.log`, so a bare "wrote
    the plan" line would leave the log unable to say what the owner was shown.
    """
    payload = json.dumps(plan, indent=2)
    if out is None:
        print(payload)
        return 0
    out = out.expanduser()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(payload + "\n", encoding="utf-8")

    print(f"restore plan for {plan['archive']} -> {out}")
    print(f"  {plan['total_files']} files: {plan['added']} new, {plan['replaced']} replaced")
    for root in plan["roots"]:
        print(
            f"  {root['name']:12} {root['files']:>6} files "
            f"({root['replaced']} replaced) -> {root['destination']}"
        )
    return 0


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
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit the machine-readable plan (counts, conflicts) instead of the prose "
             "report. Describes a restore, so it needs --dry-run.",
    )
    parser.add_argument(
        "--out",
        type=Path,
        help="Write the --json plan here instead of stdout, which keeps the prose report.",
    )
    args = parser.parse_args(argv)

    # Checked before anything is resolved, so a wrong invocation costs nothing.
    if args.json and not args.dry_run:
        parser.error("--json describes what a restore would do; pass --dry-run too")
    if args.out and not args.json:
        parser.error("--out writes the --json plan; pass --json too")

    # SEC13: local-only work, but the entry contract is the entry contract.
    # `secrets=False`: a restore rebuilds files, the owner re-enters tokens.
    cfg = entry.prepare(secrets=False)

    if args.json:
        try:
            plan = plan_restore(args.archive, cfg)
        except RestoreError as exc:
            print(f"[FAIL] {exc}")
            return 1
        return _report_plan(plan, args.out)

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
