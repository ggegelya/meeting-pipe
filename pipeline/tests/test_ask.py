"""Tests for `mp ask` lexical search (TECH-FEAT2)."""
from __future__ import annotations

import json
from pathlib import Path

from mp.ask import discover, main, search, snippet


def _meeting(root: Path, stem: str, *, title: str, transcript: str) -> None:
    root.mkdir(parents=True, exist_ok=True)
    (root / f"{stem}.md").write_text(transcript, encoding="utf-8")
    (root / f"{stem}.summary.json").write_text(json.dumps({"title": title}), encoding="utf-8")
    (root / f"{stem}.summary.md").write_text(f"# {title}\n", encoding="utf-8")


def test_discover_reads_title_and_text(tmp_path: Path) -> None:
    _meeting(tmp_path, "20260506-1500", title="Budget review", transcript="A: we cut the budget.\n")
    docs = discover(tmp_path)
    assert len(docs) == 1
    assert docs[0].stem == "20260506-1500"
    assert docs[0].title == "Budget review"
    assert docs[0].tf["budget"] >= 1


def test_discover_skips_meetings_with_no_text(tmp_path: Path) -> None:
    # Only a meta sidecar, no transcript or summary - nothing to search.
    (tmp_path / "20260506-1600.meta.json").write_text("{}", encoding="utf-8")
    assert discover(tmp_path) == []


def test_search_ranks_relevant_meeting_first(tmp_path: Path) -> None:
    _meeting(tmp_path, "m1", title="Hiring sync", transcript="A: interview loop and offers.\n")
    _meeting(tmp_path, "m2", title="Budget", transcript="A: budget budget budget cut spending.\n")
    docs = discover(tmp_path)
    results = search(docs, "budget", top=5)
    assert results
    assert results[0][0].stem == "m2"
    assert results[0][1] > 0


def test_search_no_match_returns_empty(tmp_path: Path) -> None:
    _meeting(tmp_path, "m1", title="Sync", transcript="A: hello world.\n")
    assert search(discover(tmp_path), "encryption", top=5) == []


def test_snippet_picks_the_line_with_query_terms(tmp_path: Path) -> None:
    _meeting(
        tmp_path, "m1", title="Mixed",
        transcript="A: small talk about the weather.\nB: the migration to Postgres is risky.\n",
    )
    docs = discover(tmp_path)
    snip = snippet(["migration", "postgres"], docs[0])
    assert "migration" in snip.lower()


def test_main_empty_library_is_clean_exit(tmp_path: Path, capsys) -> None:
    rc = main(["budget", "--dir", str(tmp_path)])
    assert rc == 0
    assert "No searchable meetings" in capsys.readouterr().out


def test_main_json_output(tmp_path: Path, capsys) -> None:
    _meeting(tmp_path, "m1", title="Budget", transcript="A: budget cut.\n")
    rc = main(["budget", "--dir", str(tmp_path), "--json"])
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload[0]["stem"] == "m1"
    assert payload[0]["title"] == "Budget"
