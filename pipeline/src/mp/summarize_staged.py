"""LOCAL14: the staged local summarization pipeline (extract, compose, verify).

The local backend's default path asks one small model, in one shot, to read a
whole transcript, obey a ~60-line defensive master prompt plus the full
`SUMMARY_TOOL` schema pasted as text, and emit every section at once. Two
structural costs of that shape, both visible in the 2026-07-23 side-by-side:

1. The defensive rules (no inventions, default to empty) are correct
   hallucination control that a 7B over-obeys into genericity.
2. JSON discipline competes with content for the model's attention, which is why
   the 4-layer extractor and the schema-violation replay exist at all.

This module is the alternative shape. Small models are markedly better at
grounded extraction (find and quote) than at open abstraction (synthesize
everything), so the abstraction burden moves onto short, dense, already-extracted
context:

- **Stage 1 EXTRACT** maps over transcript windows sized to a real token budget
  and pulls atomic fact rows, each carrying a verbatim quote and the `[mm:ss]` of
  the turn it came from. Those quotes are FEAT10's evidence anchors for free.
- **Stage 2 COMPOSE** makes one small call per section, fed ONLY the fact rows,
  never the raw transcript. A section prompt can then demand specificity without
  starving output, because the facts list is short and dense. A composed point
  cites fact rows by index rather than retyping a quote, so a composer literally
  cannot fabricate one.
- **Stage 3 VERIFY** runs deterministic checks first (every decision and action
  must trace to a quote that really resolves in the transcript, owners must
  appear in a supporting quote, caps, dedupe) and then one LLM critic call for
  the single thing determinism cannot judge: commitment against intention.

Three measurements from the LOCAL13 bench prep
(`docs/spikes/local13-local-model-refresh-bench.md`) shape this directly.

- The fixed prompt + schema overhead of the single-pass path is **3,520 tokens**,
  larger than the transcript itself on a typical stand-up. A staged pipeline
  multiplies the number of calls, so per-stage prompt size is a first-order cost:
  every schema here is a few hundred chars, not fifteen thousand.
- The installed `mlx_lm.server` parses **no** `response_format` at all, so every
  stage decodes unconstrained. The layered JSON recovery below is load-bearing,
  not belt and braces, and each stage is written to tolerate a thinking-mode
  prefix or a Markdown fence around its object.
- Prefix caching only bites on a byte-stable prefix, so every stage's system turn
  is constant text with the volatile content last, and Stage 1 sends the
  identical system turn for every window.

Status: **not the default.** The path is reached only when the internal
`MP_STAGED_LOCAL` bake-off toggle is set, and it declines (returns None, so the
caller runs the existing single-pass shape) on a degenerate transcript or when
composition produces nothing usable. Adoption is owner-owed and gated on the
`mp dogfood` thresholds LOCAL14 pre-registers; the toggle dies at adoption, per
the HYG2 rule against knobs nothing reads.
"""
from __future__ import annotations

import json
import logging
import os
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import Any

from . import events
from .chunking import chunked_windows
from .evidence import normalize, segments_from_timestamped_markdown, verify as verify_anchors
from .json_extract import largest_balanced_json_object, repair_missing_commas
from .prompt_safety import wrap_untrusted
from .schemas import MAX_EVIDENCE_PER_ITEM, ActionItem, Evidence, MeetingSummary
from .summary_language import language_reinforcement, language_signature

log = logging.getLogger("mp.summarize_staged")

# The one internal bake-off toggle LOCAL14 permits. An environment variable and
# deliberately NOT a `config.py` key: a config key would have to be documented in
# `config.example.toml` and the README (CI5 diffs both ways), and would then have
# to be deleted from three files when the bake-off ends. `MP_CONTEXT_OVERRIDE`
# and `MP_FORCE_BYO` are the existing precedents for an internal env switch.
STAGED_ENV = "MP_STAGED_LOCAL"

# ----- Sizing -----

