"""Unit tests for the shared summary-language verification (LANG1).

Pure helpers, no server: the detector and the per-section divergence check are
side-effect-free, so they are tested directly. The backend repair loops that use
them live in ``test_summarize.py`` (cloud) and ``test_summarize_local.py`` (local).
"""
from __future__ import annotations

from mp.schemas import ActionItem, MeetingSummary
from mp.summary_language import (
    divergent_sections,
    expected_summary_language,
    language_reinforcement,
    language_signature,
)


def test_language_signature_reads_scripts() -> None:
    assert language_signature("Sprint planning: we aligned on scope and risks.") == "en"
    assert language_signature("Обговорили обсяг, ризики і терміни релізу.") == "uk"
    assert language_signature("Обсудили объём, риски и сроки выпуска.") == "ru"
    # Too little signal to be sure -> None, so it never triggers a retry.
    assert language_signature("short") is None
    assert language_signature("") is None


def test_expected_summary_language_forced_codes() -> None:
    uk_transcript = "Привіт, давайте почнемо. Це важливе питання і рішення."
    en_transcript = "Hello everyone, let us begin the sprint review now."
    # A verifiable forced code is honored regardless of the transcript.
    assert expected_summary_language("uk", en_transcript) == "uk"
    assert expected_summary_language("en", uk_transcript) == "en"
    # A non-verifiable forced Latin code is left alone (no false English retry).
    assert expected_summary_language("de", en_transcript) is None


def test_expected_summary_language_auto() -> None:
    uk_transcript = "Привіт, давайте почнемо. Це важливе питання і рішення."
    en_transcript = "Hello everyone, let us begin the sprint review now."
    # auto trusts a confident Cyrillic read...
    assert expected_summary_language("auto", uk_transcript) == "uk"
    # ...and, LANG1, a confidently all-Latin transcript is a firm "en" target, so
    # a Cyrillic summary section in an English meeting is an unambiguous divergence.
    assert expected_summary_language("auto", en_transcript) == "en"


def test_expected_summary_language_auto_mixed_script_unverified() -> None:
    # Latin-dominant but with some Cyrillic mixed in: the meeting may legitimately
    # code-switch, so auto leaves it unverified rather than force English.
    mixed = "Hello everyone, we will discuss the roadmap and the да plan for today."
    assert expected_summary_language("auto", mixed) is None
    # Too short to read at all.
    assert expected_summary_language("auto", "Hi there.") is None


def _summary(*, actions_task: str, questions: list[str]) -> MeetingSummary:
    return MeetingSummary(
        title="Sprint review sync",
        summary=["Reviewed the sprint scope and the release plan for the migration."],
        decisions=["We agreed to ship the migration on Friday."],
        actions=[ActionItem(task=actions_task, owner=None)],
        questions=questions,
        attendees=["A", "B"],
        detected_language="en",
    )


def test_divergent_sections_flags_only_the_drifted_ones() -> None:
    # The confirmed LANG1 shape: English title/summary/decisions, Russian actions
    # and questions. Per-section detection flags exactly the drifted sections; a
    # single merged bag would let the English majority mask them.
    summary = _summary(
        actions_task="Подготовить отчёт о регрессионном тестировании к пятнице.",
        questions=["Нужно ли ограничивать размер расшифровки стенограммы?"],
    )
    assert set(divergent_sections(summary, "en")) == {"actions", "questions"}


def test_divergent_sections_clean_when_all_on_target() -> None:
    summary = _summary(
        actions_task="Prepare the regression test report by Friday.",
        questions=["Should we cap the transcript size?"],
    )
    assert divergent_sections(summary, "en") == []


def test_divergent_sections_ignores_too_short_sections() -> None:
    # A section too short to read a language from is never flagged, so a terse
    # foreign-looking title cannot trigger a bogus repair.
    summary = _summary(
        actions_task="Prepare the regression test report by Friday.",
        questions=["Да?"],  # too short to classify
    )
    assert divergent_sections(summary, "en") == []


def test_language_reinforcement_names_the_target() -> None:
    block = language_reinforcement("uk")
    assert "Ukrainian" in block
    assert "українською" in block
    # Names every language-bearing section so the model cannot repair only some.
    assert "action task" in block
