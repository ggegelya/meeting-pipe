"""On-device embedding index over the meeting library (AI2 spike; AI3 base).

Builds a small vector index from the summaries + transcripts already on disk,
reusing `chunked_windows` for windowing. The embedding backend is pluggable:

- `MLXEmbedder` (production path): a multilingual-e5 model on MLX via
  `mlx_embeddings`. Runs fully on-device, en/uk capable, 384-d.
- `HashingEmbedder` (fallback + tests): a numpy-only hashed-token vector. Not
  semantic, but needs no model and runs identically on CI/Linux, so the index,
  the AI2 harness, and the tests stay exercisable without the heavy MLX dep.

`default_embedder()` picks MLX when `mlx_embeddings` is importable, else the
hashing fallback. Search is cosine similarity over L2-normalized rows.

This module is the durable artifact AI3 (engine-backed cited answers) builds on;
the AI2 measurement harness in `ai2_spike.py` is the throwaway that consumes it.
The heavy MLX import is deferred into the methods that use it, per the pipeline's
lazy-import contract, so importing this module costs only numpy.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import logging
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, Protocol

import numpy as np

from .chunking import chunked_windows

log = logging.getLogger("mp.embed_index")

# multilingual-e5-small: XLM-RoBERTa based, 384-d, strong en/uk, ~120 MB.
DEFAULT_EMBED_MODEL = "mlx-community/multilingual-e5-small-mlx"

# Derived, disposable; outside the Library-scanned ~/Documents/Meetings/raw.
DEFAULT_INDEX_DIR = Path("~/Library/Caches/meeting-pipe/ai2-index").expanduser()

# Index windowing. ~1200 chars (~300 tokens) balances retrieval granularity
# against embedding throughput; the 200-char overlap matches the
# `chunked_windows` default so a fact at a window seam survives in a neighbour.
CHUNK_CHARS = 1200
CHUNK_OVERLAP = 200

_TOKEN = re.compile(r"[a-z0-9]+")

EmbedKind = Literal["query", "passage"]


@dataclass
class Chunk:
    """One indexed window of a meeting's summary + transcript text."""

    stem: str
    title: str
    index: int
    text: str

    def to_json(self) -> dict:
        return {"stem": self.stem, "title": self.title, "index": self.index, "text": self.text}

    @classmethod
    def from_json(cls, obj: dict) -> "Chunk":
        return cls(
            stem=str(obj["stem"]),
            title=str(obj.get("title", obj["stem"])),
            index=int(obj.get("index", 0)),
            text=str(obj["text"]),
        )


@dataclass
class SearchHit:
    chunk: Chunk
    score: float


class Embedder(Protocol):
    """Narrow contract every backend satisfies. `name` rides into the index
    manifest so a reload can tell which model produced the vectors."""

    name: str

    def embed(self, texts: list[str], kind: EmbedKind = "passage") -> np.ndarray: ...


def _l2_normalize(mat: np.ndarray) -> np.ndarray:
    norms = np.linalg.norm(mat, axis=1, keepdims=True)
    norms[norms == 0.0] = 1.0
    return (mat / norms).astype(np.float32)


class HashingEmbedder:
    """Deterministic, dependency-free embedder: hashes token unigrams and
    bigrams into a fixed-width vector (the hashing trick), L2-normalized.

    Similarity is lexical overlap (a dense cousin of TF), not semantic, but it
    needs no model and is byte-identical across runs and machines, which is what
    keeps the harness and tests green on CI where MLX is absent. `kind` is
    ignored: queries and passages share one space. The production backend is
    `MLXEmbedder`; this is the floor, not the goal.
    """

    def __init__(self, dim: int = 512) -> None:
        self.dim = dim
        self.name = f"hashing-{dim}"

    def _tokens(self, text: str) -> list[str]:
        toks = _TOKEN.findall(text.lower())
        bigrams = [f"{a}_{b}" for a, b in zip(toks, toks[1:])]
        return toks + bigrams

    def _bucket(self, token: str) -> int:
        # blake2b, not the salted built-in hash(), so buckets are stable across
        # processes (a saved index must reload to the same vectors).
        digest = hashlib.blake2b(token.encode("utf-8"), digest_size=8).digest()
        return int.from_bytes(digest, "little") % self.dim

    def embed(self, texts: list[str], kind: EmbedKind = "passage") -> np.ndarray:
        mat = np.zeros((len(texts), self.dim), dtype=np.float32)
        for i, text in enumerate(texts):
            for tok in self._tokens(text):
                mat[i, self._bucket(tok)] += 1.0
        return _l2_normalize(mat)