# Transcript tokens per Stage 1 window. The single-pass path budgets its map
# windows at a worst-case 1,500 chars; this is model-aware instead, a token
# budget converted to chars using the script actually in the transcript. Sized so
# a window plus the (small) extract preamble plus its output stays inside the 4K
# end of the context guard even on Cyrillic, which is where the incumbent 7B and
# the 14B candidates are both safe.
_EXTRACT_WINDOW_TOKENS = 2_000
# Tokens per character, measured on the real corpus under LOCAL13: English 0.22
# to 0.25, Ukrainian 0.47 to 0.49. Both take the pessimistic end, so a window
# budget is never overrun by the estimate being generous.
_TOK_PER_CHAR_LATIN = 0.25
_TOK_PER_CHAR_CYRILLIC = 0.49
# Keeps a sentence spanning a window boundary whole in at least one window.
_WINDOW_OVERLAP_CHARS = 200
# Below this the staged shape cannot pay for itself: three-plus calls against one,
# on a transcript with almost nothing to extract. Roughly two minutes of speech.
_MIN_STAGED_CHARS = 1_200
# Caps on the fact list. Per-window keeps one runaway extraction from blowing
# Stage 2's context; the total keeps a long meeting's composed input dense rather
# than becoming a second transcript.
_MAX_FACTS_PER_WINDOW = 12
_MAX_FACTS_TOTAL = 60
# Matches `SUMMARY_TOOL`'s `maxItems` for the summary section.
_MAX_SUMMARY_BULLETS = 5
# Output budget per stage call, as a fraction of the caller's max_tokens. A fact
# list or one section is far smaller than a whole summary, and a tight ceiling is
# also the cheapest guard against a thinking-mode model rambling.
_STAGE_TOKEN_FRACTION = 0.5
_MIN_STAGE_TOKENS = 512

# The fact kinds Stage 1 may emit. Deliberately closed: an open `kind` turns into
# a free-text field the composer then has to interpret.
FACT_KINDS = ("commitment", "request", "date", "artifact", "identity", "question")

# The three string sections Stage 2 composes with the shared section prompt.
_TEXT_SECTIONS = ("summary", "decisions", "questions")


def staged_enabled(env: Mapping[str, str] | None = None) -> bool:
    """Is the LOCAL14 bake-off toggle set? Default off, and it stays off until a
    `mp dogfood` verdict says otherwise. `env` is a test seam."""
    source = env if env is not None else os.environ
    return source.get(STAGED_ENV, "").strip().lower() in {"1", "true", "yes", "on"}


# ----- Stage 1: EXTRACT -----

_EXTRACT_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "facts": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "kind": {"type": "string", "enum": list(FACT_KINDS)},
                    "text": {"type": "string"},
                    "who": {"type": ["string", "null"]},
                    "quote": {"type": "string"},
                    "t": {"type": ["string", "number"]},
                },
                "required": ["kind", "text", "who", "quote", "t"],
            },
        }
    },
    "required": ["facts"],
}

_EXTRACT_SYSTEM = (
    "You extract atomic facts from one slice of a meeting transcript. You do not"
    " summarize, interpret, rank, or judge. You find and you quote.\n\n"
    "Emit one row per fact, with these fields:\n"
    "- kind: exactly one of commitment, request, date, artifact, identity, question.\n"
    "  commitment: someone said they will do something.\n"
    "  request: someone asked another person to do something.\n"
    "  date: a deadline, a scheduled moment, or a named day.\n"
    "  artifact: a ticket id, document, repository, service, or tool named in the talk.\n"
    "  identity: someone naming themselves or naming another participant.\n"
    "  question: something raised and left unresolved.\n"
    "- text: the fact in one short clause, in the transcript's own language.\n"
    "- who: the person the row is about, spelled exactly as the transcript spells"
    " it, or null when no person is named.\n"
    "- quote: a phrase copied VERBATIM from the transcript, at most 15 words. Copy"
    " it character for character. Do not paraphrase, translate, tidy, or complete it.\n"
    "- t: the [mm:ss] marker at the start of the line the quote came from.\n\n"
    "Emit no row you cannot quote. A slice where nothing happens has no facts, and"
    ' {"facts": []} is the right answer for it: an invented row is worse than a'
    " missing one.\n\n"
    "Reply with ONLY a single JSON object matching this schema. No prose, no"
    " Markdown fences, no reasoning, no commentary.\n\n"
    f"```json-schema\n{json.dumps(_EXTRACT_SCHEMA, indent=2)}\n```"
)


@dataclass(frozen=True)
class FactRow:
    """One atomic fact Stage 1 pulled out of a window.

    `quote` plus `t` is the whole point: it is what Stage 3 re-checks against the
    transcript and what becomes a FEAT10 anchor on the composed point that cites
    this row. A row without a usable quote never survives `parse_facts`.
    """

    kind: str
    text: str
    quote: str
    t: float
    who: str | None = None

    def render(self, index: int) -> str:
        """The one line Stage 2 sees for this row. Numbered, because a composer
        cites rows by index rather than retyping a quote."""
        who = f" who={self.who}" if self.who else ""
        return f'[{index}] {self.kind}{who} | {self.text} | "{self.quote}" @ {self.t:.0f}s'


