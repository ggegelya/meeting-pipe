"""FEAT10: verify a summary's evidence anchors against the real transcript.

The model attaches anchors while it writes (see `schemas.SUMMARY_TOOL`), which is
the only way they can stay aligned with the points they back. But a model that
invents a quote or misreads a `[mm:ss]` marker would otherwise ship a citation
that resolves to nothing, and a wrong citation is worse than no citation: the
whole point of the feature is that a reader can check a bullet without replaying
audio. So every anchor is re-checked here, against the same segments the Library
renders, before anything is written.

The rule, in one line: an anchor survives only if its timestamp lands on (or
within `SNAP_WINDOW_SEC` of) a real segment AND its quote is really in the
transcript around that time. Survivors get their `t` snapped to the source
segment's start, so a chip click lands on that row rather than near it. Everything
else is dropped silently, per the standing "absence over wrong anchors" call, and
the kept/dropped counts go to the event log so a backend that cites badly is
visible rather than merely quiet.

This is `mp ask`'s `rag.verify_citations` applied one level down: same shape (the
model cites, we check it against ground truth, unverifiable citations are
dropped), different unit (a transcript segment instead of a meeting stem).

`segments_from_timestamped_markdown` (LOCAL14) is the same check run one step
earlier. The staged local pipeline verifies its anchors *before* it assembles a
summary, and at that point it holds the timestamped transcript render rather than
the `<stem>.json` segments, so it recovers segments from the render and calls the
verifier below. One rule, one implementation, two call sites.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any

from .schemas import EVIDENCE_SECTIONS, Evidence, MeetingSummary

# How far an anchor's timestamp may sit from a real segment and still resolve.
# Generous on purpose: the model reads a `[mm:ss]` marker on a merged *turn*, so
# a quote from late in a long turn legitimately carries the turn's opening time.
# The quote match is the strict half of the check; this one only has to find the
# right neighbourhood.
SNAP_WINDOW_SEC = 45.0
# A "verbatim phrase" past this many words is not a phrase, it is a paragraph the
# model pasted. The schema asks for <=15; this is the tolerant ceiling at which a
# quote stops being a quote, and dropping it keeps a hover card readable.
MAX_QUOTE_WORDS = 25


def normalize(text: str) -> str:
    """Casefolded, punctuation-stripped, whitespace-collapsed text for matching.

    Deliberately tolerant: the model retypes a quote from a transcript that may
    carry different capitalization, a trailing comma, or a smart apostrophe, and
    failing an otherwise-correct citation over punctuation would make the feature
    look broken. `str.isalnum` is Unicode-aware, so Cyrillic survives this exactly
    as Latin does, which matters because most of this user's meetings are not in
    English.
    """
    return " ".join("".join(c if c.isalnum() else " " for c in text.casefold()).split())


@dataclass(frozen=True)
class _Segment:
    start: float
    end: float
    norm: str

    def distance(self, t: float) -> float:
        """Seconds from `t` to this segment's span; 0 while inside it."""
        if self.start <= t <= self.end:
            return 0.0
        return min(abs(self.start - t), abs(self.end - t))


@dataclass(frozen=True)
class VerifyResult:
    """The verified summary plus what the pass did, for the event log."""

    summary: MeetingSummary
    kept: int
    dropped: int


def _prepare(segments: list[dict[str, Any]]) -> list[_Segment]:
    """Normalize the raw `<stem>.json` segments once, so a summary with a dozen
    anchors does not re-normalize the whole transcript a dozen times."""
    out: list[_Segment] = []
    for seg in segments:
        if seg.get("kind") == "gap":
            continue  # a recording-break marker, not something anyone said
        text = seg.get("text")
        if not isinstance(text, str) or not text.strip():
            continue
        start = _as_float(seg.get("start"))
        end = _as_float(seg.get("end"))
        if start is None:
            continue
        out.append(_Segment(start=start, end=end if end is not None else start, norm=normalize(text)))
    out.sort(key=lambda s: s.start)
    return out


# One turn of `markdown.render_markdown(timestamps=True)`:
# `[mm:ss] **Speaker**: text`, or `[h:mm:ss]` past the hour. The speaker block is
# optional so a turn rendered without one still contributes its text.
_TURN = re.compile(r"^\[(?P<t>\d+(?::\d{1,2})*)\]\s*(?:\*\*[^*]*\*\*:\s*)?(?P<text>.*)$")


