"""Balanced-JSON extraction shared by the text-completion providers.

The local MLX path and the `claude_cli` provider both prompt a plain
text-completion engine for a single JSON object and then have to recover it from
output that may carry leading/trailing prose. This is the robust recovery step:
a brace-counter that tracks string state so braces inside strings do not throw
off the depth, returning the largest top-level object.

Promoted out of `summarize_local` (PROV1) so the provider modules share one
implementation rather than each carrying a private copy (the pipeline's
"promote, don't copy a sibling's helper" rule). Pure stdlib; a Swift mirror
(`AppleIntelligenceSummarizer.largestJSONObject`) is pinned separately by CI3.

`parse_summary` sits here for the same reason (ARCH5): both PROV1 providers had
a private copy of the scan-then-validate step, differing only in which provider
error they raise on exhaustion, so the recovery policy could drift per provider.

`repair_missing_commas` is the lenient last resort, and it is load-bearing for
the local backend specifically: mlx-lm 0.31.3 parses no `response_format` at all
(measured under LOCAL13), so the model decodes unconstrained and nothing but
prompt discipline keeps its output parseable. A 7B dropping one comma between
`"text"` and `"evidence"` cost a whole meeting on 2026-07-27, because every
recovery step above it ends in a strict `json.loads` and the balanced scan
counts braces only, so it returns a span that is balanced but not parseable.
"""
from __future__ import annotations

import json

from pydantic import ValidationError

from .schemas import MeetingSummary


def largest_balanced_json_object(text: str) -> str | None:
    """Return the largest top-level `{...}` block in `text`, or None.

    Walks the string with a brace counter, tracking string/escape state so a
    brace inside a JSON string literal does not shift the depth. Picks the
    biggest balanced top-level object, which is robust to prose or Markdown
    fences around the JSON.
    """
    best: tuple[int, int, int] | None = None  # (length, start, end)
    depth = 0
    start = -1
    in_str = False
    escape = False
    for i, ch in enumerate(text):
        if in_str:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
            continue
        if ch == "{":
            if depth == 0:
                start = i
            depth += 1
            continue
        if ch == "}":
            if depth == 0:
                continue
            depth -= 1
            if depth == 0 and start >= 0:
                length = i - start + 1
                if best is None or length > best[0]:
                    best = (length, start, i + 1)
                start = -1
    if best is None:
        return None
    return text[best[1]:best[2]]


# Chars that can end a JSON value: a closing quote/brace/bracket, a digit, or the
# last letter of `true` / `false` / `null`.
_VALUE_END = set('"}]0123456789elu')
# Chars that can start the next member of an object or array.
_MEMBER_START = set('"{[-0123456789tfn')


def repair_missing_commas(text: str) -> str | None:
    """Insert commas a model forgot between members, or None if none were missing.

    Walks `text` with the same string/escape awareness as the balanced scan, so
    punctuation inside a string literal is never touched. At depth >= 1, a member
    can only start where the last significant character was a separator (`,` `:`)
    or an opener (`{` `[`); when it instead follows the end of a value, the model
    dropped a comma and one goes in.

    Deliberately narrow. It fires only after a strict parse has already failed,
    so the worst case is a candidate that still does not parse, never a mangled
    object that does. Trailing commas are the mirror defect and are NOT handled;
    add them the same way if one ever shows up in a real reply.
    """
    out: list[str] = []
    last = ""  # last significant char seen outside a string
    depth = 0
    in_str = False
    escape = False
    # Inside a bare literal (number / true / false / null). Load-bearing: without
    # it the `-` of an exponent like `1e-5` reads as a member start following the
    # value-ending `e`, and the repair would corrupt a number that parsed fine.
    in_literal = False
    inserted = 0
    for ch in text:
        if in_str:
            out.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_str = False
                last = '"'
            continue
        if ch.isspace():
            in_literal = False
            out.append(ch)
            continue
        if in_literal and ch not in '{}[],:"':
            out.append(ch)
            last = ch
            continue
        if depth >= 1 and ch in _MEMBER_START and last in _VALUE_END:
            # `last` is the end of a value and this starts another member with no
            # separator between them: exactly the comma the model dropped.
            out.append(",")
            inserted += 1
        out.append(ch)
        if ch == '"':
            in_str = True
            in_literal = False
        elif ch in "{[":
            depth += 1
            in_literal = False
        elif ch in "}]":
            depth = max(0, depth - 1)
            in_literal = False
        elif ch in ",:":
            in_literal = False
        else:
            in_literal = True
        last = ch
    if not inserted:
        return None
    return "".join(out)


def parse_summary(text: str, *, error: type[Exception], message: str) -> MeetingSummary:
    """Validate a model's text into a `MeetingSummary`, recovering the JSON
    object from any surrounding prose with the shared balanced-object scan.

    Tries the whole reply first (the common case: the model obeyed and emitted
    bare JSON), then the largest balanced object (prose or Markdown fences
    around it). `error` / `message` let each provider raise its own exception
    type on exhaustion, which is the only thing that differed between the two
    private copies this replaced; callers catch that type in their repair loop.
    """
    for candidate in (text.strip(), largest_balanced_json_object(text)):
        if not candidate:
            continue
        try:
            return MeetingSummary.model_validate(json.loads(candidate))
        except (json.JSONDecodeError, ValidationError):
            continue
    raise error(message)
