"""PIPE55 (2026-11-21 amendment): every pipeline surface that names a meeting resolves its
title the way the sinks and the Library do, through `titles.resolve`.

Before the amendment only `publish_notion.apply_meeting_title` read `<stem>.meta.json`, so a
Library rename reached Notion while the digest, `mp actions`, Ask's citations, `mp prep` and
the MCP tools kept showing the generated `summary.title`. One table, every reader.
"""
from __future__ import annotations

import json
from collections.abc import Callable
from datetime import date
from pathlib import Path
from typing import Any

import pytest

from mp import actions, digest, embed_index, mcp_tools, prep, titles
from mp.prompt_safety import wrap_untrusted

STEM = "20261118-100000"
WORKFLOW = "Client work"


def _plain(value: str) -> str:
    """The text inside one untrusted fence (the MCP tools fence every title)."""
    begin, end = wrap_untrusted("").splitlines()[0], wrap_untrusted("").splitlines()[-1]
    assert value.startswith(begin + "\n") and value.endswith("\n" + end), value
    return value[len(begin) + 1 : -(len(end) + 1)]


def _meeting(root: Path, *, summary_title: str, meta: dict[str, Any] | None) -> None:
    (root / f"{STEM}.md").write_text("[00:00] Alice: we agreed to ship\n", encoding="utf-8")
    (root / f"{STEM}.summary.md").write_text("# whatever\n\n- we agreed to ship\n", encoding="utf-8")
    (root / f"{STEM}.summary.json").write_text(json.dumps({
        "title": summary_title,
        "summary": ["we agreed to ship"],
        "decisions": ["Ship on Friday"],
        "actions": [{"task": "Send the deck", "owner": "Alice"}],
        "questions": [],
        "attendees": ["Alice"],
        "detected_language": "en",
    }), encoding="utf-8")
    if meta is not None:
        (root / f"{STEM}.meta.json").write_text(json.dumps(meta), encoding="utf-8")


def _digest(root: Path) -> str:
    return digest.collect_recent_decisions(root, date(2026, 11, 20), 30)[0].title


def _actions(root: Path) -> str:
    return actions.discover(root)[0].title


def _ask_index(root: Path) -> str:
    return embed_index.chunk_stem(root, STEM)[0].title


def _prep(root: Path) -> str:
    card = prep.prep(root, WORKFLOW)
    assert card is not None
    return card.title


def _mcp(root: Path) -> str:
    return _plain(mcp_tools.list_meetings(root, {STEM})["meetings"][0]["title"])


READERS: dict[str, Callable[[Path], str]] = {
    "digest": _digest,
    "actions": _actions,
    "embed_index": _ask_index,
    "prep": _prep,
    "mcp_tools": _mcp,
}

# (case, summary title, sidecar title keys, expected). The sidecar always names the
# workflow, since `mp prep` only cards a meeting that belongs to one.
CASES = [
    ("rename wins over both", "Generated", {"user_title": "My rename", "meeting_title": "Captured"}, "My rename"),
    ("captured wins over generated", "Generated", {"meeting_title": "Captured"}, "Captured"),
    ("blank rename falls through", "Generated", {"user_title": "  ", "meeting_title": "Captured"}, "Captured"),
    ("generated when the sidecar names none", "Generated", {}, "Generated"),
    ("stem when nothing names it", "", {}, STEM),
]


@pytest.mark.parametrize("reader", READERS, ids=str)
@pytest.mark.parametrize("case", CASES, ids=lambda c: c[0])
def test_every_reader_resolves_the_title_like_the_sinks(
    reader: str, case: tuple[str, str, dict[str, str], str], tmp_path: Path,
) -> None:
    _, summary_title, keys, expected = case
    _meeting(tmp_path, summary_title=summary_title, meta={"workflow_name": WORKFLOW, **keys})
    assert READERS[reader](tmp_path) == expected


@pytest.mark.parametrize("reader", [r for r in READERS if r != "prep"], ids=str)
def test_an_unreadable_sidecar_falls_back_to_the_generated_title(reader: str, tmp_path: Path) -> None:
    # `prep` is absent on purpose: with no readable sidecar a meeting belongs to no workflow.
    _meeting(tmp_path, summary_title="Generated", meta=None)
    (tmp_path / f"{STEM}.meta.json").write_text("[1]", encoding="utf-8")
    assert READERS[reader](tmp_path) == "Generated"


def test_a_rename_is_scrubbed_and_cut_on_every_surface(tmp_path: Path) -> None:
    hostile = "![x](http://evil.example/p.png) " + "a" * 200
    _meeting(tmp_path, summary_title="Generated", meta={"workflow_name": WORKFLOW, "user_title": hostile})
    for name, read in READERS.items():
        title = read(tmp_path)
        assert len(title) <= titles.TITLE_MAX_CHARS and "](" not in title, name


def test_a_rename_invalidates_that_meetings_cached_index_entry(tmp_path: Path) -> None:
    # Ask cites a chunk by the title stored at index time, so the sidecar is a source of
    # the stem's fingerprint: a rename re-chunks that meeting and its citations follow.
    _meeting(tmp_path, summary_title="Generated", meta={"workflow_name": WORKFLOW})
    before = embed_index.stem_fingerprint(tmp_path, STEM)
    (tmp_path / f"{STEM}.meta.json").write_text(
        json.dumps({"workflow_name": WORKFLOW, "user_title": "Renamed, longer"}), encoding="utf-8")
    assert embed_index.stem_fingerprint(tmp_path, STEM) != before