def segments_from_timestamped_markdown(markdown: str) -> list[dict[str, Any]]:
    """Recover `verify`-shaped segments from a timestamped transcript render.

    The staged local pipeline (LOCAL14) has the render, not the `<stem>.json` it
    came from, so this reverses just enough of `render_markdown(timestamps=True)`
    to let the same verifier run: one segment per marked turn, spanning until the
    next one starts. Non-turn lines (the header, the language note, a recording-gap
    divider) carry no marker and are skipped, so nothing anyone did not say ever
    becomes a segment to match a quote against.

    The `[mm:ss]` marker decodes through `Evidence`, which already accepts the
    `mm:ss`, `h:mm:ss`, and bare-seconds forms, rather than a second parser here.
    `model_validate` rather than the constructor because that tolerance lives in a
    `mode="before"` validator, while the field itself is typed `float`.
    """
    rows: list[dict[str, Any]] = []
    for line in markdown.splitlines():
        m = _TURN.match(line.strip())
        if m is None:
            continue
        text = m.group("text").strip()
        if not text:
            continue
        start = Evidence.model_validate({"quote": "", "t": m.group("t")}).t
        rows.append({"start": start, "text": text})
    for i, row in enumerate(rows[:-1]):
        # A turn runs until the next one begins; the last one is a point, which
        # `_prepare` already handles by treating a missing end as the start.
        row["end"] = rows[i + 1]["start"]
    return rows


def _as_float(value: Any) -> float | None:
    # `bool` is an `int` subclass; a JSON `true` is not a timestamp.
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def resolve(anchor: Evidence, segments: list[_Segment]) -> float | None:
    """The snapped start time for `anchor`, or None when it does not check out.

    Two gates, both required:

    1. **Time.** At least one segment sits within `SNAP_WINDOW_SEC` of `anchor.t`.
    2. **Quote.** The normalized quote appears in that window's text.

    The returned time is the start of the segment that actually carries the
    quote, when one does. That is a shade stricter than "snap to whichever
    segment the timestamp landed nearest", and it is what makes a chip click land
    on the cited row instead of merely near it. A quote that spans a turn
    boundary matches the joined window and falls back to the nearest segment.
    """
    quote = normalize(anchor.quote)
    if not quote or len(quote.split()) > MAX_QUOTE_WORDS:
        return None
    window = [s for s in segments if s.distance(anchor.t) <= SNAP_WINDOW_SEC]
    if not window:
        return None
    for seg in window:
        if quote in seg.norm:
            return seg.start
    if quote in " ".join(s.norm for s in window):
        return min(window, key=lambda s: (s.distance(anchor.t), s.start)).start
    return None


def _verify_anchors(anchors: list[Evidence], segments: list[_Segment]) -> tuple[list[Evidence], int]:
    """Surviving anchors (times snapped) and how many were dropped."""
    kept: list[Evidence] = []
    dropped = 0
    for anchor in anchors:
        snapped = resolve(anchor, segments)
        if snapped is None:
            dropped += 1
            continue
        kept.append(Evidence(quote=anchor.quote, t=snapped))
    return kept, dropped


def verify(summary: MeetingSummary, segments: list[dict[str, Any]]) -> VerifyResult:
    """Drop every anchor that does not resolve to a real transcript segment.

    Pass the segments the summary was generated from (`<stem>.json` with both
    reversible overlays applied). An empty list is a legitimate input, not an
    error: a BYO-paste meeting has no structured transcript, so nothing can be
    verified and every anchor is dropped, which is the same "absence over wrong
    anchors" answer the local map-reduce and Apple Intelligence paths give.

    Returns a new summary; the input is not mutated.
    """
    prepared = _prepare(segments)
    kept_total = 0
    dropped_total = 0

    actions = []
    for action in summary.actions:
        kept, dropped = _verify_anchors(action.evidence, prepared)
        kept_total += len(kept)
        dropped_total += dropped
        actions.append(action.model_copy(update={"evidence": kept}))

    evidence: dict[str, list[list[Evidence]]] = {}
    for section in EVIDENCE_SECTIONS:
        anchors_per_item = summary.evidence.get(section)
        if not anchors_per_item:
            continue
        verified: list[list[Evidence]] = []
        for anchors in anchors_per_item:
            kept, dropped = _verify_anchors(anchors, prepared)
            kept_total += len(kept)
            dropped_total += dropped
            verified.append(kept)
        if any(verified):
            evidence[section] = verified

    return VerifyResult(
        summary=summary.model_copy(update={"actions": actions, "evidence": evidence}),
        kept=kept_total,
        dropped=dropped_total,
    )
