"""`mp ask` - lexical search over the meeting library (TECH-FEAT2).

A zero-dependency "ask my meetings" MVP: it builds an in-memory TF-IDF index
over the summaries and transcripts already on disk and ranks meetings by a
query. Stdlib only (`re` / `math` / `collections` / `json` / `pathlib`); the
true on-device semantic RAG (embeddings + a vector index over the same library,
reusing the MLX model) is the follow-up this paves the way for.

Searchable corpus per meeting: `<stem>.summary.md` (when present) plus the
`<stem>.md` speaker-segmented transcript. The title is read from
`<stem>.summary.json` when available, else the stem.
"""
from __future__ import annotations

import argparse
import json
import math
import re
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

from .config import Config

_TOKEN = re.compile(r"[a-z0-9]+")


def _tokenize(text: str) -> list[str]:
    return _TOKEN.findall(text.lower())


@dataclass
class MeetingDoc:
    stem: str
    title: str
    lines: list[str]
    tf: Counter = field(default_factory=Counter)


def discover(root: Path) -> list[MeetingDoc]:
    """Build one `MeetingDoc` per meeting under `root` from its summary +
    transcript text. Meetings with neither are skipped."""
    root = root.expanduser()
    if not root.is_dir():
        return []

    stems: set[str] = set()
    for p in root.glob("*.md"):
        # `<stem>.md` is the transcript (one dot); `<stem>.summary.md` etc. have more.
        if p.name.count(".") == 1:
            stems.add(p.name.split(".", 1)[0])
    for p in root.glob("*.summary.json"):
        stems.add(p.name.split(".", 1)[0])

    docs: list[MeetingDoc] = []
    for stem in sorted(stems):
        parts: list[str] = []
        title = stem
        summary_json = root / f"{stem}.summary.json"
        if summary_json.exists():
            try:
                obj = json.loads(summary_json.read_text(encoding="utf-8"))
                if isinstance(obj, dict) and obj.get("title"):
                    title = str(obj["title"])
            except (OSError, ValueError):
                pass
        for name in (f"{stem}.summary.md", f"{stem}.md"):
            f = root / name
            if f.exists():
                parts.append(f.read_text(encoding="utf-8", errors="ignore"))
        if not parts:
            continue
        text = "\n".join(parts)
        lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
        docs.append(MeetingDoc(stem=stem, title=title, lines=lines, tf=Counter(_tokenize(text))))
    return docs


def idf(docs: list[MeetingDoc]) -> dict[str, float]:
    """Smoothed inverse document frequency across the library."""
    n = len(docs)
    df: Counter = Counter()
    for d in docs:
        df.update(d.tf.keys())   # unique terms per doc
    return {term: math.log((n + 1) / (c + 1)) + 1.0 for term, c in df.items()}


def score(query_terms: list[str], doc: MeetingDoc, weights: dict[str, float]) -> float:
    """Sum of tf * idf over the query terms - a simple, effective lexical rank."""
    return sum(doc.tf.get(t, 0) * weights.get(t, 0.0) for t in set(query_terms))


def snippet(query_terms: list[str], doc: MeetingDoc, width: int = 200) -> str:
    """The single line with the most query-term hits, for a bit of context."""
    qset = set(query_terms)
    best, best_hits = "", 0
    for ln in doc.lines:
        hits = sum(1 for t in _tokenize(ln) if t in qset)
        if hits > best_hits:
            best_hits, best = hits, ln
    return best[:width]


def search(docs: list[MeetingDoc], query: str, top: int) -> list[tuple[MeetingDoc, float]]:
    weights = idf(docs)
    terms = _tokenize(query)
    ranked = [(d, score(terms, d, weights)) for d in docs]
    ranked = [(d, s) for d, s in ranked if s > 0]
    ranked.sort(key=lambda ds: ds[1], reverse=True)
    return ranked[:top]


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="mp ask",
        description="Lexical search over the meeting library (TECH-FEAT2).",
    )
    ap.add_argument("query", nargs="+", help="search terms")
    ap.add_argument("--top", type=int, default=5, help="how many meetings to show (default 5)")
    ap.add_argument("--dir", type=Path, default=None, help="override the recordings directory")
    ap.add_argument("--json", action="store_true", dest="as_json", help="emit JSON instead of text")
    args = ap.parse_args(argv)

    root = args.dir if args.dir is not None else Config.load().recording.output_dir
    docs = discover(Path(root))
    if not docs:
        print(f"No searchable meetings under {root}.")
        return 0

    query = " ".join(args.query)
    terms = _tokenize(query)
    results = search(docs, query, args.top)

    if args.as_json:
        print(json.dumps([
            {"stem": d.stem, "title": d.title, "score": round(s, 3), "snippet": snippet(terms, d)}
            for d, s in results
        ], indent=2))
        return 0

    if not results:
        print(f"No meetings matched: {query}")
        return 0

    for d, s in results:
        print(f"{d.title}  [{d.stem}]  (score {s:.2f})")
        snip = snippet(terms, d)
        if snip:
            print(f"    {snip}")
    return 0