class MLXEmbedder:
    """A sentence-embedding model on MLX via `mlx_embeddings` (default
    multilingual-e5-small). Mean-pooled, L2-normalized vectors, fully on-device.

    E5 models expect an asymmetric `query:` / `passage:` prefix, so indexing and
    retrieval are deliberately not symmetric. The model + tokenizer load lazily
    on first `embed`.
    """

    def __init__(self, model_id: str = DEFAULT_EMBED_MODEL, *, batch_size: int = 32) -> None:
        self.name = model_id
        self.model_id = model_id
        self.batch_size = batch_size
        self._model = None
        self._tokenizer = None

    def _ensure_loaded(self) -> None:
        if self._model is not None:
            return
        from mlx_embeddings.utils import load  # heavy; darwin/arm64 only

        log.info("loading MLX embedding model %s", self.model_id)
        self._model, self._tokenizer = load(self.model_id)

    def embed(self, texts: list[str], kind: EmbedKind = "passage") -> np.ndarray:
        import mlx.core as mx

        self._ensure_loaded()
        if not texts:
            return np.zeros((0, 0), dtype=np.float32)
        prefix = "query: " if kind == "query" else "passage: "
        prepared = [prefix + t for t in texts]
        rows: list[np.ndarray] = []
        for start in range(0, len(prepared), self.batch_size):
            batch = prepared[start : start + self.batch_size]
            enc = self._tokenizer.batch_encode_plus(
                batch, return_tensors="mlx", padding=True, truncation=True, max_length=512
            )
            out = self._model(enc["input_ids"], attention_mask=enc["attention_mask"])
            emb = out.text_embeds
            mx.eval(emb)  # mlx is lazy; force the compute before leaving mlx-land
            rows.append(np.array(emb, dtype=np.float32))
        return _l2_normalize(np.vstack(rows))


def default_embedder(model_id: str = DEFAULT_EMBED_MODEL) -> Embedder:
    """`MLXEmbedder` when `mlx_embeddings` is importable, else `HashingEmbedder`.
    Logged so a run makes plain which backend (and thus index quality) it used."""
    if importlib.util.find_spec("mlx_embeddings") is not None:
        log.info("embedder: MLX (%s)", model_id)
        return MLXEmbedder(model_id)
    log.warning(
        "mlx_embeddings not installed; using HashingEmbedder (lexical, not semantic). "
        "Install mlx-embeddings for a real on-device semantic index."
    )
    return HashingEmbedder()


def _library_stems(root: Path) -> list[str]:
    """Every meeting stem under `root` that has summary or transcript text.
    Mirrors `ask.discover`'s one-dot transcript rule so the two stay aligned."""
    stems: set[str] = set()
    for p in root.glob("*.md"):
        if p.name.count(".") == 1:  # `<stem>.md` is the transcript; `.summary.md` has more dots
            stems.add(p.name.split(".", 1)[0])
    for p in root.glob("*.summary.json"):
        stems.add(p.name.split(".", 1)[0])
    return sorted(stems)


def _read_title(root: Path, stem: str) -> str:
    summary_json = root / f"{stem}.summary.json"
    if summary_json.exists():
        try:
            obj = json.loads(summary_json.read_text(encoding="utf-8"))
            if isinstance(obj, dict) and obj.get("title"):
                return str(obj["title"])
        except (OSError, ValueError):
            pass
    return stem


