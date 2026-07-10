"""Post-ASR glossary: deterministic vocabulary normalization at finalize.

Recurring proper nouns, client / product names, and en/uk code-switched terms
are mangled by ASR every meeting; left uncorrected the damage propagates into
summaries, embeddings, ask, and the Library transcript view. This module
applies a user-maintained glossary to the finalized transcript text BEFORE
summarize + embed ever see it, so a term is spelled the same way everywhere.

The glossary is a hand-edited TOML file at ``~/.config/meeting-pipe/glossary.toml``
(the workflows precedent: the pipeline only reads it, the user owns it). Two
layers, merged with per-workflow winning on a key clash::

    [terms]                       # global "as heard" = "canonical"
    "kubernetes" = "Kubernetes"

    [workflow."Client X".terms]   # per-workflow, keyed by workflow name
    "acme" = "ACME Corp"

Matching is case-insensitive, whole-word (Unicode / Cyrillic-aware boundaries
via ``\\b``), longest-match-first (longest key wins at each position), and
deterministic. An optional fuzzy stage (``[fuzzy] enabled = false`` by default)
normalizes a single token within a bounded edit distance of a canonical name;
a wrong substitution is worse than a missed one, so it is opt-in and
conservative (single-token names only, length >= 4).

Write-once: applied only in the ``run-all`` finalize path; re-applying to an
old meeting is an explicit regenerate, never a silent mutation.
"""
from __future__ import annotations

import logging
import re
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from .config import CONFIG_PATH
from .workflow import read_meta

log = logging.getLogger("mp.glossary")

# The hand-maintained glossary lives beside config.toml.
GLOSSARY_PATH = CONFIG_PATH.parent / "glossary.toml"

# Names shorter than this are too risky to fuzzy-match (a 3-letter name is
# within one edit of too many real words). Exact matching still covers them.
_FUZZY_MIN_LEN = 4


@dataclass
class Glossary:
    """A compiled set of substitutions ready to apply to transcript text.

    ``terms`` maps a lower-cased "as heard" key to its canonical replacement.
    Build via :func:`load_glossary`; the regex and fuzzy-name table are derived
    in ``__post_init__`` so ``apply`` stays cheap per segment.
    """

    terms: dict[str, str] = field(default_factory=dict)
    fuzzy_enabled: bool = False
    fuzzy_max_distance: int = 1
    _exact_re: re.Pattern[str] | None = field(init=False, default=None, repr=False)
    _fuzzy_names: dict[str, str] = field(init=False, default_factory=dict, repr=False)

    def __post_init__(self) -> None:
        # Longest key first so the regex alternation prefers the longest match
        # at each position (Python `re` takes the first matching alternative).
        keys = sorted(self.terms, key=len, reverse=True)
        self._exact_re = (
            re.compile(r"\b(" + "|".join(re.escape(k) for k in keys) + r")\b", re.IGNORECASE)
            if keys
            else None
        )
        # Canonical single-token names eligible for fuzzy correction, keyed by
        # their lower-cased form.
        self._fuzzy_names = {
            c.lower(): c
            for c in set(self.terms.values())
            if " " not in c and len(c) >= _FUZZY_MIN_LEN
        }

    def __bool__(self) -> bool:
        return bool(self.terms)

    def apply(self, text: str) -> tuple[str, int, int]:
        """Return ``(new_text, exact_count, fuzzy_count)``.

        Exact substitution runs first; the optional fuzzy pass runs over the
        result so it never re-touches an exact hit.
        """
        text, exact = self._apply_exact(text)
        text, fuzzy = self._apply_fuzzy(text)
        return text, exact, fuzzy

    def _apply_exact(self, text: str) -> tuple[str, int]:
        if self._exact_re is None:
            return text, 0
        count = 0

        def repl(m: re.Match[str]) -> str:
            nonlocal count
            count += 1
            return self.terms[m.group(0).lower()]

        return self._exact_re.sub(repl, text), count

    def _apply_fuzzy(self, text: str) -> tuple[str, int]:
        if not self.fuzzy_enabled or not self._fuzzy_names:
            return text, 0
        count = 0
        max_d = self.fuzzy_max_distance

        def repl(m: re.Match[str]) -> str:
            nonlocal count
            token = m.group(0)
            low = token.lower()
            if low in self._fuzzy_names:  # exact form already; leave it be
                return token
            for lname, canonical in self._fuzzy_names.items():
                if abs(len(lname) - len(low)) > max_d:
                    continue
                d = _bounded_levenshtein(low, lname, max_d)
                if d is not None and 0 < d <= max_d:
                    count += 1
                    return canonical
            return token

        return re.sub(r"\w+", repl, text), count


def _bounded_levenshtein(a: str, b: str, max_d: int) -> int | None:
    """Levenshtein distance, or ``None`` once it is known to exceed ``max_d``.

    Early-exits per row so a far-apart pair costs little; the caller also
    length-prefilters, so this only runs on plausible candidates.
    """
    la, lb = len(a), len(b)
    if abs(la - lb) > max_d:
        return None
    prev = list(range(lb + 1))
    for i in range(1, la + 1):
        cur = [i] + [0] * lb
        row_min = cur[0]
        ai = a[i - 1]
        for j in range(1, lb + 1):
            cost = 0 if ai == b[j - 1] else 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            if cur[j] < row_min:
                row_min = cur[j]
        if row_min > max_d:
            return None
        prev = cur
    return prev[lb] if prev[lb] <= max_d else None


def _merge_terms(dst: dict[str, str], section: object) -> None:
    """Fold a `[terms]` table into ``dst``, lower-casing keys (later wins)."""
    if not isinstance(section, dict):
        return
    for key, value in section.items():
        if isinstance(key, str) and isinstance(value, str) and key.strip() and value:
            dst[key.lower()] = value


def load_glossary(
    meeting_path: Path | None = None,
    *,
    path: Path | None = None,
    workflow_name: str | None = None,
) -> Glossary:
    """Load the glossary, merging global terms with the meeting's workflow.

    ``meeting_path`` is any file belonging to the meeting (its `<stem>.meta.json`
    is read for the workflow name); pass ``workflow_name`` directly to bypass
    that. ``path`` overrides the glossary file location (tests). A missing or
    malformed file yields an empty glossary (a clean no-op), never an error.
    """
    gpath = path or GLOSSARY_PATH
    if not gpath.exists():
        return Glossary()
    try:
        with gpath.open("rb") as f:
            raw = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as e:
        log.warning("glossary at %s is malformed, ignoring: %s", gpath, e)
        return Glossary()

    terms: dict[str, str] = {}
    _merge_terms(terms, raw.get("terms"))

    if workflow_name is None and meeting_path is not None:
        workflow_name = read_meta(meeting_path).get("workflow_name")
    if workflow_name:
        wf = (raw.get("workflow") or {}).get(workflow_name)
        if isinstance(wf, dict):
            _merge_terms(terms, wf.get("terms"))

    fuzzy = raw.get("fuzzy")
    fuzzy = fuzzy if isinstance(fuzzy, dict) else {}
    try:
        max_distance = int(fuzzy.get("max_distance", 1)) or 1
    except (TypeError, ValueError):
        max_distance = 1
    return Glossary(
        terms=terms,
        fuzzy_enabled=bool(fuzzy.get("enabled", False)),
        fuzzy_max_distance=max_distance,
    )
