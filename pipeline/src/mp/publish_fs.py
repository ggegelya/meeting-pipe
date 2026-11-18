"""Filesystem publisher.

The simplest possible MeetingPublisher: dumps three files into a
configured output directory and stops.

  <stem>.summary.md     - the same human-readable summary that
                          summarize.py renders.
  <stem>.transcript.md  - copy of the speaker-segmented transcript
                          (when transcript_md is supplied).
  <stem>.actions.json   - just the action_items array, deduped from
                          the summary, for tools that watch a
                          directory and route action items elsewhere
                          (Hazel, Karabiner shortcuts, file-based
                          inboxes, etc.).

No frontmatter, no templating. The point of this sink is "any tool
that watches a directory" - the moment we add formatting we have
opinions about consumers.

Idempotency by content-hash, same shape as ObsidianPublisher's
sidecar so the orchestrator's two sinks parallel each other.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import storage
from .transcript_corrections import publish_text
from .markdown import deeplink_stem, render_summary_md
from .schemas import MeetingSummary

log = logging.getLogger("mp.publish_fs")


class FilesystemPublisher:
    """Dumps summary + transcript + actions into a directory.

    Construction takes a resolved output path. The orchestrator does
    config-to-fields mapping; tests pass a tmp_path directly.
    """

    name = "filesystem"

    def __init__(self, *, output_dir: Path) -> None:
        self._out = output_dir.expanduser().resolve()

    def upsert(
        self,
        *,
        summary: MeetingSummary,
        transcript_md: Path | None,
        sidecar_path: Path,
        transcript_text: str | None = None,
    ) -> dict[str, Any]:
        stem = transcript_md.stem if transcript_md else stem_from_summary(summary)

        # AUTO2: a Markdown-file sink, so its `[mm:ss]` citations link back into
        # the app. The signature below hashes the rendered text, so a note whose
        # links changed republishes rather than reading as unchanged.
        summary_md = render_summary_md(summary, deeplink_stem(transcript_md))
        actions_json = json.dumps(
            [a.model_dump(mode="json") for a in summary.actions],
            indent=2, sort_keys=True,
        )
        # PIPE51: the overlaid view, resolved once by `fanout`; the signature below
        # hashes it, so a Library correction republishes instead of reading unchanged.
        if transcript_text is None:
            transcript_text = publish_text(transcript_md)

        signature = hashlib.sha256(
            (summary_md + "\n---\n" + actions_json + "\n---\n" + transcript_text).encode("utf-8")
        ).hexdigest()

        existing = load_sidecar(sidecar_path)
        if (
            existing and existing.get("signature_sha256") == signature
            and recorded_target_is_live(existing, "output_dir", self._out)
        ):
            log.info("filesystem sink unchanged, skipping write (sha=%s...)", signature[:8])
            return {
                "page_id": existing.get("summary_path"),
                "page_url": file_url(Path(existing["summary_path"])) if existing.get("summary_path") else None,
                "idempotent": True,
                "local": True,
            }

        self._out.mkdir(parents=True, exist_ok=True)  # after the skip decision: a skip creates nothing
        summary_path = self._out / f"{stem}.summary.md"
        actions_path = self._out / f"{stem}.actions.json"
        # PIPE30: atomic and 0600; a truncated sidecar would read as absent and
        # the next publish would treat the meeting as new.
        storage.atomic_write_text(summary_path, summary_md)
        storage.atomic_write_text(actions_path, actions_json)
        if transcript_text:
            storage.atomic_write_text(self._out / f"{stem}.transcript.md", transcript_text)

        sidecar_path.parent.mkdir(parents=True, exist_ok=True)
        storage.atomic_write_text(sidecar_path, json.dumps({
            "schema_version": 1,
            "summary_path": str(summary_path),
            "actions_path": str(actions_path),
            "output_dir": str(self._out),
            "signature_sha256": signature,
            "ts": now_iso(),
        }, indent=2, sort_keys=True))

        return {
            "page_id": str(summary_path),
            "page_url": file_url(summary_path),
            "idempotent": False,
            "local": True,
        }


# ----- Helpers -----
#
# Public because the LAN sink (publish_lan) is a network-mount variant of this
# one and shares them. They were private and imported anyway (PIPE7).

def stem_from_summary(summary: MeetingSummary) -> str:
    # Used only when no transcript is provided (rare). Falls back to
    # an ISO timestamp prefix so two consecutive summaries with the
    # same title do not collide.
    safe = "".join(c if c.isalnum() else "-" for c in summary.title.lower())[:60].strip("-")
    return f"{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M')}-{safe or 'meeting'}"


def file_url(p: Path) -> str:
    """A `file://` URL for `p`. `Path.as_uri()` percent-encodes `#`, `%`, `?` and
    the rest; the hand-rolled version encoded only spaces, so a vault named
    `Vault #1` produced a URL whose path ended at the `#` (PIPE31)."""
    return Path(os.path.abspath(p)).as_uri()


def date_from_stem(stem: str | None) -> str | None:
    """The meeting's own local date, `YYYY-MM-DD`, from a `YYYYMMDD-HHMMSS` stem;
    None for a stem that carries no valid date. Sinks file a meeting under the day
    it happened, not the day it was published (PIPE31)."""
    m = re.match(r"^(\d{4})(\d{2})(\d{2})(?:\D|$)", stem or "")
    if m is None:
        return None
    try:
        return datetime(int(m[1]), int(m[2]), int(m[3])).date().isoformat()
    except ValueError:
        return None


def recorded_target_is_live(existing: dict[str, Any] | None, key: str, target: Path) -> bool:
    """PIPE31 (F090): an unchanged-content skip is only honest when the sidecar's
    recorded destination (`output_dir` / `mount_path`) is the one in use now and the
    summary file it recorded is still there. Otherwise the sink writes as if there
    were no sidecar."""
    if not existing or existing.get(key) != str(target):
        return False
    summary_path = existing.get("summary_path")
    return bool(summary_path) and Path(summary_path).exists()


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def load_sidecar(p: Path) -> dict[str, Any] | None:
    if not p.exists():
        return None
    data = storage.read_json_object(p)
    if data is None:
        log.warning("could not parse filesystem sidecar %s; treating as new", p)
    return data