def tokens_per_char(text: str) -> float:
    """Estimated tokens per character for `text`, interpolated between the two
    figures LOCAL13 measured on this corpus (Latin 0.25, Cyrillic 0.49).

    Cyrillic costs about twice as many tokens per character as English here, so a
    window budget calibrated on English stems is roughly half as generous on a
    Ukrainian meeting. Pure, so the sizing is unit-testable without a model.
    """
    cyr = sum(1 for ch in text if 0x0400 <= ord(ch) <= 0x04FF)
    letters = sum(1 for ch in text if ch.isalpha())
    if not letters:
        return _TOK_PER_CHAR_LATIN
    share = cyr / letters
    return _TOK_PER_CHAR_LATIN + share * (_TOK_PER_CHAR_CYRILLIC - _TOK_PER_CHAR_LATIN)


def window_chars(transcript: str, budget_tokens: int = _EXTRACT_WINDOW_TOKENS) -> int:
    """Characters per Stage 1 window for this transcript's script.

    The single-pass map path uses a flat worst-case 1,500 chars, which throws away
    most of an English window's budget. This converts a token budget with the
    measured ratio instead, so an English meeting gets ~8,000-char windows and a
    Ukrainian one ~4,000, both landing on the same token cost.
    """
    return max(500, int(budget_tokens / tokens_per_char(transcript)))


def parse_facts(text: str, *, limit: int = _MAX_FACTS_PER_WINDOW) -> list[FactRow]:
    """Fact rows recovered from one Stage 1 reply, or [] when nothing survives.

    Tolerant by design, and it has to be: the server constrains nothing, so a
    reply can arrive fenced, prefixed with reasoning text, or one comma short.
    The same recovery ladder the single-pass extractor walks applies here (raw,
    balanced scan, comma repair), and then every row is filtered individually, so
    one malformed row costs its own row rather than the whole window.
    """
    obj = _loads_tolerant(text)
    if not isinstance(obj, dict):
        return []
    raw = obj.get("facts")
    if not isinstance(raw, list):
        return []
    out: list[FactRow] = []
    for item in raw:
        row = _fact_row(item)
        if row is not None:
            out.append(row)
        if len(out) >= limit:
            break
    return out


def _fact_row(item: Any) -> FactRow | None:
    if not isinstance(item, dict):
        return None
    kind = item.get("kind")
    text = item.get("text")
    quote = item.get("quote")
    if kind not in FACT_KINDS or not isinstance(text, str) or not text.strip():
        return None
    if not isinstance(quote, str) or not quote.strip():
        # A row we cannot quote is a row Stage 3 can never verify, so it would
        # only ever add unanchored prose to the composer's input.
        return None
    who = item.get("who")
    # `Evidence` already decodes the `[mm:ss]` marker the model copies (FEAT10),
    # including the h:mm:ss form and plain seconds, so the coercion lives in one
    # place rather than being re-implemented per stage.
    anchor = Evidence(quote=quote.strip(), t=item.get("t", 0.0))
    return FactRow(
        kind=kind,
        text=text.strip(),
        quote=anchor.quote,
        t=anchor.t,
        who=who.strip() if isinstance(who, str) and who.strip() else None,
    )


# ----- Stage 2: COMPOSE -----

# Shared leading block of every compose system turn, so the five calls have a
# byte-identical prefix a KV cache can reuse. Section-specific text and the
# language directive follow it; the fact rows ride in the user turn, last.
_COMPOSE_PREAMBLE = (
    "You write one section of a meeting summary from a list of facts that were"
    " already extracted from the transcript. You never see the transcript itself,"
    " and you must not invent anything the facts do not contain.\n\n"
    "Every fact row is numbered and carries a verbatim quote. Each point you write"
    ' cites the rows it came from by number, in its "facts" array. A point you'
    " cannot attribute to at least one row does not belong in the section.\n\n"
    "Be specific. Name the person, the artifact, and the commitment. A point that"
    " would read the same for any meeting is not worth writing.\n\n"
)

_SECTION_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "items": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "text": {"type": "string"},
                    "facts": {"type": "array", "items": {"type": "integer"}},
                },
                "required": ["text", "facts"],
            },
        }
    },
    "required": ["items"],
}

_ACTIONS_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "items": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "task": {"type": "string"},
                    "owner": {"type": ["string", "null"]},
                    "due": {"type": ["string", "null"]},
                    "facts": {"type": "array", "items": {"type": "integer"}},
                },
                "required": ["task", "owner", "due", "facts"],
            },
        }
    },
    "required": ["items"],
}

_TITLE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {"title": {"type": "string"}},
    "required": ["title"],
}

