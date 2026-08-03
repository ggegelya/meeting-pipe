"""Post-hoc language verification for generated summaries (LANG1, generalizing LOCAL7).

A summary section can come out in a language the transcript never contained. The
confirmed LANG1 case: an all-English transcript (0 Cyrillic across 279 segments)
whose `questions` and every `actions[].task` came back in Russian from the cloud
model, while title/summary/decisions stayed English. This module holds the cheap,
pure language detector plus the per-section divergence check that both summary
backends use to catch and repair such drift:

  - the Anthropic path (`summarize.summarize`) verifies backend-agnostically after
    the client answers (before LANG1 the cloud path verified nothing);
  - the local MLX path (`summarize_local`) reinforces the target before writing and
    replays once when it drifts (LOCAL7).

The detector is deliberately tiny: it only separates the languages this user
actually meets (English, Ukrainian, Russian) by script + signature letters, and
returns None when it cannot be sure, so a German or French meeting never triggers a
bogus retry. It reads *script*, not meaning: "en" really means "Latin script", and
callers must not ask it to tell Latin languages apart.
"""
from __future__ import annotations

from .schemas import MeetingSummary

# Cyrillic letters that appear in Ukrainian but not Russian, and vice versa.
# Presence of one set over the other is a reliable uk-vs-ru tell in running text.
_UK_SIGNATURE = frozenset("іїєґІЇЄҐ")
_RU_SIGNATURE = frozenset("ыэъёЫЭЪЁ")
# Enough letters to trust a script read; a title plus one bullet clears this.
_LANG_MIN_LETTERS = 12
# LANG2: how much of the *other* script a transcript may carry and still be a firm
# target language. It protects one thing: a genuinely code-switched meeting, which
# must stay unverified rather than be flattened into whichever script edged ahead.
# It is not there to protect against noise, and before LANG2 the Latin branch used
# `cyr == 0`, which treated the two as the same thing: 25 Cyrillic letters in
# 17,247 (one opening quip in a 30-minute English meeting) left the target
# unverified, so LANG1's reinforcement, divergence check, and repair all sat out
# and that meeting shipped 1,178 characters of Ukrainian prose.
#
# 0.33 comes from scoring all 232 transcripts in the owner's library, measured on
# the rendered markdown because that is what callers pass, not on the raw segment
# text. The population is three groups, not a continuum:
#   - 205 are a single script exactly (0% minority);
#   - the 19 Cyrillic-dominant meetings run 0.9% to 23.1% Latin, because a
#     Ukrainian standup borrows English technical vocabulary word by word
#     (Jenkins, Docker, tenant, API); longest run of Latin words: 14;
#   - the Latin-dominant meetings sit at 0.1% to 1.4%, with one at 8.0%, because
#     the only way Cyrillic enters an English transcript is somebody actually
#     speaking it for a stretch (contiguous runs of 35 to 94 words);
#   - exactly one meeting is genuinely bilingual: 45.2% minority, 1,637 Cyrillic
#     words, a single run of 281. That one must stay unverified.
# So the window is (23.1%, 45.2%), and 0.33 sits 1.43x above the most English-larded
# single-language meeting and 1.37x below the bilingual one, which is as close to
# centred as the data allows. Read plainly: a transcript is a firm target only when
# at least two thirds of its letters are one script.
#
# The 23.1% ceiling is worth knowing about, because it is not linguistic. That
# meeting's *speech* is 5.7% Latin; the rest is the markdown wrapper, whose header
# and one `**Name**:` label per turn are Latin whatever the meeting was spoken in.
# It is a fixed cost per turn, so it lands hardest on the shortest meetings (that
# one is ~3 minutes: 174 of its 218 Latin letters are labels), while the longest
# Cyrillic meeting is barely moved (0.4% to 0.9%). Two consequences. Erring low is
# the safer error, so this constant is deliberately nearer the Cyrillic ceiling
# than the middle of the raw range: a threshold set too low costs a very short
# meeting its safety net and leaves it where it was before LANG1, while one set too
# high forces a genuinely bilingual meeting into a single language, which is an
# actively wrong answer rather than an absent one. And a still shorter Cyrillic
# meeting could clear 33% on labels alone; the fix for that would be to stop
# counting the wrapper rather than to keep raising this number.
_LANG_MAX_MINORITY_SHARE = 0.33
# The languages the cheap detector can actually verify. A forced code outside
# this set (de, es, fr, ...) is left unverified rather than misread as English.
_VERIFIABLE_LANGS = frozenset({"uk", "ru", "en"})
# Human names + endonyms for the directive; the endonym reinforces the target
# for a model that is drifting away from it.
_LANGUAGE_NAMES = {
    "uk": "Ukrainian (українською мовою)",
    "ru": "Russian (на русском языке)",
    "en": "English",
}


