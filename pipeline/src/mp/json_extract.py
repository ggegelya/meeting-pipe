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
"""
from __future__ import annotations


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