_SECTION_INSTRUCTIONS = {
    "summary": (
        "Write the SUMMARY section: at most 5 bullets, at most 30 words each,"
        " covering what the meeting was actually about. Prefer a bullet that names"
        " a person and a concrete thing over a bullet about a topic."
    ),
    "decisions": (
        "Write the DECISIONS section: only statements the meeting actually settled,"
        " where the cited quote carries explicit commitment language (will, agreed,"
        " decided, approved). A plan to analyze, an intention to study, or an idea"
        " being floated is NOT a decision. An empty list is the right answer for a"
        " meeting that settled nothing."
    ),
    "questions": (
        "Write the QUESTIONS section: clarifications raised and left open,"
        " uncertainty someone expressed, or decisions explicitly deferred."
    ),
    "actions": (
        "Write the ACTIONS section: one entry per task somebody is expected to do."
        " The owner must be a person the cited quote names for THAT task; use null"
        " rather than guessing, and never assign every action to one person. Tools"
        " and products are never owners. Set due to an ISO 8601 date only when a"
        " cited row states one, otherwise null."
    ),
    "title": (
        "Write the TITLE: one line, under 60 characters, naming what this meeting"
        " was about. No date, no generic word like Meeting, Sync, or Discussion on"
        " its own."
    ),
}


def compose_system(section: str, target: str | None) -> str:
    """The system turn for one Stage 2 section call.

    Order matters twice over. The shared preamble comes first so the five section
    calls share a cacheable prefix, and the language directive comes last, right
    before the model starts reading, which is where a small model actually obeys
    it (the LOCAL7 finding the single-pass path relies on too).
    """
    schema = _TITLE_SCHEMA if section == "title" else (
        _ACTIONS_SCHEMA if section == "actions" else _SECTION_SCHEMA
    )
    out = (
        _COMPOSE_PREAMBLE
        + _SECTION_INSTRUCTIONS[section]
        + "\n\nReply with ONLY a single JSON object matching this schema. No prose,"
        " no Markdown fences, no reasoning, no commentary.\n\n"
        + f"```json-schema\n{json.dumps(schema, indent=2)}\n```"
    )
    if target:
        out += language_reinforcement(target)
    return out


def compose_user(facts: list[FactRow]) -> str:
    """The user turn for a Stage 2 call: the numbered fact rows and nothing else.

    The raw transcript never appears here, which is the whole point of the stage
    and is asserted directly by a test. The rows are transcript-derived, so they
    stay inside the untrusted fence exactly as the transcript would (TECH-SEC6).
    """
    rendered = "\n".join(row.render(i) for i, row in enumerate(facts))
    return (
        "Here are the facts extracted from this meeting. Write your section from"
        " these rows only.\n\n" + wrap_untrusted(rendered)
    )


@dataclass(frozen=True)
class ComposedPoint:
    """One composed point plus the fact indices it cited."""

    text: str
    facts: tuple[int, ...]
    owner: str | None = None
    due: str | None = None


def parse_points(text: str, *, key: str = "text") -> list[ComposedPoint]:
    """Composed points recovered from one Stage 2 reply, or [] when none survive.

    `key` is "text" for the three string sections and "task" for actions, which is
    the only shape difference between them.
    """
    obj = _loads_tolerant(text)
    if not isinstance(obj, dict):
        return []
    raw = obj.get("items")
    if not isinstance(raw, list):
        return []
    out: list[ComposedPoint] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        body = item.get(key)
        if not isinstance(body, str) or not body.strip():
            continue
        cited = item.get("facts")
        indices = tuple(
            i for i in (cited if isinstance(cited, list) else [])
            if isinstance(i, int) and not isinstance(i, bool) and i >= 0
        )
        owner = item.get("owner")
        due = item.get("due")
        out.append(ComposedPoint(
            text=body.strip(),
            facts=indices,
            owner=owner.strip() if isinstance(owner, str) and owner.strip() else None,
            due=due.strip() if isinstance(due, str) and due.strip() else None,
        ))
    return out


def parse_title(text: str) -> str:
    obj = _loads_tolerant(text)
    if isinstance(obj, dict):
        title = obj.get("title")
        if isinstance(title, str) and title.strip():
            return title.strip()[:120]
    return ""


def anchors_for(point: ComposedPoint, facts: list[FactRow]) -> list[Evidence]:
    """The FEAT10 anchors a composed point inherits from the rows it cited.

    Looked up rather than retyped, which is what makes fabrication structurally
    impossible at this stage: a composer can cite the wrong row, and Stage 3 will
    catch that, but it cannot invent a quote that was never extracted.
    """
    out: list[Evidence] = []
    for index in point.facts:
        if 0 <= index < len(facts):
            row = facts[index]
            out.append(Evidence(quote=row.quote, t=row.t))
        if len(out) >= MAX_EVIDENCE_PER_ITEM:
            break
    return out


