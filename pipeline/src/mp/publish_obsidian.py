"""Obsidian-vault publisher.

Writes a Markdown note to a configured vault path with a user-templatable
front-matter, optionally drops the recording into a configured
``_attachments`` folder, and (optionally) appends a backlink to the daily
note.

Idempotency: each call writes to a deterministic path
(``<vault>/<folder>/<stem>.md``) plus a sidecar at
``<wav-dir>/<stem>.obsidian.json`` containing a SHA-256 of the rendered
file body. A second call with identical body returns ``idempotent: True``
without touching disk; a changed body overwrites the file in place.

The Notion publisher is the schema reference; this one stays narrower:
no API keys, no rate limits, no toggle blocks. The strategic point is
that users who never want their meeting data leaving their machine can
configure ``output.sinks = ["obsidian", "filesystem"]`` and the pipeline
publishes everywhere except Notion.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .schemas import MeetingSummary

log = logging.getLogger("mp.publish_obsidian")

# Fixed stand-ins for the volatile front-matter fields when computing the
# idempotency hash. The real values still go into the written note; only
# the fingerprint pins them so an unchanged meeting hashes the same on a
# re-publish or a next-day re-run.
_HASH_PINNED_DATE = "0000-00-00"
_HASH_PINNED_GENERATED = "0000-00-00T00:00:00+00:00"


DEFAULT_TEMPLATE = """\
---
title: {title_yaml}
date: {date}
attendees: {attendees}
tags: [meeting, source/meeting-pipe]
language: {language}
generated: {generated}
---

# {title}

{summary_bullets}

## Decisions

{decisions}

## Action items

{actions}

## Open questions

{questions}

