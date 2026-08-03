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


def test_language_signature_keeps_the_majority_split_not_the_lang2_share() -> None:
    # LANG2 reviewed this detector alongside `expected_summary_language` and left
    # it on the plain majority split. Real Ukrainian summary sections carry 20% to
    # 37% Latin (product names, ADR, API, DMS); if this borrowed the transcript
    # share threshold it would answer None for them, and a section it will not
    # read is a section `divergent_sections` will not flag. This one is 31% Latin.
    section = (
        "Підготувати ADR по автентифікації FusionAuth і оновити DMS API до релізу, "
        "потім перевірити збірку Jenkins та образи Docker на середовищі stage."
    )
    assert language_signature(section) == "uk"


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
    # Genuinely code-switched, roughly half of each script: whichever one edges
    # ahead is a coin flip, so auto refuses to pick a side rather than flatten the
    # meeting into one language. Built from the shape of the one such meeting in
    # the owner's library (46.8% minority, a single 281-word Ukrainian run).
    mixed = (
        "Hello everyone, we will walk the roadmap and the release plan for today "
        "and then hand over to the platform side. "
        "Добре, тоді я коротко розкажу про поточний стан міграції, що вже "
        "зроблено і що залишилось до кінця тижня, а потім ми разом подивимось "
        "на плани і терміни."
    )
    assert expected_summary_language("auto", mixed) is None
    # Too short to read at all.
    assert expected_summary_language("auto", "Hi there.") is None


def test_expected_summary_language_auto_stray_cyrillic_is_still_english() -> None:
    # LANG2, the real numbers from meeting 20260730-163434: one throwaway opening
    # line (exactly 25 Cyrillic letters) in front of a 30-minute English meeting,
    # 0.14% of all letters. The pre-LANG2 `cyr == 0` gate returned None for it, so
    # LANG1's reinforcement, per-section divergence check and repair all sat out
    # and the summary shipped 1,178 characters of Ukrainian prose.
    quip = "Суть в том, что мне треба солнце."
    english = "We reviewed the release plan and agreed to ship the migration on Friday. "
    transcript = quip + " " + english * 292  # 25 Cyrillic against 17,228 Latin
    assert expected_summary_language("auto", transcript) == "en"
    # The same widening at the small end: one Russian word in an English sentence
    # is noise, not a code switch. This exact string read None before LANG2.
    one_word = "Hello everyone, we will discuss the roadmap and the да plan for today."
    assert expected_summary_language("auto", one_word) == "en"


def test_expected_summary_language_auto_cyrillic_with_latin_terms() -> None:
    # The mirror case, and the one that matters most: a Ukrainian meeting studded
    # with English technical vocabulary is still "uk". The library's Cyrillic
    # meetings run to 10.8% Latin because that borrowing is normal, so a threshold
    # tight enough to please the English side would de-verify every one of them.
    # This fixture is 16% Latin, which is where the real ones cluster once the
    # markdown wrapper's Latin speaker labels are counted in.
    uk_transcript = (
        "Давайте почнемо зі статусу міграції. Jenkins збирає нову версію, "
        "образи Docker вже в реєстрі, залишилось оновити конфігурацію tenant "
        "і перевірити, що логін через FusionAuth працює на середовищі stage. "
        "Далі подивимось на відкриті питання і терміни релізу."
    )
    assert expected_summary_language("auto", uk_transcript) == "uk"


def test_expected_summary_language_auto_near_even_split_is_unverified_either_way() -> None:
    # LANG2's symmetry: before it, the Cyrillic branch accepted anything up to
    # half while the Latin branch demanded purity, so the same near-even meeting
    # was a confident "uk" or an unverifiable None depending on which script
    # happened to edge ahead. One shared share threshold, so now neither verifies.
    uk_half = "Обговорили обсяг робіт, ризики і терміни релізу цього тижня разом. "
    en_half = "We discussed the scope of work, the risks and this week release date. "
    # Even letter counts, so which script "wins" is an accident of one word.
    assert expected_summary_language("auto", uk_half + en_half) is None
    # And clearly Cyrillic-dominant (40% Latin), which read "uk" before LANG2.
    assert expected_summary_language("auto", uk_half * 3 + en_half * 2) is None


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
