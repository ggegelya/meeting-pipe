"""PIPE55: the one rule for which title a meeting goes by.

The owner's rename (`<stem>.meta.json["user_title"]`), else the title captured at
recording start (`meeting_title`), else the generated `summary.title`. The Library's
`Meeting.displayTitle` resolves the same order, pinned on both sides by
`Fixtures/title-precedence-golden.json`. Every pipeline surface that names a meeting
reads it through here: the sinks (`publish_notion.apply_meeting_title`), the digest,
`mp actions`, Ask's index, `mp prep` and the MCP tools. Before the 2026-11-21 amendment
only the sinks did, so a rename reached Notion but not the digest.

Pure and stdlib-only, so the MCP tools can import it without the publishers' HTTP stack.
"""
from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from .prompt_safety import clean_text

#: The keys of `<stem>.meta.json` that name a meeting, in precedence order.
TITLE_KEYS = ("user_title", "meeting_title")

#: `MeetingSummary.title`'s schema limit; a sidecar title is cut to it like the sinks' title.
TITLE_MAX_CHARS = 120


def sidecar_title(meta: Mapping[str, Any] | None) -> str:
    """The rename, else the captured title, scrubbed and cut; "" when the sidecar has neither.

    SEC28: a captured window title is something an invitee controls, and the rename may be
    pasted from a hostile invite, so both pass `clean_text` before anything renders them."""
    if not meta:
        return ""
    for key in TITLE_KEYS:
        raw = meta.get(key)
        title = clean_text(raw.strip()) if isinstance(raw, str) and raw.strip() else ""
        if title:
            return title[:TITLE_MAX_CHARS]
    return ""


def resolve(meta: Mapping[str, Any] | None, summary_title: object) -> str:
    """The title a meeting goes by: the sidecar's, else `summary_title` as stored, else ""
    (each caller picks its own last resort, usually the stem)."""
    return sidecar_title(meta) or (str(summary_title) if summary_title else "")
