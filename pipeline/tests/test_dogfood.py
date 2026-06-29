"""Tests for the dogfood scorecard parser + aggregator + report.

The per-meeting harness itself is excluded: it spins up Anthropic and
the local MLX backend end-to-end, which is the manual workflow the
user runs. The scorecard format and the aggregation logic are pure
and worth locking in here so a future commit cannot silently break
the ship-decision math.
"""
from __future__ import annotations

from pathlib import Path

from unittest.mock import Mock

from mp.config import Config
from mp.dogfood import (
    SHIP_GATE,
    Scorecard,
    _read_scorecard,
    aggregate,
    main,
    render_report,
)


def _write_card(path: Path, *, actions: str, decisions: str, hall: str, notes: str = "") -> None:
    """Helper: emit a dogfood markdown file with the given score
    strings (use empty string for "unset"). Mirrors the layout
    produced by `_render_comparison`."""
    notes_line = f'notes: "{notes}"'
    front = (
        "---\n"
        "transcript: t.md\n"
        "ts: 2026-05-06T10:00:00+00:00\n"
        "scores:\n"
        f"  actions_capture: {actions}\n"
        f"  decisions_capture: {decisions}\n"
        f"  hallucination_rate: {hall}\n"
        f"{notes_line}\n"
        "---\n"
        "\n# body\n"
    )
    path.write_text(front, encoding="utf-8")


def test_read_scorecard_parses_filled_in_card(tmp_path: Path) -> None:
    f = tmp_path / "a.dogfood.md"
    _write_card(f, actions="0.85", decisions="0.90", hall="0.02", notes="good")
    sc = _read_scorecard(f)
    assert sc == Scorecard(0.85, 0.90, 0.02, "good")


def test_read_scorecard_returns_none_for_partial_card(tmp_path: Path) -> None:
    f = tmp_path / "b.dogfood.md"
    _write_card(f, actions="0.85", decisions="", hall="0.02")
    assert _read_scorecard(f) is None


def test_read_scorecard_tolerates_inline_comment(tmp_path: Path) -> None:
    # The template emits "  actions_capture:    # 0.0 to 1.0".
    # A reviewer who edits in place may leave the comment intact.
    text = (
        "---\n"
        "transcript: t.md\n"
        "ts: 2026-05-06T10:00:00+00:00\n"
        "scores:\n"
        "  actions_capture: 0.81  # captured nearly all\n"
        "  decisions_capture: 0.92  # one missed\n"
        "  hallucination_rate: 0.04\n"
        'notes: ""\n'
        "---\n"
    )
    f = tmp_path / "c.dogfood.md"
    f.write_text(text, encoding="utf-8")
    sc = _read_scorecard(f)
    assert sc is not None
    assert sc.actions_capture == 0.81
    assert sc.decisions_capture == 0.92
    assert sc.hallucination_rate == 0.04


def test_aggregate_ship_decision_threshold(tmp_path: Path) -> None:
    # 3 cards above the ship gate, 1 below; gate is the AVG, not the min.
    _write_card(tmp_path / "1.dogfood.md", actions="0.90", decisions="0.95", hall="0.02")
    _write_card(tmp_path / "2.dogfood.md", actions="0.85", decisions="0.85", hall="0.03")
    _write_card(tmp_path / "3.dogfood.md", actions="0.80", decisions="0.85", hall="0.04")
    _write_card(tmp_path / "4.dogfood.md", actions="0.75", decisions="0.80", hall="0.05")
    stats = aggregate(tmp_path)
    assert stats["n_scored"] == 4
    assert stats["n_pending"] == 0
    # avg actions: (0.90 + 0.85 + 0.80 + 0.75) / 4 = 0.825 > 0.80
    # avg decisions: (0.95 + 0.85 + 0.85 + 0.80) / 4 = 0.8625 > 0.80
    # avg hallucination: (0.02 + 0.03 + 0.04 + 0.05) / 4 = 0.035 < 0.05
    assert stats["ship"] is True


def test_aggregate_ship_blocks_when_hallucination_too_high(tmp_path: Path) -> None:
    _write_card(tmp_path / "a.dogfood.md", actions="0.95", decisions="0.95", hall="0.10")
    stats = aggregate(tmp_path)
    assert stats["ship"] is False
    assert "hallucination_rate" in stats["reason"]