{transcript_section}
"""


class ObsidianPublisher:
    """Concrete ``MeetingPublisher`` for an Obsidian vault.

    Construction takes the resolved settings (vault path, folder,
    optional attachment dir, optional template) so the caller (the
    multi-sink orchestrator) does the config-to-fields mapping once.
    """

    name = "obsidian"

    def __init__(
        self,
        *,
        vault_path: Path,
        folder: str = "Meetings",
        attach_audio: bool = True,
        attachments_subfolder: str = "_attachments",
        template_path: Path | None = None,
        daily_note_backlink: bool = False,
    ) -> None:
        self._vault = vault_path.expanduser().resolve()
        self._folder = folder.strip("/") or "Meetings"
        self._attach_audio = attach_audio
        self._attachments_subfolder = attachments_subfolder.strip("/") or "_attachments"
        self._template_path = template_path
        self._daily_note_backlink = daily_note_backlink

    def upsert(
        self,
        *,
        summary: MeetingSummary,
        transcript_md: Path | None,
        sidecar_path: Path,
    ) -> dict[str, Any]:
        body = self._render_note(
            summary, transcript_md, date=_today_iso(), generated=_now_iso(),
        )
        # Idempotency fingerprint: hash a canonical render with the
        # volatile date/generated values pinned. Without this every
        # re-publish rewrites the file, and a next-day re-run produces a
        # second note (orphaning the old one), since the body always
        # differs by at least its timestamp.
        canonical = self._render_note(
            summary, transcript_md,
            date=_HASH_PINNED_DATE, generated=_HASH_PINNED_GENERATED,
        )
        body_hash = hashlib.sha256(canonical.encode("utf-8")).hexdigest()

        existing = _load_sidecar(sidecar_path)
        if existing and existing.get("body_sha256") == body_hash:
            log.info("Obsidian note unchanged, skipping write (sha=%s...)", body_hash[:8])
            return {
                "page_id": existing.get("note_path"),
                "page_url": _file_url(Path(existing["note_path"])) if existing.get("note_path") else None,
                "idempotent": True,
                "local": True,
            }

        note_path = self._compute_note_path(summary, transcript_md)
        note_path.parent.mkdir(parents=True, exist_ok=True)
        note_path.write_text(body, encoding="utf-8")
        log.info("wrote %s", note_path)

        attachment_rel: str | None = None
        if self._attach_audio and transcript_md is not None:
            attachment_rel = self._copy_audio_attachment(transcript_md)

        if self._daily_note_backlink:
            self._append_daily_note_backlink(note_path)

        sidecar_path.parent.mkdir(parents=True, exist_ok=True)
        sidecar_path.write_text(
            json.dumps({
                "note_path": str(note_path),
                "vault": str(self._vault),
                "attachment_rel": attachment_rel,
                "body_sha256": body_hash,
                "ts": _now_iso(),
            }, indent=2, sort_keys=True),
            encoding="utf-8",
        )

        return {
            "page_id": str(note_path),
            "page_url": _file_url(note_path),
            "idempotent": False,
            "local": True,
        }

    # ----- Path layout -----

    def _compute_note_path(self, summary: MeetingSummary, transcript_md: Path | None) -> Path:
        stem = transcript_md.stem if transcript_md else _slugify(summary.title)
        # Strip the speaker-segmented suffix so two Markdown files
        # do not share a name. Same convention summarize.py uses.
        if stem.endswith(".summary"):
            stem = stem[: -len(".summary")]
        date = _today_iso()
        # Title prefix with the meeting topic for human-grokkability
        # at the file-listing level. Falls back to bare stem when the
        # title slug is empty.
        title_slug = _slugify(summary.title)
        filename = f"{date} {title_slug}".strip() if title_slug else stem
        return self._vault / self._folder / f"{filename}.md"

    def _copy_audio_attachment(self, transcript_md: Path) -> str | None:
        # transcript_md is <stem>.md alongside the .wav. Find the wav
        # by stem; if missing (e.g. cleaned up already), do not fail.
        wav = transcript_md.parent / f"{transcript_md.stem}.wav"
        if not wav.exists():
            log.info("no audio attachment found at %s", wav)
            return None
        attach_dir = self._vault / self._attachments_subfolder
        attach_dir.mkdir(parents=True, exist_ok=True)
        target = attach_dir / wav.name
        if target.exists() and target.stat().st_size == wav.stat().st_size:
            log.info("audio attachment already present, skipping copy")
        else:
            shutil.copy2(wav, target)
            log.info("copied audio to %s", target)
        return f"{self._attachments_subfolder}/{wav.name}"

    def _append_daily_note_backlink(self, note_path: Path) -> None:
        daily = self._vault / f"{_today_iso()}.md"
        rel = note_path.relative_to(self._vault).with_suffix("").as_posix()
        line = f"- [[{rel}]]\n"
        if daily.exists() and line in daily.read_text(encoding="utf-8"):
            return
        with daily.open("a", encoding="utf-8") as f:
            f.write(line)

    # ----- Rendering -----

    def _render_note(
        self,
        summary: MeetingSummary,
        transcript_md: Path | None,
        *,
        date: str,
        generated: str,
    ) -> str:
        template = (
            self._template_path.read_text(encoding="utf-8")
            if self._template_path and self._template_path.exists()
            else DEFAULT_TEMPLATE
        )

        attendees_yaml = "[" + ", ".join(_yaml_str(a) for a in summary.attendees) + "]"
        summary_bullets = "\n".join(f"- {bullet}" for bullet in summary.summary) or "_no summary_"
        decisions = "\n".join(f"{i+1}. {d}" for i, d in enumerate(summary.decisions)) or "_none_"
        actions = "\n".join(_format_action(a) for a in summary.actions) or "_none_"
        questions = "\n".join(f"- {q}" for q in summary.questions) or "_none_"
        transcript_section = ""
        if transcript_md and transcript_md.exists():
            transcript_section = "## Transcript\n\n" + transcript_md.read_text(encoding="utf-8")

        # The title lands in YAML frontmatter and the H1. Collapse it to one
        # line, then route the frontmatter copy through _yaml_str so a ':' or a
        # smuggled newline cannot inject a YAML key. (TECH-SEC7; the Swift
        # MeetingTitleResolver also strips control chars at the source.)
        clean_title = _single_line(summary.title)
        return template.format(
            title=clean_title,
            title_yaml=_yaml_str(clean_title),
            date=date,
            attendees=attendees_yaml,
            tags="meeting",  # back-compat: older templates may use {tags}
            language=summary.detected_language,
            generated=generated,
            summary_bullets=summary_bullets,
            decisions=decisions,
            actions=actions,
            questions=questions,
            transcript_section=transcript_section,
        )


# ----- Helpers (file-scope so they're testable in isolation) -----

def _format_action(a: Any) -> str:
    owner = getattr(a, "owner", None) or "_unassigned_"
    due = getattr(a, "due", None)
    confidence = getattr(a, "confidence", "medium")
    suffix = f"  (due: {due})" if due else ""
    return f"- [ ] **{owner}** {a.task}{suffix} _(confidence: {confidence})_"


_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")  # control chars incl newline / tab / CR
_WS_RUN_RE = re.compile(r"\s+")


def _single_line(s: str) -> str:
    # Collapse all whitespace (including newlines) to single spaces and strip, so
    # an interpolated title cannot span lines or carry control chars (TECH-SEC7).
    return _WS_RUN_RE.sub(" ", s).strip()


def _yaml_str(s: str) -> str:
    # Quote anything with a ":" or YAML-special leading char, and always escape
    # inner double quotes. Control chars are neutralized to spaces first so the
    # result is always a single-line scalar that cannot inject a YAML key via a
    # newline (TECH-SEC7). Cheap subset of YAML escaping that covers our finite
    # title / attendee-name use case.
    s = _CONTROL_RE.sub(" ", s)
    needs_quote = bool(re.search(r'[:\-?#&*!|>\'"%@`]', s)) or s != s.strip()
    if not needs_quote:
        return s
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


_SLUG_RE = re.compile(r"[^a-z0-9]+")


def _slugify(s: str) -> str:
    s = s.lower().strip()
    s = _SLUG_RE.sub("-", s)
    return s.strip("-")[:80]


def _today_iso() -> str:
    return datetime.now(timezone.utc).date().isoformat()


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _file_url(p: Path) -> str:
    return "file://" + os.path.abspath(p).replace(" ", "%20")


def _load_sidecar(p: Path) -> dict[str, Any] | None:
    if not p.exists():
        return None
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else None
    except Exception:  # noqa: BLE001
        log.warning("could not parse Obsidian sidecar %s; treating as new", p)
        return None
