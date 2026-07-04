"""Persisted self-voiceprint for speaker enrollment (FEAT3-VOICEPRINT).

The daemon writes a 256-d L2-normalized embedding per diarized speaker into the
draft `<stem>.json`. This module persists a single running-average voiceprint of
the user, learned automatically from the mic channel of stereo recordings, and
lets `diarize.match_voiceprint` identify "me" by voice on the mono/merged
recordings where the mic-channel trick can't.

Stdlib-only (json, math, pathlib): the vectors are small (256 floats) and this
runs on every finalize, so it never pulls in numpy.
"""
from __future__ import annotations

import json
import math
from pathlib import Path

# Sibling of config.toml / secrets.env so all per-user state lives in one place.
VOICEPRINT_PATH = Path("~/.config/meeting-pipe/voiceprint.json").expanduser()

_SCHEMA_VERSION = 1
EMBEDDING_DIM = 256


def _l2_normalize(vec: list[float]) -> list[float]:
    norm = math.sqrt(sum(x * x for x in vec))
    if norm < 1e-9:
        return list(vec)
    return [x / norm for x in vec]


class VoiceprintStore:
    """Single running-average self-voiceprint at ~/.config/meeting-pipe/voiceprint.json.

    Shape: ``{"schema_version": 1, "embedding": [256 floats], "meetings": N}``.
    An absent or malformed file means "not enrolled yet" (``load`` returns
    ``(None, 0)``), so every reader degrades to the structural "me" heuristic.
    """

    def __init__(self, path: Path | None = None) -> None:
        self.path = path or VOICEPRINT_PATH

    def load(self) -> tuple[list[float] | None, int]:
        """Return ``(embedding, meetings)``; ``(None, 0)`` when unset/unreadable."""
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None, 0
        emb = data.get("embedding")
        if not isinstance(emb, list) or len(emb) != EMBEDDING_DIM:
            return None, 0
        try:
            emb = [float(x) for x in emb]
        except (TypeError, ValueError):
            return None, 0
        meetings = data.get("meetings", 0)
        meetings = meetings if isinstance(meetings, int) and meetings >= 0 else 0
        return _l2_normalize(emb), meetings

    def embedding(self) -> list[float] | None:
        return self.load()[0]

    def meetings(self) -> int:
        return self.load()[1]

    def update(self, sample: list[float]) -> int:
        """Fold a fresh mic-channel user sample into the running-average
        voiceprint and persist it. Returns the new meeting count. A
        wrong-dimension sample is ignored (count unchanged)."""
        if len(sample) != EMBEDDING_DIM:
            return self.meetings()
        sample = _l2_normalize([float(x) for x in sample])
        current, n = self.load()
        if current is None or n <= 0:
            merged, new_n = sample, 1
        else:
            # Equal-weight running mean: stable once learned, so one noisy
            # meeting can't swamp a voiceprint built from many clean samples.
            merged = _l2_normalize(
                [(c * n + s) / (n + 1) for c, s in zip(current, sample)]
            )
            new_n = n + 1
        self._write(merged, new_n)
        return new_n

    def reset(self) -> None:
        """Forget the learned voiceprint (the Preferences "Reset" action)."""
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass

    def _write(self, embedding: list[float], meetings: int) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "schema_version": _SCHEMA_VERSION,
            "embedding": embedding,
            "meetings": meetings,
        }
        tmp = self.path.with_name(self.path.name + ".tmp")
        tmp.write_text(json.dumps(payload), encoding="utf-8")
        tmp.replace(self.path)