# ----- Stage 3: VERIFY -----

_CRITIC_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {"keep": {"type": "array", "items": {"type": "integer"}}},
    "required": ["keep"],
}

_CRITIC_SYSTEM = (
    "You are checking a list of candidate decisions from a meeting. For each one"
    " you decide the single thing a deterministic check cannot: is this a decision"
    " the meeting actually made, or merely an intention, a plan to look into"
    " something, or an idea somebody floated?\n\n"
    "A decision carries explicit commitment language in its quote: will, agreed,"
    " decided, approved, going with. An intention does not: we should look at, it"
    " might be worth, let us think about, I want to explore.\n\n"
    "Reply with ONLY a single JSON object listing the numbers to keep. Keeping"
    " nothing is a valid answer. No prose, no Markdown fences, no reasoning.\n\n"
    f"```json-schema\n{json.dumps(_CRITIC_SCHEMA, indent=2)}\n```"
)


def critic_user(points: list[tuple[str, list[Evidence]]]) -> str:
    lines = []
    for i, (text, anchors) in enumerate(points):
        quotes = " ; ".join(f'"{a.quote}"' for a in anchors) or "(no quote)"
        lines.append(f"[{i}] {text}\n    quoted: {quotes}")
    return (
        "Which of these are decisions the meeting actually made?\n\n"
        + wrap_untrusted("\n".join(lines))
    )


def parse_keep(text: str, count: int) -> list[int] | None:
    """The indices a critic reply keeps, or None when the reply cannot be read.

    None and an empty list mean different things and the caller treats them
    differently: an unreadable critic must not silently empty the decisions list,
    so it fails open, while a critic that read the list and rejected everything is
    answering the question it was asked.
    """
    obj = _loads_tolerant(text)
    if not isinstance(obj, dict):
        return None
    raw = obj.get("keep")
    if not isinstance(raw, list):
        return None
    return [
        i for i in raw
        if isinstance(i, int) and not isinstance(i, bool) and 0 <= i < count
    ]


def owner_is_supported(owner: str, anchors: list[Evidence], row_names: set[str]) -> bool:
    """Does `owner` actually appear in the evidence backing THIS action?

    The single-pass path's worst owner failure is propagation: one name attached
    to every action because it was the only name in the transcript. So the test is
    deliberately narrow. An owner survives only when it shows up in one of this
    action's own surviving quotes, or when one of the rows this action cited named
    that person as its subject. `row_names` is therefore the names from the cited
    rows, never every name the meeting mentioned: widening it to the latter lets
    exactly the propagation this exists to stop pass unnoticed.

    Matching runs through FEAT10's `normalize`, so casing, punctuation, and
    Cyrillic all behave here the way they do in the anchor verifier.
    """
    needle = normalize(owner)
    if not needle:
        return False
    if needle in row_names:
        return True
    return any(needle in normalize(a.quote) for a in anchors)


def _dedupe(items: list[str]) -> list[int]:
    """Indices of the first occurrence of each distinct point, order preserved."""
    seen: set[str] = set()
    keep: list[int] = []
    for i, text in enumerate(items):
        key = normalize(text)
        if not key or key in seen:
            continue
        seen.add(key)
        keep.append(i)
    return keep


# ----- The pipeline -----

# What `LocalSummaryClient` hands in: a chat-completion call and a keep-warm hook.
Chat = Callable[..., str]


@dataclass(frozen=True)
class StagedResult:
    """The staged summary plus per-stage counts, for the event log and the bench."""

    summary: MeetingSummary
    windows: int
    facts: int
    dropped_unanchored: int
    dropped_by_critic: int


def run_staged(
    *,
    chat: Chat,
    transcript: str,
    target: str | None,
    max_tokens: int,
    keep_warm: Callable[[], None] | None = None,
) -> MeetingSummary | None:
    """Run the three stages, or return None to decline.

    Declining is a first-class outcome, not an error: the caller falls back to the
    existing single-pass shape, which stays in the code precisely for this. The
    two decline gates are a transcript too degenerate to extract from and a
    composition that produced no summary bullets, both of which would otherwise
    ship an empty or invented summary.

    `transcript` is the timestamped render (FEAT10's `render_markdown(
    timestamps=True)`), which is what the local client already sends; the
    `[mm:ss]` markers are what Stage 1 copies and Stage 3 resolves against.

    Total on purpose. An unexpected failure anywhere in here is a bug in a path
    that is not even the default yet, and it must cost a fallback rather than the
    meeting: the caller has a working single-pass shape sitting right behind it.
    The warning and the `staged_local_declined` event are what keep that from
    being silent, which matters while the bake-off is the whole point.
    """
    try:
        return _run_staged(
            chat=chat, transcript=transcript, target=target,
            max_tokens=max_tokens, keep_warm=keep_warm,
        )
    except Exception as e:
        log.warning("LOCAL14 staged pipeline raised (%s)", e, exc_info=True)
        _decline("staged pipeline raised", error=str(e))
        return None