def test_aggregate_pending_counts_unscored_files(tmp_path: Path) -> None:
    _write_card(tmp_path / "filled.dogfood.md", actions="0.85", decisions="0.85", hall="0.03")
    _write_card(tmp_path / "blank.dogfood.md", actions="", decisions="", hall="")
    stats = aggregate(tmp_path)
    assert stats["n_total"] == 2
    assert stats["n_scored"] == 1
    assert stats["n_pending"] == 1
    assert any("blank" in p for p in stats["pending"])


def test_aggregate_empty_dir_does_not_ship(tmp_path: Path) -> None:
    stats = aggregate(tmp_path)
    assert stats["n_total"] == 0
    assert stats["ship"] is False


def test_render_report_includes_ship_decision(tmp_path: Path) -> None:
    _write_card(tmp_path / "a.dogfood.md", actions="0.85", decisions="0.85", hall="0.02")
    stats = aggregate(tmp_path)
    out = render_report(stats)
    assert "**SHIP**" in out
    assert "Action items captured" in out


def test_render_report_for_no_grade_state(tmp_path: Path) -> None:
    stats = aggregate(tmp_path)
    out = render_report(stats)
    assert "**DO NOT SHIP**" in out
    assert "no scorecards filled in yet" in out


def test_ship_gate_constants_match_roadmap() -> None:
    # P2.4 acceptance criterion: >= 80% capture, <= 5% hallucination.
    assert SHIP_GATE["actions_capture_min"] == 0.80
    assert SHIP_GATE["decisions_capture_min"] == 0.80
    assert SHIP_GATE["hallucination_max"] == 0.05


# ----- egress gate (SEC10/AUD-23) -----

def test_main_refuses_regulated_meeting(tmp_path: Path, monkeypatch) -> None:
    """mp dogfood must not POST a regulated/NDA transcript to Anthropic. With
    regulated_mode on, main refuses (rc 2) before any backend call, even when
    an API key is present."""
    transcript = tmp_path / "20260501-1000.md"
    transcript.write_text("**A**: hi there\n", encoding="utf-8")

    regulated = Config()
    regulated.modes.regulated_mode = True
    monkeypatch.setattr(Config, "load", lambda: regulated)
    monkeypatch.setattr("mp.dogfood.load_secrets", lambda *a, **k: None)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")  # present: must still refuse

    anthropic = Mock()
    monkeypatch.setattr("mp.dogfood.AnthropicSummaryClient", anthropic)

    rc = main([str(transcript)])

    assert rc == 2
    anthropic.assert_not_called()


def test_main_runs_non_regulated_meeting(tmp_path: Path, monkeypatch) -> None:
    """A normal meeting still runs the A/B: the gate only refuses zero-egress
    modes, so a user who simply prefers the local backend is unaffected."""
    transcript = tmp_path / "20260501-1100.md"
    transcript.write_text("**A**: hi there\n", encoding="utf-8")

    monkeypatch.setattr(Config, "load", lambda: Config())  # not regulated
    monkeypatch.setattr("mp.dogfood.load_secrets", lambda *a, **k: None)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    ran: list[int] = []
    monkeypatch.setattr("mp.dogfood.run_one",
                        lambda *a, **k: ran.append(1) or (tmp_path / "out.md"))

    rc = main([str(transcript)])

    assert rc == 0
    assert ran == [1]


def test_main_passes_local_model_override(tmp_path: Path, monkeypatch) -> None:
    """--local-model reaches run_one so any MLX size can be A/B'd without
    editing config (the "MLX size is a user choice" path)."""
    transcript = tmp_path / "20260501-1200.md"
    transcript.write_text("**A**: hi there\n", encoding="utf-8")

    monkeypatch.setattr(Config, "load", lambda: Config())
    monkeypatch.setattr("mp.dogfood.load_secrets", lambda *a, **k: None)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    seen: dict = {}
    monkeypatch.setattr("mp.dogfood.run_one",
                        lambda *a, **k: seen.update(k) or (tmp_path / "out.md"))

    rc = main([str(transcript), "--local-model", "mlx-community/Qwen2.5-3B-Instruct-4bit"])

    assert rc == 0
    assert seen["local_model"] == "mlx-community/Qwen2.5-3B-Instruct-4bit"