def chunk_library(root: Path, *, chunk_chars: int = CHUNK_CHARS, overlap: int = CHUNK_OVERLAP) -> list[Chunk]:
    """One `Chunk` per window of each meeting's `summary.md` + `md` transcript.
    Meetings with neither are skipped (same corpus `mp ask` searches)."""
    root = Path(root).expanduser()
    if not root.is_dir():
        return []
    chunks: list[Chunk] = []
    for stem in _library_stems(root):
        parts: list[str] = []
        for name in (f"{stem}.summary.md", f"{stem}.md"):
            f = root / name
            if f.exists():
                parts.append(f.read_text(encoding="utf-8", errors="ignore"))
        if not parts:
            continue
        title = _read_title(root, stem)
        text = "\n\n".join(parts)
        for window in chunked_windows(text, max_chars=chunk_chars, overlap_chars=overlap):
            chunks.append(Chunk(stem=stem, title=title, index=window.index, text=window.text))
    return chunks


class EmbeddingIndex:
    """A flat vector index over the library: L2-normalized rows + the chunks
    they came from. Small enough (low thousands of rows) that exact cosine via a
    single dense dot beats any ANN structure, which is also why AI3 can reuse it
    as-is before scale justifies SQLite/FTS (see TECH-A3)."""

    def __init__(self, embedder: Embedder, chunks: list[Chunk], vectors: np.ndarray, *, model: str, dim: int) -> None:
        self.embedder = embedder
        self.chunks = chunks
        self.vectors = vectors
        self.model = model
        self.dim = dim

    @classmethod
    def build(
        cls,
        root: Path,
        embedder: Embedder | None = None,
        *,
        chunk_chars: int = CHUNK_CHARS,
        overlap: int = CHUNK_OVERLAP,
    ) -> "EmbeddingIndex":
        embedder = embedder or default_embedder()
        chunks = chunk_library(root, chunk_chars=chunk_chars, overlap=overlap)
        if not chunks:
            return cls(embedder, [], np.zeros((0, 0), dtype=np.float32), model=embedder.name, dim=0)
        vectors = embedder.embed([c.text for c in chunks], kind="passage")
        return cls(embedder, chunks, vectors, model=embedder.name, dim=int(vectors.shape[1]))

    def search(self, query: str, k: int = 8) -> list[SearchHit]:
        if not self.chunks:
            return []
        qv = self.embedder.embed([query], kind="query")[0]
        if qv.shape[0] != self.vectors.shape[1]:
            raise ValueError(
                f"query embedding dim {qv.shape[0]} != index dim {self.vectors.shape[1]}; "
                "the index was built with a different embedder than the one loaded"
            )
        scores = self.vectors @ qv
        order = np.argsort(-scores)[: max(0, k)]
        return [SearchHit(self.chunks[i], float(scores[i])) for i in order]

    def save(self, directory: Path) -> None:
        directory = Path(directory).expanduser()
        directory.mkdir(parents=True, exist_ok=True)
        np.save(directory / "vectors.npy", self.vectors)
        with (directory / "chunks.jsonl").open("w", encoding="utf-8") as f:
            for c in self.chunks:
                f.write(json.dumps(c.to_json(), ensure_ascii=False) + "\n")
        (directory / "manifest.json").write_text(
            json.dumps(
                {"schema_version": 1, "model": self.model, "dim": self.dim, "count": len(self.chunks)},
                indent=2,
            ),
            encoding="utf-8",
        )

    @classmethod
    def load(cls, directory: Path, embedder: Embedder | None = None) -> "EmbeddingIndex":
        directory = Path(directory).expanduser()
        manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
        vectors = np.load(directory / "vectors.npy")
        chunks: list[Chunk] = []
        with (directory / "chunks.jsonl").open(encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    chunks.append(Chunk.from_json(json.loads(line)))
        embedder = embedder or default_embedder(str(manifest.get("model", DEFAULT_EMBED_MODEL)))
        return cls(
            embedder,
            chunks,
            vectors,
            model=str(manifest.get("model", "")),
            dim=int(manifest.get("dim", vectors.shape[1] if vectors.ndim == 2 else 0)),
        )