def _run_staged(
    *,
    chat: Chat,
    transcript: str,
    target: str | None,
    max_tokens: int,
    keep_warm: Callable[[], None] | None,
) -> MeetingSummary | None:
    if len(transcript) < _MIN_STAGED_CHARS:
        _decline("transcript below the staged floor", chars=len(transcript))
        return None

    stage_tokens = max(_MIN_STAGE_TOKENS, int(max_tokens * _STAGE_TOKEN_FRACTION))
    windows = list(chunked_windows(
        transcript,
        max_chars=window_chars(transcript),
        overlap_chars=_WINDOW_OVERLAP_CHARS,
    ))
    facts = _extract(chat, windows, stage_tokens, keep_warm)
    if not facts:
        _decline("stage 1 extracted no facts", windows=len(windows))
        return None

    result = _compose_and_verify(
        chat=chat,
        facts=facts,
        transcript=transcript,
        target=target,
        stage_tokens=stage_tokens,
        keep_warm=keep_warm,
        windows=len(windows),
    )
    if result is None:
        _decline("stage 2 composed no summary bullets", facts=len(facts))
        return None

    events.emit(
        "pipeline",
        "staged_local_summary",
        windows=result.windows,
        facts=result.facts,
        dropped_unanchored=result.dropped_unanchored,
        dropped_by_critic=result.dropped_by_critic,
    )
    log.info(
        "LOCAL14 staged: %d window(s) -> %d fact(s); dropped %d unanchored point(s) "
        "and %d decision(s) the critic rejected",
        result.windows, result.facts, result.dropped_unanchored, result.dropped_by_critic,
    )
    return result.summary


def _decline(reason: str, **attrs: Any) -> None:
    log.info("LOCAL14 staged declined (%s); falling back to the single-pass shape", reason)
    events.emit("pipeline", "staged_local_declined", reason=reason, **attrs)


def _extract(
    chat: Chat, windows: list[Any], stage_tokens: int, keep_warm: Callable[[], None] | None
) -> list[FactRow]:
    """Stage 1 over every window. A window that errors or yields nothing costs its
    own rows, never the run: extraction is the map, and a map that loses one slice
    still composes from the rest."""
    facts: list[FactRow] = []
    for window in windows:
        if keep_warm is not None:
            keep_warm()  # a multi-window run must not lose the server to the idle timer
        try:
            reply = chat(
                messages=[
                    {"role": "system", "content": _EXTRACT_SYSTEM},
                    {"role": "user", "content": wrap_untrusted(window.text)},
                ],
                max_tokens=stage_tokens,
                response_format=_response_format("meeting_facts", _EXTRACT_SCHEMA),
            )
        except Exception as e:
            log.warning("staged extract window %d failed (%s); skipping it", window.index, e)
            continue
        facts.extend(parse_facts(reply))
        if len(facts) >= _MAX_FACTS_TOTAL:
            log.info("staged extract hit the %d-fact cap; stopping", _MAX_FACTS_TOTAL)
            break
    return facts[:_MAX_FACTS_TOTAL]


def _compose_and_verify(
    *,
    chat: Chat,
    facts: list[FactRow],
    transcript: str,
    target: str | None,
    stage_tokens: int,
    keep_warm: Callable[[], None] | None,
    windows: int,
) -> StagedResult | None:
    """Stages 2 and 3. Composition first, then the deterministic checks, then the
    single critic pass over what survived them."""
    composed: dict[str, list[ComposedPoint]] = {}
    for section in (*_TEXT_SECTIONS, "actions"):
        composed[section] = _compose(
            chat, section, facts, target, stage_tokens, keep_warm,
            key="task" if section == "actions" else "text",
        )
    if not composed["summary"]:
        return None

    verified = _verify(composed, facts, segments_from_timestamped_markdown(transcript))
    decisions, dropped_by_critic = _criticize(
        chat, verified.sections["decisions"], stage_tokens, keep_warm
    )
    verified.sections["decisions"] = decisions

    title = _compose_title(chat, facts, target, stage_tokens, keep_warm)
    return StagedResult(
        summary=_assemble(verified, facts, title, transcript, target),
        windows=windows,
        facts=len(facts),
        dropped_unanchored=verified.dropped,
        dropped_by_critic=dropped_by_critic,
    )


