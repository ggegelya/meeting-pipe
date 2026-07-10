"""LAN sink (TECH-FEAT1).

A first-class publisher for a mounted SMB/NFS share, instead of pointing the
plain filesystem sink at a network mount. Two things the filesystem sink does
not do matter on a share:

  - Reachability. We never create the mount root ourselves; if the share is not
    mounted, a plain `mkdir(parents=True)` would silently write to local disk
    where the mount point should be. Instead we require the target (or its
    parent) to already exist and be writable, and raise `LanUnreachableError`
    otherwise so `fanout` records the sink as failed without blocking the
    others.
  - Atomic writes. Other tools watch the share; a half-written file read
    mid-flush is worse over the network. Each file is written to a sibling
    temp file and `os.replace`d into place (an atomic same-directory rename).

The rendered files are identical to the filesystem sink (summary, transcript,
actions), reusing its renderer so the two never drift. On-prem, no cloud
metering, so this sink is allowed under regulated mode.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
from pathlib import Path
from typing import Any

from .markdown import render_summary_md
from .publish_fs import (
    file_url,
    load_sidecar,
    now_iso,
    stem_from_summary,
)
from .schemas import MeetingSummary

log = logging.getLogger("mp.publish_lan")


class LanUnreachableError(RuntimeError):
    """The configured LAN share is not mounted / not writable."""


class LanPublisher:
    """Writes summary + transcript + actions to a mounted share, atomically."""

    name = "lan"

    def __init__(self, *, mount_path: Path, host: str = "") -> None:
        # No `.resolve()`: a share mount point should be used as configured,
        # not canonicalised through symlinks that may themselves be on the share.
        self._mount = mount_path.expanduser()
        self._host = host

    def upsert(
        self,
        *,
        summary: MeetingSummary,
        transcript_md: Path | None,
        sidecar_path: Path,
    ) -> dict[str, Any]:
        target = self._check_reachable()
        target.mkdir(parents=True, exist_ok=True)
        stem = transcript_md.stem if transcript_md else stem_from_summary(summary)

        summary_md = render_summary_md(summary)
        actions_json = json.dumps(
            [a.model_dump(mode="json") for a in summary.actions],
            indent=2, sort_keys=True,
        )
        transcript_text = (
            transcript_md.read_text(encoding="utf-8") if transcript_md and transcript_md.exists() else ""
        )

        signature = hashlib.sha256(
            (summary_md + "\n---\n" + actions_json + "\n---\n" + transcript_text).encode("utf-8")
        ).hexdigest()

        existing = load_sidecar(sidecar_path)
        if existing and existing.get("signature_sha256") == signature:
            log.info("lan sink unchanged, skipping write (sha=%s...)", signature[:8])
            return {
                "page_id": existing.get("summary_path"),
                "page_url": file_url(Path(existing["summary_path"])) if existing.get("summary_path") else None,
                "idempotent": True,
                "local": True,
            }

        summary_path = target / f"{stem}.summary.md"
        actions_path = target / f"{stem}.actions.json"
        _atomic_write(summary_path, summary_md)
        _atomic_write(actions_path, actions_json)
        if transcript_text:
            _atomic_write(target / f"{stem}.transcript.md", transcript_text)

        sidecar_path.parent.mkdir(parents=True, exist_ok=True)
        sidecar_path.write_text(
            json.dumps({
                "schema_version": 1,
                "summary_path": str(summary_path),
                "actions_path": str(actions_path),
                "mount_path": str(target),
                "signature_sha256": signature,
                "ts": now_iso(),
            }, indent=2, sort_keys=True),
            encoding="utf-8",
        )

        return {
            "page_id": str(summary_path),
            "page_url": file_url(summary_path),
            "idempotent": False,
            "local": True,
        }

    def _check_reachable(self) -> Path:
        """Return the target dir once the share is confirmed mounted + writable.

        Never walks past the immediate parent: if the share is down, the mount
        point's parent is missing or read-only, and we refuse rather than create
        a local directory tree the user would never find.
        """
        target = self._mount
        if target.exists():
            if not target.is_dir():
                raise LanUnreachableError(f"LAN target {target} exists but is not a directory")
            if not os.access(target, os.W_OK):
                raise LanUnreachableError(f"LAN target {target} is not writable")
            return target
        parent = target.parent
        if not parent.exists() or not parent.is_dir() or not os.access(parent, os.W_OK):
            where = f" (host {self._host})" if self._host else ""
            raise LanUnreachableError(
                f"LAN share not mounted or not writable at {target}{where}: "
                f"parent {parent} is missing or read-only"
            )
        return target


def _atomic_write(path: Path, text: str) -> None:
    """Write `text` to `path` via a sibling temp file + atomic rename, so a
    reader on the share never sees a partial file."""
    tmp = path.parent / f".{path.name}.tmp-{os.getpid()}"
    try:
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            try:
                tmp.unlink()
            except OSError:
                pass
