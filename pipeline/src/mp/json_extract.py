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