def _compose(
    chat: Chat,
    section: str,
    facts: list[FactRow],
    target: str | None,
    stage_tokens: int,
    keep_warm: Callable[[], None] | None,
    *,
    key: str,
) -> list[ComposedPoint]:
    if keep_warm is not None:
        keep_warm()
    schema = _ACTIONS_SCHEMA if section == "actions" else _SECTION_SCHEMA
    try:
        reply = chat(
            messages=[
                {"role": "system", "content": compose_system(section, target)},
                {"role": "user", "content": compose_user(facts)},
            ],
            max_tokens=stage_tokens,
            response_format=_response_format(f"meeting_{section}", schema),
        )
    except Exception as e:
        # One section failing must not sink the others; an empty section is a
        # legitimate value for all four of them.
        log.warning("staged compose of %s failed (%s); leaving it empty", section, e)
        return []
    points = parse_points(reply, key=key)
    return points[:_MAX_SUMMARY_BULLETS] if section == "summary" else points


def _compose_title(
    chat: Chat,
    facts: list[FactRow],
    target: str | None,
    stage_tokens: int,
    keep_warm: Callable[[], None] | None,
) -> str:
    if keep_warm is not None:
        keep_warm()
    try:
        reply = chat(
            messages=[
                {"role": "system", "content": compose_system("title", target)},
                {"role": "user", "content": compose_user(facts)},
            ],
            max_tokens=_MIN_STAGE_TOKENS,
            response_format=_response_format("meeting_title", _TITLE_SCHEMA),
        )
    except Exception as e:
        log.warning("staged compose of title failed (%s)", e)
        return ""
    return parse_title(reply)


@dataclass
class Verified:
    """What survived the deterministic half of Stage 3.

    `sections` pairs each surviving point with the anchors that backed it, so the
    two stay index-aligned through the critic pass and the final assembly without
    anyone having to re-zip two parallel lists.
    """

    sections: dict[str, list[tuple[str, list[Evidence]]]]
    actions: list[ActionItem]
    dropped: int


def _verify(
    composed: dict[str, list[ComposedPoint]],
    facts: list[FactRow],
    segments: list[dict[str, Any]],
) -> Verified:
    """The deterministic half of Stage 3.

    Every composed point is given the anchors of the rows it cited, and the whole
    draft goes through FEAT10's own `evidence.verify` against segments recovered
    from the timestamped transcript. That is deliberately the same verifier the
    summarizer runs downstream rather than a second implementation of the rule, so
    a quote a Stage 1 model invented is dropped by exactly the check that would
    have dropped it after the fact.

    Then: decisions and actions with no surviving anchor are dropped entirely (an
    unattributable decision is the failure mode this pipeline exists to remove),
    owners not named in a supporting quote fall back to null, and every section is
    deduped.
    """
    draft = MeetingSummary.model_validate({
        "title": "draft",
        "summary": [p.text for p in composed["summary"]],
        "decisions": [p.text for p in composed["decisions"]],
        "questions": [p.text for p in composed["questions"]],
        "actions": [
            {"task": p.text, "owner": p.owner, "due": p.due,
             "evidence": anchors_for(p, facts)}
            for p in composed["actions"]
        ],
        "evidence": {
            section: [anchors_for(p, facts) for p in composed[section]]
            for section in _TEXT_SECTIONS
        },
    })
    checked = verify_anchors(draft, segments).summary

    sections: dict[str, list[tuple[str, list[Evidence]]]] = {}
    dropped = 0
    for section in _TEXT_SECTIONS:
        texts = list(getattr(checked, section))
        anchors = checked.evidence.get(section) or [[] for _ in texts]
        pairs = list(zip(texts, anchors))
        if section == "decisions":
            # Only decisions and actions carry the trace-to-a-quote requirement;
            # a summary bullet or an open question is legitimately synthesized.
            kept = [p for p in pairs if p[1]]
            dropped += len(pairs) - len(kept)
            pairs = kept
        keep = _dedupe([text for text, _ in pairs])
        sections[section] = [pairs[i] for i in keep]

    actions: list[ActionItem] = []
    # `verify` copies each action in place, so the checked list stays aligned with
    # the composed one and each action can be paired back with the rows it cited.
    for point, action in zip(composed["actions"], checked.actions):
        if not action.evidence:
            dropped += 1
            continue
        owner = action.owner
        cited_names = {
            normalize(facts[i].who or "")
            for i in point.facts if 0 <= i < len(facts) and facts[i].who
        }
        if owner and not owner_is_supported(owner, action.evidence, cited_names):
            log.info("staged verify: owner %r is not named in a supporting quote", owner)
            owner = None
        actions.append(action.model_copy(update={
            "owner": owner,
            "confidence": "medium" if owner else "low",
        }))
    keep = _dedupe([a.task for a in actions])
    return Verified(
        sections=sections,
        actions=[actions[i] for i in keep],
        dropped=dropped,
    )


