"""Tests for ObsidianPublisher.

Covers: round-trip write, content-hash idempotency, audio attachment
copy, daily-note backlink, custom template substitution.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from mp.publish_obsidian import ObsidianPublisher, _slugify, _yaml_str
from mp.schemas import ActionItem, MeetingSummary


def _summary() -> MeetingSummary:
    return MeetingSummary(
        title="Sprint planning",
        summary=["Reviewed Q3 milestones.", "Aligned on staffing."],
        decisions=["Ship beta on 2026-05-20."],
        actions=[ActionItem(task="Send recap", owner="Alice", due="2026-05-07", confidence="high")],
        questions=["Who owns docs?"],
        attendees=["Alice", "Bob"],
        detected_language="en",
    )


def test_format_action_checkbox_reflects_resolved() -> None:
    # AI1: the Obsidian action line ticks the checkbox for a resolved action.
    from mp.publish_obsidian import _format_action
    done = ActionItem(task="Ship it", owner="Alice", due=None, confidence="high", resolved=True)
    open_ = ActionItem(task="Draft it", owner="Bob", due=None, confidence="high")
    assert _format_action(done).startswith("- [x] **Alice**")
    assert _format_action(open_).startswith("- [ ] **Bob**")


def test_upsert_writes_note(tmp_path: Path) -> None:
    transcript = tmp_path / "20260506-1500.md"
    transcript.write_text("# Transcript\n", encoding="utf-8")
    sidecar = tmp_path / "20260506-1500.obsidian.json"
    pub = ObsidianPublisher(vault_path=tmp_path / "vault", folder="Meetings",
                            attach_audio=False)
    res = pub.upsert(summary=_summary(), transcript_md=transcript, sidecar_path=sidecar)
    assert res["idempotent"] is False
    assert res["local"] is True
    note = Path(res["page_id"])
    assert note.exists()
    body = note.read_text(encoding="utf-8")
    assert "Sprint planning" in body
    assert "Send recap" in body
    assert "Alice" in body  # in front-matter and in actions
    # Sidecar persisted with body hash + note path.
    sc = json.loads(sidecar.read_text(encoding="utf-8"))
    assert sc["note_path"] == str(note)
    assert len(sc["body_sha256"]) == 64


def test_upsert_idempotent_on_same_body(tmp_path: Path) -> None:
    transcript = tmp_path / "20260506-1500.md"
    transcript.write_text("# Transcript\n", encoding="utf-8")
    sidecar = tmp_path / "20260506-1500.obsidian.json"
    pub = ObsidianPublisher(vault_path=tmp_path / "vault", attach_audio=False)
    first = pub.upsert(summary=_summary(), transcript_md=transcript, sidecar_path=sidecar)
    note = Path(first["page_id"])
    mtime_before = note.stat().st_mtime_ns

    second = pub.upsert(summary=_summary(), transcript_md=transcript, sidecar_path=sidecar)
    assert second["idempotent"] is True
    # File must not be re-written when the body hash matches.
    assert note.stat().st_mtime_ns == mtime_before


def test_upsert_overwrites_when_body_changes(tmp_path: Path) -> None:
    transcript = tmp_path / "20260506-1500.md"
    transcript.write_text("# Transcript\n", encoding="utf-8")
    sidecar = tmp_path / "20260506-1500.obsidian.json"
    pub = ObsidianPublisher(vault_path=tmp_path / "vault", attach_audio=False)
    pub.upsert(summary=_summary(), transcript_md=transcript, sidecar_path=sidecar)

    changed = _summary().model_copy(update={"summary": ["Changed bullet."]})
    res = pub.upsert(summary=changed, transcript_md=transcript, sidecar_path=sidecar)
    assert res["idempotent"] is False
    body = Path(res["page_id"]).read_text(encoding="utf-8")
    assert "Changed bullet." in body
    assert "Reviewed Q3 milestones." not in body


def test_upsert_idempotent_across_day_boundary(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # The note body carries a `date` and a `generated` timestamp, both
    # non-deterministic. A re-publish the next day must still register as
    # unchanged: same hash, no rewrite, and no second note orphaning the
    # first.
    transcript = tmp_path / "20260506-1500.md"
    transcript.write_text("# Transcript\n", encoding="utf-8")
    sidecar = tmp_path / "20260506-1500.obsidian.json"
    vault = tmp_path / "vault"
    pub = ObsidianPublisher(vault_path=vault, folder="Meetings", attach_audio=False)

    monkeypatch.setattr("mp.publish_obsidian._today_iso", lambda: "2026-05-06")
    monkeypatch.setattr("mp.publish_obsidian._now_iso", lambda: "2026-05-06T15:30:00+00:00")
    first = pub.upsert(summary=_summary(), transcript_md=transcript, sidecar_path=sidecar)
    note = Path(first["page_id"])
    mtime_before = note.stat().st_mtime_ns

    # Next day: both the front-matter date and the generated timestamp move.
    monkeypatch.setattr("mp.publish_obsidian._today_iso", lambda: "2026-05-07")
    monkeypatch.setattr("mp.publish_obsidian._now_iso", lambda: "2026-05-07T09:00:00+00:00")
    second = pub.upsert(summary=_summary(), transcript_md=transcript, sidecar_path=sidecar)

    assert second["idempotent"] is True
    assert note.stat().st_mtime_ns == mtime_before, "unchanged meeting must not be rewritten"
    notes = list((vault / "Meetings").glob("*.md"))
    assert notes == [note], f"next-day re-run orphaned a note: {notes}"


def test_attachment_copied_when_wav_present(tmp_path: Path) -> None:
    transcript = tmp_path / "20260506-1500.md"
    transcript.write_text("# Transcript\n", encoding="utf-8")
    wav = tmp_path / "20260506-1500.wav"
    wav.write_bytes(b"RIFFfake")
    sidecar = tmp_path / "20260506-1500.obsidian.json"
    vault = tmp_path / "vault"
    pub = ObsidianPublisher(vault_path=vault, attach_audio=True,
                            attachments_subfolder="_attachments")
    pub.upsert(summary=_summary(), transcript_md=transcript, sidecar_path=sidecar)
    target = vault / "_attachments" / "20260506-1500.wav"
    assert target.exists()
    assert target.read_bytes() == b"RIFFfake"


def test_attachment_skipped_when_wav_missing(tmp_path: Path) -> None:
    transcript = tmp_path / "20260506-1500.md"
    transcript.write_text("# Transcript\n", encoding="utf-8")
    sidecar = tmp_path / "20260506-1500.obsidian.json"
    vault = tmp_path / "vault"
    pub = ObsidianPublisher(vault_path=vault, attach_audio=True)
    pub.upsert(summary=_summary(), transcript_md=transcript, sidecar_path=sidecar)
    # No wav alongside the transcript means no attachments folder.
    assert not (vault / "_attachments").exists()


def test_daily_note_backlink_appended(tmp_path: Path) -> None:
    transcript = tmp_path / "20260506-1500.md"
    transcript.write_text("# Transcript\n", encoding="utf-8")
    sidecar = tmp_path / "20260506-1500.obsidian.json"
    vault = tmp_path / "vault"
    vault.mkdir()
    pub = ObsidianPublisher(vault_path=vault, attach_audio=False,
                            daily_note_backlink=True)
    res = pub.upsert(summary=_summary(), transcript_md=transcript, sidecar_path=sidecar)
    note_rel = Path(res["page_id"]).relative_to(vault).with_suffix("").as_posix()

    daily_files = list(vault.glob("*.md"))
    daily = next(p for p in daily_files if p.parent == vault and p.stem != note_rel)
    assert f"[[{note_rel}]]" in daily.read_text(encoding="utf-8")


def test_custom_template_substituted(tmp_path: Path) -> None:
    template = tmp_path / "tpl.md"
    template.write_text(
        "# {title}\n\n@{language}\n\nA: {summary_bullets}\n",
        encoding="utf-8",
    )
    transcript = tmp_path / "t.md"
    transcript.write_text("", encoding="utf-8")
    sidecar = tmp_path / "t.obsidian.json"
    pub = ObsidianPublisher(
        vault_path=tmp_path / "vault",
        attach_audio=False,
        template_path=template,
    )
    res = pub.upsert(summary=_summary(), transcript_md=transcript, sidecar_path=sidecar)
    body = Path(res["page_id"]).read_text(encoding="utf-8")
    assert body.startswith("# Sprint planning")
    assert "@en" in body
    assert "- Reviewed Q3 milestones." in body


def test_yaml_str_escapes_quotes_and_specials() -> None:
    assert _yaml_str("Alice") == "Alice"
    assert _yaml_str("Alice: Manager") == '"Alice: Manager"'
    assert _yaml_str('She said "hi"') == '"She said \\"hi\\""'


def test_render_note_neutralizes_title_yaml_injection(tmp_path: Path) -> None:
    # A title carrying a newline must not inject a top-level YAML key into the
    # frontmatter: it is collapsed to one line and quoted (TECH-SEC7).
    pub = ObsidianPublisher(vault_path=tmp_path / "vault", attach_audio=False)
    summary = MeetingSummary(
        title="Pwned\nmalicious_key: true",
        summary=["x"],
        detected_language="en",
    )
    body = pub._render_note(summary, None, date="2026-01-01",
                            generated="2026-01-01T00:00:00+00:00")
    frontmatter = body.split("---", 2)[1]
    assert "\nmalicious_key:" not in frontmatter, "newline injected a YAML key"
    assert 'title: "Pwned malicious_key: true"' in frontmatter


def test_slugify_normalizes_to_url_safe() -> None:
    assert _slugify("Sprint Planning Q3!") == "sprint-planning-q3"
    assert _slugify("   leading and trailing   ") == "leading-and-trailing"
    assert _slugify("???") == ""


# --- PIPE31: one note per stem, named by the recording, in any script --------

def _obs(tmp_path: Path, name: str = "vault") -> ObsidianPublisher:
    return ObsidianPublisher(vault_path=tmp_path / name, folder="Meetings", attach_audio=False)


def _stem_md(tmp_path: Path, stem: str = "20261001-003000") -> tuple[Path, Path]:
    md = tmp_path / f"{stem}.md"
    md.write_text("# Transcript\n", encoding="utf-8")
    return md, tmp_path / f"{stem}.obsidian.json"


def test_changed_body_on_a_later_day_rewrites_the_same_note(tmp_path: Path, monkeypatch) -> None:
    md, sidecar = _stem_md(tmp_path)
    pub = _obs(tmp_path)
    monkeypatch.setattr("mp.publish_obsidian._today_iso", lambda: "2026-10-01")
    first = pub.upsert(summary=_summary(), transcript_md=md, sidecar_path=sidecar)
    changed = _summary().model_copy(update={"summary": ["Reviewed Q3 milestones.", "A new bullet."]})
    monkeypatch.setattr("mp.publish_obsidian._today_iso", lambda: "2026-10-02")
    second = pub.upsert(summary=changed, transcript_md=md, sidecar_path=sidecar)

    assert second["idempotent"] is False
    assert second["page_id"] == first["page_id"]
    notes = list((tmp_path / "vault" / "Meetings").glob("*.md"))
    assert notes == [Path(first["page_id"])]
    assert "A new bullet." in notes[0].read_text(encoding="utf-8")


def test_a_title_change_rewrites_the_same_note(tmp_path: Path) -> None:
    md, sidecar = _stem_md(tmp_path)
    pub = _obs(tmp_path)
    first = pub.upsert(summary=_summary(), transcript_md=md, sidecar_path=sidecar)
    renamed = _summary().model_copy(update={"title": "A different title"})
    second = pub.upsert(summary=renamed, transcript_md=md, sidecar_path=sidecar)
    assert second["page_id"] == first["page_id"]
    assert len(list((tmp_path / "vault" / "Meetings").glob("*.md"))) == 1
    assert "A different title" in Path(second["page_id"]).read_text(encoding="utf-8")


def test_a_recorded_note_in_another_vault_is_treated_as_absent(tmp_path: Path) -> None:
    md, sidecar = _stem_md(tmp_path)
    first = _obs(tmp_path, "old-vault").upsert(summary=_summary(), transcript_md=md, sidecar_path=sidecar)
    res = _obs(tmp_path, "new-vault").upsert(summary=_summary(), transcript_md=md, sidecar_path=sidecar)
    assert res["idempotent"] is False
    assert Path(res["page_id"]).is_relative_to((tmp_path / "new-vault").resolve())
    assert Path(res["page_id"]).exists() and Path(first["page_id"]).exists()


def test_an_unchanged_body_whose_note_was_deleted_is_rewritten(tmp_path: Path) -> None:
    md, sidecar = _stem_md(tmp_path)
    pub = _obs(tmp_path)
    first = pub.upsert(summary=_summary(), transcript_md=md, sidecar_path=sidecar)
    Path(first["page_id"]).unlink()
    res = pub.upsert(summary=_summary(), transcript_md=md, sidecar_path=sidecar)
    assert res["idempotent"] is False
    assert Path(res["page_id"]).exists()


def test_the_note_and_its_date_follow_the_meeting_not_the_publish_day(tmp_path: Path, monkeypatch) -> None:
    md, sidecar = _stem_md(tmp_path, "20261001-003000")
    monkeypatch.setattr("mp.publish_obsidian._today_iso", lambda: "2026-12-31")
    res = _obs(tmp_path).upsert(summary=_summary(), transcript_md=md, sidecar_path=sidecar)
    assert Path(res["page_id"]).name.startswith("20261001-003000 ")
    assert "date: 2026-10-01\n" in Path(res["page_id"]).read_text(encoding="utf-8")


def test_a_stem_with_no_date_falls_back_to_today(tmp_path: Path, monkeypatch) -> None:
    md, sidecar = _stem_md(tmp_path, "paste-note")
    monkeypatch.setattr("mp.publish_obsidian._today_iso", lambda: "2026-12-31")
    res = _obs(tmp_path).upsert(summary=_summary(), transcript_md=md, sidecar_path=sidecar)
    assert "date: 2026-12-31\n" in Path(res["page_id"]).read_text(encoding="utf-8")


def test_two_recordings_with_one_title_never_share_a_note(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr("mp.publish_obsidian._today_iso", lambda: "2026-10-01")
    pub = _obs(tmp_path)
    md1, sc1 = _stem_md(tmp_path, "20261001-090000")
    md2, sc2 = _stem_md(tmp_path, "20261001-150000")
    first = pub.upsert(summary=_summary(), transcript_md=md1, sidecar_path=sc1)
    second = pub.upsert(summary=_summary(), transcript_md=md2, sidecar_path=sc2)
    assert first["page_id"] != second["page_id"]
    before = {p: p.read_bytes() for p in (tmp_path / "vault" / "Meetings").glob("*.md")}
    again = pub.upsert(summary=_summary(), transcript_md=md1, sidecar_path=sc1)
    assert again["idempotent"] is True and again["page_id"] == first["page_id"]
    assert {p: p.read_bytes() for p in (tmp_path / "vault" / "Meetings").glob("*.md")} == before


def test_a_cyrillic_title_keeps_its_words_in_the_filename(tmp_path: Path) -> None:
    md, sidecar = _stem_md(tmp_path)
    s = _summary().model_copy(update={"title": "Планування спринту: Q3"})
    res = _obs(tmp_path).upsert(summary=s, transcript_md=md, sidecar_path=sidecar)
    assert Path(res["page_id"]).name == "20261001-003000 планування-спринту-q3.md"


def test_slugify_keeps_any_script_and_strips_separators() -> None:
    assert _slugify("a/b:c") == "a-b-c"
    assert _slugify("Планування спринту") == "планування-спринту"
    assert _slugify("会议 记录") == "会议-记录"
    assert "/" not in _slugify("../../etc/passwd") and ":" not in _slugify("x:y")


def test_a_long_cjk_title_stays_within_the_filename_limit(tmp_path: Path) -> None:
    md, sidecar = _stem_md(tmp_path)
    s = _summary().model_copy(update={"title": "会" * 300})
    res = _obs(tmp_path).upsert(summary=s, transcript_md=md, sidecar_path=sidecar)
    assert len(Path(res["page_id"]).name.encode("utf-8")) <= 255