def _script_counts(text: str) -> tuple[int, int, int, int]:
    """(cyrillic, latin, uk_signature, ru_signature) letter counts in ``text``.
    ASCII plus accented Latin (ä, é, ł, ...) and other non-Cyrillic alphabets all
    count as Latin-ish for the coarse script read; the Cyrillic block is matched
    exactly. Pure, so callers can share one pass over the text."""
    cyr = lat = uk = ru = 0
    for ch in text:
        if 0x0400 <= ord(ch) <= 0x04FF:  # Cyrillic block (covers uk + ru)
            cyr += 1
            if ch in _UK_SIGNATURE:
                uk += 1
            elif ch in _RU_SIGNATURE:
                ru += 1
        elif ch.isalpha():
            lat += 1
    return cyr, lat, uk, ru


def language_signature(text: str) -> str | None:
    """Best-effort language of ``text``: "uk", "ru", "en", or None when there is
    not enough signal to be sure. Script first (Cyrillic vs Latin), then uk vs ru
    by signature letters. "en" really means "Latin script"; the detector does not
    separate Latin languages, and callers must not ask it to (see
    ``expected_summary_language``). Pure, so it is unit-tested without a server.

    LANG2 reviewed whether this should share ``_LANG_MAX_MINORITY_SHARE`` and
    deliberately left it on the plain majority split, because it answers a
    different question over much shorter text. Its callers are the per-section
    checks in ``divergent_sections``, and the owner's real Ukrainian summaries
    carry 20% to 37% Latin per section (product names, ADR, API, DMS), one title
    at 49%. Gating this on the same share would return None for most of them, and
    a section the detector will not read is a section ``divergent_sections`` will
    not flag, which is LANG1's whole mechanism switched off. Fail-safe is the
    wrong default here: the cost of a missed flag is a summary in the wrong
    language, the cost of a wrong flag is one extra model call that is discarded
    unless it comes back clean."""
    cyr, lat, uk, ru = _script_counts(text)
    if cyr + lat < _LANG_MIN_LETTERS:
        return None
    if cyr >= lat:
        if uk > ru:
            return "uk"
        if ru > uk:
            return "ru"
        return None  # Cyrillic but ambiguous; do not act on a coin flip
    return "en"