def _criticize(
    chat: Chat,
    decisions: list[tuple[str, list[Evidence]]],
    stage_tokens: int,
    keep_warm: Callable[[], None] | None,
) -> tuple[list[tuple[str, list[Evidence]]], int]:
    """The one LLM call in Stage 3: commitment against intention, on the decisions
    that already survived the deterministic checks.

    Deliberately a single pass and not the open-ended self-refine loop the task's
    sketch reached for. Self-refine at 7 to 14B tends to paraphrase rather than
    improve, so a second pass would have to earn its place on the bench before it
    is written. Fails open in both directions: no decisions means no call, and an
    unreadable reply keeps the list untouched, because a critic that cannot be
    read must never cost content that passed determinism.
    """
    if not decisions:
        return decisions, 0
    if keep_warm is not None:
        keep_warm()
    try:
        reply = chat(
            messages=[
                {"role": "system", "content": _CRITIC_SYSTEM},
                {"role": "user", "content": critic_user(decisions)},
            ],
            max_tokens=stage_tokens,
            response_format=_response_format("decision_critic", _CRITIC_SCHEMA),
        )
    except Exception as e:
        log.warning("staged critic call failed (%s); keeping every decision", e)
        return decisions, 0
    keep = parse_keep(reply, len(decisions))
    if keep is None:
        log.warning("staged critic reply could not be read; keeping every decision")
        return decisions, 0
    kept = [decisions[i] for i in sorted(set(keep))]
    return kept, len(decisions) - len(kept)


def _assemble(
    verified: Verified,
    facts: list[FactRow],
    title: str,
    transcript: str,
    target: str | None,
) -> MeetingSummary:
    """Build the final `MeetingSummary` from what survived Stage 3.

    Two fields are derived rather than composed, because a model call for either
    would buy nothing a deterministic read of the fact rows does not already have.
    `attendees` is every distinct person Stage 1 named as a row's subject, which is
    exactly what the identity and name-cue rows are extracted for; the schema's own
    `clean_person` scrub then runs on them as it does for every backend.
    `detected_language` is the cheap script read the language check already trusts.
    """
    sections = {
        section: [text for text, _ in verified.sections[section]]
        for section in _TEXT_SECTIONS
    }
    evidence = {
        section: [anchors for _, anchors in verified.sections[section]]
        for section in _TEXT_SECTIONS
    }
    attendees: list[str] = []
    seen: set[str] = set()
    for row in facts:
        if not row.who:
            continue
        key = normalize(row.who)
        if key and key not in seen:
            seen.add(key)
            attendees.append(row.who)
    fallback = sections["summary"][0][:120] if sections["summary"] else "Meeting"
    return MeetingSummary.model_validate({
        "title": title or fallback,
        **sections,
        "actions": verified.actions,
        "attendees": attendees,
        "detected_language": target or language_signature(transcript) or "en",
        "evidence": {k: v for k, v in evidence.items() if any(v)},
    })


# ----- Shared plumbing -----


def _response_format(name: str, schema: dict[str, Any]) -> dict[str, Any]:
    """The OpenAI structured-output hint for one stage.

    The installed `mlx_lm.server` parses no `response_format` at all (measured
    under LOCAL13), so this constrains nothing today and every stage is decoded
    unconstrained. It is sent anyway because the request stays valid
    OpenAI-compatible JSON either way, and because the day the seam does honor it,
    a per-stage minimal schema is the shape that benefits: it is the same schema
    the prompt above already carries as text.
    """
    return {
        "type": "json_schema",
        "json_schema": {"name": name, "schema": schema, "strict": True},
    }


def _loads_tolerant(text: str) -> Any:
    """Parse one stage's reply, walking the same recovery ladder the single-pass
    extractor does: the raw body, the largest balanced object (prose, a thinking
    prefix, or a Markdown fence around it), then the lenient comma repair that a
    7B dropping one comma made load-bearing on 2026-07-27.

    Returns None rather than raising. Every caller filters what it gets anyway, so
    an unreadable stage degrades to an empty section instead of an exception the
    whole run has to catch.
    """
    for candidate in (text.strip(), largest_balanced_json_object(text)):
        if not candidate:
            continue
        for attempt in (candidate, repair_missing_commas(candidate)):
            if not attempt:
                continue
            try:
                return json.loads(attempt)
            except json.JSONDecodeError:
                continue
    return None
