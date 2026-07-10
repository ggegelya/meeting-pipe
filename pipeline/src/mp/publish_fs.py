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
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .markdown import render_summary_md
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
    ) -> dict[str, Any]:
        self._out.mkdir(parents=True, exist_ok=True)
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
            log.info("filesystem sink unchanged, skipping write (sha=%s...)", signature[:8])
            return {
                "page_id": existing.get("summary_path"),
                "page_url": file_url(Path(existing["summary_path"])) if existing.get("summary_path") else None,
                "idempotent": True,
                "local": True,
            }

        summary_path = self._out / f"{stem}.summary.md"
        actions_path = self._out / f"{stem}.actions.json"
        summary_path.write_text(summary_md, encoding="utf-8")
        actions_path.write_text(actions_json, encoding="utf-8")
        if transcript_text:
            transcript_path = self._out / f"{stem}.transcript.md"
            transcript_path.write_text(transcript_text, encoding="utf-8")

        sidecar_path.parent.mkdir(parents=True, exist_ok=True)
        sidecar_path.write_text(
            json.dumps({
                "schema_version": 1,
                "summary_path": str(summary_path),
                "actions_path": str(actions_path),
                "output_dir": str(self._out),
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
    return "file://" + os.path.abspath(p).replace(" ", "%20")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def load_sidecar(p: Path) -> dict[str, Any] | None:
    if not p.exists():
        return None
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else None
    except Exception:  # noqa: BLE001
        log.warning("could not parse filesystem sidecar %s; treating as new", p)
        return None
