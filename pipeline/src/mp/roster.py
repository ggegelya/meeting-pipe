"""Named-third-party voiceprint roster (FEAT3-ROSTER).

Extends the single self-voiceprint (FEAT3-VOICEPRINT) to a roster of named
people. Each person carries a small set of enrolled sample embeddings, reduced
to up to three k-means centroids so one outlier sample can't dominate a match.
Matching uses a two-gate accept rule (top similarity AND a runner-up margin) so
the roster biases to leaving a speaker unknown over pinning a wrong name.

A declined match still knows who the voice came closest to, and `match_detail`
reports it (FEAT14) instead of discarding it with the ranking. That near miss is
a suggestion for a person to accept by hand, never a name anything writes on its
own: the two gates above decide every automatic name and are untouched by it.

Stdlib-only (json, math, pathlib). Embeddings are 256-d and L2-normalized; the
per-person sample count is capped, so the k-means stays trivially cheap.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import NamedTuple

from . import storage
from .diarize import cosine_similarity
from .voiceprint import EMBEDDING_DIM, _l2_normalize

ROSTER_PATH = Path("~/.config/meeting-pipe/roster.json").expanduser()

_SCHEMA_VERSION = 1
_MAX_CENTROIDS = 3
_MAX_SAMPLES = 12  # per person; oldest samples drop out so the roster self-bounds

# A legacy sample (no recorded provenance) is attributed to a meeting only when its
# stored vector equals that meeting's re-normalised label vector. Enrolment stores
# `_l2_normalize(embedding)` deterministically, so the same sidecar reproduces the
# sample to float precision, while a different voice or a re-transcribed sidecar
# lands far below this (FEAT24).
UNENROLL_MATCH_MIN = 0.9999

# Two-gate accept rule. Top centroid similarity must clear MATCH_MIN, and the
# gap to the runner-up person must clear MATCH_MARGIN; otherwise leave unknown.
MATCH_MIN = 0.65
MATCH_MARGIN = 0.07

# The floor under a *suggestion* (FEAT14), well below MATCH_MIN because the whole
# point is the band the accept rule refuses. Under it the top candidate is a
# stranger rather than a near miss: every roster has a closest person to any voice,
# so with no floor at all the app would offer a name for every unknown speaker it
# ever hears, and a suggestion that is usually wrong teaches the owner to ignore
# the one that is right. Not a config knob, for the same reason the two gates
# above are not: it is a property of the matcher, not of a deployment.
SUGGEST_MIN = 0.50


class MatchResult(NamedTuple):
    """What one voice scored against the roster (FEAT14).

    `name` is the two-gate verdict and the only value anything auto-names from;
    it is exactly what `match` returns. `near_miss` is the person the voice came
    closest to when the verdict was to decline, offered to a human to accept or
    ignore. `similarity` is the top candidate's cosine, kept inside the pipeline:
    it is a distance between two vectors, not the probability that this is Dana,
    and a number shown beside a name is read as a confidence it cannot support.
    """

    name: str | None
    near_miss: str | None
    similarity: float | None


_NO_CANDIDATES = MatchResult(None, None, None)


def _fingerprint(sample: list[float]) -> str:
    """A short stable digest of one stored sample (FEAT24), kept in its `sources`
    entry so a provenance record is trusted only beside the exact vector it was
    written for. An older writer that appends and evicts without knowing about
    `sources` leaves both lists the same length but shifted by one; without this
    the shifted entries would attribute a sample to the wrong meeting."""
    return hashlib.sha1(json.dumps(sample).encode("utf-8"), usedforsecurity=False).hexdigest()[:12]


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

    Shape: ``{"schema_version": 1, "people": [{"name", "samples", "sources",
    "centroids"}]}``. `sources` (FEAT24) is index-aligned with `samples`: each entry
    is ``{"stem", "label", "fp"}`` naming the meeting speaker the sample was taken
    from (`fp` fingerprints the sample so a shifted list is never believed), or
    ``null`` for a sample enrolled before provenance existed. It is additive, so
    a roster written without it loads unchanged and every older reader still sees
    `samples` as before. Absent / malformed file means an empty roster (every
    speaker stays unknown).
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
        return self.match_detail(
            embedding, min_similarity=min_similarity, margin=margin
        ).name

    def match_detail(
        self,
        embedding: list[float] | None,
        *,
        min_similarity: float = MATCH_MIN,
        margin: float = MATCH_MARGIN,
        suggest_min: float = SUGGEST_MIN,
    ) -> MatchResult:
        """`match`'s verdict plus what it took to reach it (FEAT14).

        The accept rule is the whole of the automatic naming and is unchanged:
        `name` is set only when the top candidate clears `min_similarity` AND the
        gap to the runner-up person clears `margin`. What is new is that a
        decline no longer throws the ranking away.

        `near_miss` is offered only when the *sole* thing standing in the way was
        the similarity floor: a top candidate the runner-up is level with is a
        coin flip between two enrolled people, and putting one of those two names
        in front of the owner is the wrong-name outcome the margin gate exists to
        prevent. Below `suggest_min` nobody is near enough to name at all.
        """
        people = self._people()
        if not embedding or not people:
            return _NO_CANDIDATES
        scored: list[tuple[float, str]] = []
        for p in people:
            name = p.get("name")
            centroids = p.get("centroids") or []
            if not isinstance(name, str) or not centroids:
                continue
            best = max((cosine_similarity(embedding, c) for c in centroids), default=-1.0)
            scored.append((best, name))
        if not scored:
            return _NO_CANDIDATES
        scored.sort(key=lambda t: t[0], reverse=True)
        top_sim, top_name = scored[0]
        runner_up = scored[1][0] if len(scored) > 1 else -1.0
        clears_margin = top_sim - runner_up >= margin
        if top_sim >= min_similarity and clears_margin:
            return MatchResult(top_name, None, top_sim)
        near_miss = top_name if (clears_margin and top_sim >= suggest_min) else None
        return MatchResult(None, near_miss, top_sim)

    @staticmethod
    def _aligned(person: dict) -> tuple[list[list[float]], list[dict | None]]:
        """A person's samples and their provenance as two equal-length lists.

        Wrong-dimension samples are dropped *with* their provenance. A missing or
        short `sources` reads the unmatched samples as legacy (`None`), and an entry
        whose fingerprint does not match the sample beside it reads as legacy too,
        never as another sample's meeting."""
        raw = person.get("samples")
        samples = raw if isinstance(raw, list) else []
        recorded = person.get("sources")
        recorded = recorded if isinstance(recorded, list) else []
        # Paired by index with no length check: the per-entry fingerprint below is what
        # decides whether an entry is believed. An older writer that appended below the
        # cap leaves `sources` shorter, and the earlier entries still sit beside their
        # own samples, so they keep their provenance instead of being discarded.
        sources: list = (recorded + [None] * len(samples))[: len(samples)]
        pairs = [
            (smp, origin if isinstance(origin, dict) and origin.get("fp") == _fingerprint(smp) else None)
            for smp, origin in zip(samples, sources)
            if isinstance(smp, list) and len(smp) == EMBEDDING_DIM
        ]
        return [s for s, _ in pairs], [src for _, src in pairs]

    def enroll(
        self,
        name: str,
        embedding: list[float],
        *,
        stem: str | None = None,
        label: str | None = None,
    ) -> None:
        """Add a sample embedding to `name` (creating the person if new) and
        recompute their centroids. A wrong-dimension embedding is ignored.

        `stem` and `label` record which meeting speaker the sample came from
        (FEAT24), so `unenroll` can take back this meeting's sample. A stem alone is
        kept as partial provenance. At the per-person cap the oldest sample drops
        out to make room, and `unenroll` does not bring it back."""
        name = name.strip()
        if not name or len(embedding) != EMBEDDING_DIM:
            return
        sample = _l2_normalize([float(x) for x in embedding])
        people = self._people()
        person = next((p for p in people if p.get("name") == name), None)
        if person is None:
            person = {"name": name, "samples": []}
            people.append(person)
        samples, sources = self._aligned(person)
        samples.append(sample)
        sources.append({"stem": stem, "label": label, "fp": _fingerprint(sample)} if stem else None)
        samples = samples[-_MAX_SAMPLES:]
        sources = sources[-_MAX_SAMPLES:]
        person["samples"] = samples
        person["sources"] = sources
        person["centroids"] = kmeans_centroids(samples)
        self._write(people)

    def unenroll(
        self,
        name: str,
        stem: str,
        label: str,
        embedding: list[float] | None = None,
    ) -> tuple[int, bool]:
        """Take back what one meeting added to `name` (FEAT24): the inverse of
        `enroll`, where `forget` is the whole person.

        Removes every sample of `name` recorded as taken from `(stem, label)`.
        A legacy sample with no provenance, or one recorded for this `stem` under a
        different label (the label moved since, as `mp roster enroll` without
        `--no-relabel` does by re-keying the sidecar to the name), is
        removed only when its vector matches `embedding` (the meeting label's
        vector) at `UNENROLL_MATCH_MIN`; with no `embedding` those are never
        touched, and a sample recorded for another meeting never is. Centroids are recomputed
        from what remains, and the person is removed only when no samples do.

        Returns ``(removed, person_removed)``. A person with no matching sample,
        or an unknown name, writes nothing and the file stays byte-identical:
        "this meeting contributed nothing" is a correct no-op."""
        people = self._people()
        person = next((p for p in people if p.get("name") == name), None)
        if person is None:
            return 0, False
        target = None
        if isinstance(embedding, list) and len(embedding) == EMBEDDING_DIM:
            try:
                target = _l2_normalize([float(x) for x in embedding])
            except (TypeError, ValueError):
                target = None
        samples, sources = self._aligned(person)
        keep_s: list[list[float]] = []
        keep_src: list[dict | None] = []
        for sample, src in zip(samples, sources):
            same_voice = target is not None and cosine_similarity(sample, target) >= UNENROLL_MATCH_MIN
            if src is None:
                hit = same_voice
            elif src.get("stem") == stem:
                hit = src.get("label") == label or same_voice
            else:
                hit = False
            if not hit:
                keep_s.append(sample)
                keep_src.append(src)
        removed = len(samples) - len(keep_s)
        if removed == 0:
            return 0, False
        if not keep_s:
            self._write([p for p in people if p is not person])
            return removed, True
        person["samples"] = keep_s
        person["sources"] = keep_src
        person["centroids"] = kmeans_centroids(keep_s)
        self._write(people)
        return removed, False

    def forget(self, name: str) -> bool:
        """Remove a person from the roster. Returns True if one was removed."""
        people = self._people()
        kept = [p for p in people if p.get("name") != name]
        if len(kept) == len(people):
            return False
        self._write(kept)
        return True

    @staticmethod
    def forget_embeddings(name: str, library_dir: Path) -> int:
        """Strip `name` from every `<stem>.embeddings.json` in `library_dir` and
        return how many files changed (SEC22).

        `roster forget` removes the person from `roster.json` only; their voice
        embedding stayed in each meeting's sidecar, keyed by their name. That is
        the key removed here, plus any `near_misses` entry that is keyed by the
        name or points at it ("closest to <name>"). A file that does not mention
        the name is not rewritten, so it stays byte-identical; each rewrite is
        atomic and 0600. An unreadable file is skipped, never replaced.

        Deliberately separate from `forget` (and opt-in from the CLI): stripping
        the embeddings of every meeting is a whole-person erasure, reachable only
        from the Preferences People pane's Remove. Undo naming and rename take back
        one meeting's sample through `unenroll` instead (FEAT24). No in-app control
        passes the purge yet: Preferences' People Remove runs a plain `forget`."""
        changed = 0
        for path in sorted(Path(library_dir).glob("*.embeddings.json")):
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if not isinstance(data, dict):
                continue
            touched = False
            embeddings = data.get("embeddings")
            if isinstance(embeddings, dict) and name in embeddings:
                del embeddings[name]
                touched = True
            near = data.get("near_misses")
            if isinstance(near, dict):
                drop = [k for k, v in near.items() if k == name or v == name]
                for k in drop:
                    del near[k]
                touched = touched or bool(drop)
                if not near:
                    data.pop("near_misses", None)
            if not touched:
                continue
            storage.atomic_write_text(path, json.dumps(data))
            changed += 1
        return changed

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
        # SEC22: every named third party's voiceprint; 0600 in a 0700 directory.
        storage.ensure_private_dir(self.path.parent)
        payload = {"schema_version": _SCHEMA_VERSION, "people": people}
        storage.atomic_write_text(self.path, json.dumps(payload))
