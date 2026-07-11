"""Named-third-party voiceprint roster (FEAT3-ROSTER).

Extends the single self-voiceprint (FEAT3-VOICEPRINT) to a roster of named
people. Each person carries a small set of enrolled sample embeddings, reduced
to up to three k-means centroids so one outlier sample can't dominate a match.
Matching uses a two-gate accept rule (top similarity AND a runner-up margin) so
the roster biases to leaving a speaker unknown over pinning a wrong name.

Stdlib-only (json, math, pathlib). Embeddings are 256-d and L2-normalized; the
per-person sample count is capped, so the k-means stays trivially cheap.
"""
from __future__ import annotations

import json
from pathlib import Path

from .diarize import cosine_similarity
from .voiceprint import EMBEDDING_DIM, _l2_normalize

ROSTER_PATH = Path("~/.config/meeting-pipe/roster.json").expanduser()

_SCHEMA_VERSION = 1
_MAX_CENTROIDS = 3
_MAX_SAMPLES = 12  # per person; oldest samples drop out so the roster self-bounds

# Two-gate accept rule. Top centroid similarity must clear MATCH_MIN, and the
# gap to the runner-up person must clear MATCH_MARGIN; otherwise leave unknown.
MATCH_MIN = 0.65
MATCH_MARGIN = 0.07


def _mean(vectors: list[list[float]]) -> list[float]:
    n = len(vectors)
    dim = len(vectors[0])
    acc = [0.0] * dim
    for v in vectors:
        for i in range(dim):
            acc[i] += v[i]
    return [x / n for x in acc]


def kmeans_centroids(samples: list[list[float]], k: int = _MAX_CENTROIDS) -> list[list[float]]:
    """Up to `k` L2-normalized centroids over `samples` (spherical k-means).

    Deterministic: centroids seed from evenly-spaced samples (sorted by first
    component), so the same samples always yield the same centroids and tests
    are stable. Cosine assignment suits the L2-normalized WeSpeaker vectors.
    """
    pts = [s for s in samples if s]
    if not pts:
        return []
    k = min(k, len(pts))
    if k <= 1:
        return [_l2_normalize(_mean(pts))]
    order = sorted(range(len(pts)), key=lambda i: pts[i][0])
    centroids = [pts[order[i * len(pts) // k]] for i in range(k)]
    for _ in range(10):
        clusters: list[list[list[float]]] = [[] for _ in range(k)]
        for p in pts:
            j = max(range(k), key=lambda c: cosine_similarity(p, centroids[c]))
            clusters[j].append(p)
        new_centroids = [
            _l2_normalize(_mean(clusters[c])) if clusters[c] else centroids[c]
            for c in range(k)
        ]
        if new_centroids == centroids:
            break
        centroids = new_centroids
    return centroids


class RosterStore:
    """Named third-party voiceprints at ~/.config/meeting-pipe/roster.json.

    Shape: ``{"schema_version": 1, "people": [{"name", "samples", "centroids"}]}``.
    Absent / malformed file means an empty roster (every speaker stays unknown).
    """

    def __init__(self, path: Path | None = None) -> None:
        self.path = path or ROSTER_PATH

    def _people(self) -> list[dict]:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return []
        people = data.get("people")
        return people if isinstance(people, list) else []

    def names(self) -> list[str]:
        return [p["name"] for p in self._people() if isinstance(p.get("name"), str)]

    def match(
        self,
        embedding: list[float] | None,
        *,
        min_similarity: float = MATCH_MIN,
        margin: float = MATCH_MARGIN,
    ) -> str | None:
        """Return the roster name best matching `embedding` under the two-gate
        rule, or None (leave unknown). A single enrolled person only needs to
        clear `min_similarity`; two close people fail the margin and stay
        unknown, so a stranger is never pinned to the wrong name."""
        people = self._people()
        if not embedding or not people:
            return None
        scored: list[tuple[float, str]] = []
        for p in people:
            name = p.get("name")
            centroids = p.get("centroids") or []
            if not isinstance(name, str) or not centroids:
                continue
            best = max((cosine_similarity(embedding, c) for c in centroids), default=-1.0)
            scored.append((best, name))
        if not scored:
            return None
        scored.sort(key=lambda t: t[0], reverse=True)
        top_sim, top_name = scored[0]
        if top_sim < min_similarity:
            return None
        runner_up = scored[1][0] if len(scored) > 1 else -1.0
        if top_sim - runner_up < margin:
            return None
        return top_name

    def enroll(self, name: str, embedding: list[float]) -> None:
        """Add a sample embedding to `name` (creating the person if new) and
        recompute their centroids. A wrong-dimension embedding is ignored."""
        name = name.strip()
        if not name or len(embedding) != EMBEDDING_DIM:
            return
        sample = _l2_normalize([float(x) for x in embedding])
        people = self._people()
        person = next((p for p in people if p.get("name") == name), None)
        if person is None:
            person = {"name": name, "samples": []}
            people.append(person)
        samples = [s for s in person.get("samples", []) if len(s) == EMBEDDING_DIM]
        samples.append(sample)
        samples = samples[-_MAX_SAMPLES:]
        person["samples"] = samples
        person["centroids"] = kmeans_centroids(samples)
        self._write(people)

    def forget(self, name: str) -> bool:
        """Remove a person from the roster. Returns True if one was removed."""
        people = self._people()
        kept = [p for p in people if p.get("name") != name]
        if len(kept) == len(people):
            return False
        self._write(kept)
        return True

    def rename(self, old: str, new: str) -> bool:
        """Rename a roster person, keeping their samples and centroids untouched
        (FEAT3-MANAGE). Returns True when `old` was found and now reads as `new`.
        A no-op returns False and writes nothing: an empty `new`, an absent `old`,
        or a `new` that collides with a different existing person (renaming is not
        merging). Renaming a person to their current name is a True no-op."""
        new = new.strip()
        if not new:
            return False
        people = self._people()
        person = next((p for p in people if p.get("name") == old), None)
        if person is None:
            return False
        if new == old:
            return True
        if any(p.get("name") == new for p in people):
            return False
        person["name"] = new
        self._write(people)
        return True

    def _write(self, people: list[dict]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = {"schema_version": _SCHEMA_VERSION, "people": people}
        tmp = self.path.with_name(self.path.name + ".tmp")
        tmp.write_text(json.dumps(payload), encoding="utf-8")
        tmp.replace(self.path)