def expected_summary_language(summary_language: str, transcript: str) -> str | None:
    """The language a summary should come out in, or None when we cannot cheaply
    verify it (and therefore must neither reinforce nor retry).

    A forced ISO 639-1 code is honored only when the detector can check it
    (uk / ru / en); other forced Latin codes (de, es, ...) are left alone rather
    than risk forcing English on a German meeting.

    "auto" trusts a *confident* read of the transcript: a mostly-Cyrillic
    transcript yields uk or ru, a mostly-Latin one yields "en" (LANG1), so a
    Russian action block in an English meeting is an unambiguous divergence even
    under auto. "Mostly" is one symmetric share (LANG2): a transcript whose
    minority script is more than ``_LANG_MAX_MINORITY_SHARE`` of its letters, or
    that is too short to read, stays unverified so a genuinely code-switched
    meeting is never force-flattened into one language.

    That share is the same on both sides on purpose. Before LANG2 the Latin branch
    demanded purity while the Cyrillic branch accepted anything up to half, so a
    49%-Latin Ukrainian meeting was a confident "uk" while a 49%-Cyrillic English
    one was unverifiable; the same meeting got opposite treatment depending on
    which script happened to edge ahead. Now neither is verified."""
    code = (summary_language or "auto").strip().lower()
    if len(code) == 2 and code.isalpha():
        return code if code in _VERIFIABLE_LANGS else None
    cyr, lat, uk, ru = _script_counts(transcript)
    letters = cyr + lat
    if letters < _LANG_MIN_LETTERS:
        return None
    if min(cyr, lat) / letters > _LANG_MAX_MINORITY_SHARE:
        return None  # genuinely code-switched; do not pick a side for it
    if cyr >= lat:
        # Cyrillic-dominant: only act on a confident uk / ru read.
        if uk > ru:
            return "uk"
        if ru > uk:
            return "ru"
        return None
    return "en"


def _summary_sections(summary: MeetingSummary) -> dict[str, list[str]]:
    """The language-bearing prose of a summary, grouped by section. Owners, dates,
    attendees, and enums are excluded: they carry proper nouns and codes, not
    running-language signal.

    FEAT10 evidence quotes are excluded too, and deliberately. A quote is a
    verbatim copy of the transcript, so under a forced `summary_language` (an
    English summary over a Ukrainian meeting) the quotes are *supposed* to read as
    the other language. Feeding them to the detector would flag every section they
    sit in and trigger a repair of a summary that was already correct. They live
    in their own field rather than inside the section strings, so this exclusion
    is structural; keep it that way."""
    return {
        "title": [summary.title],
        "summary": list(summary.summary),
        "decisions": list(summary.decisions),
        "questions": list(summary.questions),
        "actions": [a.task for a in summary.actions],
    }


def divergent_sections(summary: MeetingSummary, target: str) -> list[str]:
    """The names of the summary sections whose detected language diverges from
    ``target``.

    Checked per section, not as one merged bag: the LANG1 case is a Russian
    ``actions`` block inside an otherwise-English summary, and merging every
    section into one string lets the English title/summary/decisions outvote and
    mask the drifted section. A section is flagged only when the detector is sure
    it reads as a different language; a too-short or ambiguous section is never
    flagged, so the check costs at most one repair, never a false alarm. Pure."""
    flagged: list[str] = []
    for name, parts in _summary_sections(summary).items():
        text = " ".join(p for p in parts if p)
        actual = language_signature(text)
        if actual is not None and actual != target:
            flagged.append(name)
    return flagged


def language_reinforcement(target: str) -> str:
    """A forceful, JSON-preserving restatement of the output language, appended
    after the schema/system prompt so it is the last thing the model reads before
    the transcript. Local models obey a directive placed here far more reliably
    than one buried in the preamble; the cloud repair pass uses the same block."""
    name = _LANGUAGE_NAMES.get(target, target)
    return (
        "\n\n---\n\n## Output language (non-negotiable)\n"
        "Write every string value in the JSON object, the title, every summary "
        "bullet, every decision, every action task, and every question, in "
        f"{name}. Do not switch to English or any other language. Keep proper "
        "nouns, product names, and code identifiers verbatim. This overrides any "
        "default to English."
    )


def language_correction_message(target: str) -> str:
    """The corrective user message for the local language-mismatch replay: same
    facts, translated into the target language, JSON only."""
    name = _LANGUAGE_NAMES.get(target, target)
    return (
        f"Your reply was not written in {name}. Rewrite the SAME summary with "
        "identical facts, but translate every string value, the title, summary "
        "bullets, decisions, action tasks, and questions, into "
        f"{name}. Keep proper nouns and code identifiers verbatim. Reply with "
        "ONLY the JSON object: no prose, no Markdown fences, no commentary."
    )
