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
actions), reusing its renderer so the two never drift. Zero egress leaves only
the filesystem sink (SEC18), so this sink does not publish under regulated
mode or an NDA workflow.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import secrets
import stat
from pathlib import Path
from typing import Any

from . import storage
from .transcript_corrections import publish_text
from .markdown import deeplink_stem, render_summary_md
from .publish_fs import (
    file_url,
    load_sidecar,
    recorded_target_is_live,
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
        transcript_text: str | None = None,
    ) -> dict[str, Any]:
        target = self._check_reachable()
        stem = transcript_md.stem if transcript_md else stem_from_summary(summary)

        # AUTO2: same linked citations the filesystem sink writes; the deeplink
        # opens the app on the Mac reading the share, not on the share itself.
        summary_md = render_summary_md(summary, deeplink_stem(transcript_md))
        actions_json = json.dumps(
            [a.model_dump(mode="json") for a in summary.actions],
            indent=2, sort_keys=True,
        )
        if transcript_text is None:  # PIPE51: the overlaid view, as the filesystem sink
            transcript_text = publish_text(transcript_md)

        signature = hashlib.sha256(
            (summary_md + "\n---\n" + actions_json + "\n---\n" + transcript_text).encode("utf-8")
        ).hexdigest()

        existing = load_sidecar(sidecar_path)
        if (
            existing and existing.get("signature_sha256") == signature
            and recorded_target_is_live(existing, "mount_path", target)
        ):
            log.info("lan sink unchanged, skipping write (sha=%s...)", signature[:8])
            return {
                "page_id": existing.get("summary_path"),
                "page_url": file_url(Path(existing["summary_path"])) if existing.get("summary_path") else None,
                "idempotent": True,
                "local": True,
            }

        target.mkdir(parents=True, exist_ok=True)  # after the skip decision (PIPE31)
        summary_path = target / f"{stem}.summary.md"
        actions_path = target / f"{stem}.actions.json"
        _atomic_write(summary_path, summary_md)
        _atomic_write(actions_path, actions_json)
        if transcript_text:
            _atomic_write(target / f"{stem}.transcript.md", transcript_text)

        sidecar_path.parent.mkdir(parents=True, exist_ok=True)
        # The local sidecar lives in the library, so the library's rule (PIPE30).
        storage.atomic_write_text(sidecar_path, json.dumps({
            "schema_version": 1,
            "summary_path": str(summary_path),
            "actions_path": str(actions_path),
            "mount_path": str(target),
            "signature_sha256": signature,
            "ts": now_iso(),
        }, indent=2, sort_keys=True))

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
    reader on the share never sees a partial file.

    Its own helper rather than `storage.atomic_write_text` (PIPE30 item 2): a
    network share's modes are the share's, so this leaves them to the umask and
    the server instead of forcing 0600 on files other machines read.

    A peer with write access to the share could plant `.<name>.tmp-<pid>`
    symlinks to a path on this Mac, which a plain `write_text` follows (security
    review 2026-11-12, finding 9). So the temp takes a random tail and is opened
    `O_CREAT | O_EXCL | O_NOFOLLOW`, which refuses any existing name, a symlink
    included, and a symlinked target folder is refused outright.
    """
    parent = path.parent
    if stat.S_ISLNK(os.lstat(parent).st_mode):
        raise LanUnreachableError(f"LAN target {parent} is a symbolic link; refusing to write through it")
    tmp = parent / f".{path.name}.tmp-{os.getpid()}-{secrets.token_hex(4)}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o666)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(text.encode("utf-8"))
        os.replace(tmp, path)
    except BaseException:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise
