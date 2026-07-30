"""On-device embedding index over the meeting library (AI3).

Builds a small vector index from the summaries + transcripts already on disk,
reusing `chunked_windows` for windowing. The embedding backend is pluggable:

- `MLXEmbedder` (production path): a multilingual-e5 model on MLX via
  `mlx_embeddings`. Runs fully on-device, en/uk capable, 384-d.
- `HashingEmbedder` (fallback + tests): a numpy-only hashed-token vector. Not
  semantic, but needs no model and runs identically on CI/Linux, so the index
  and the tests stay exercisable without the heavy MLX dep.

`default_embedder()` picks MLX when `mlx_embeddings` is importable, else the
hashing fallback. Search is cosine similarity over L2-normalized rows.

This module is the durable artifact AI3 (engine-backed cited answers) builds on,
consumed by `rag.py` for `mp ask` and `mp digest`.
The heavy MLX import is deferred into the methods that use it, per the pipeline's
lazy-import contract, so importing this module costs only numpy.

**The index lifecycle is incremental and checkpointed (AI11).** The first cut
rebuilt everything whenever any library file changed, held the whole corpus in
memory while it did, and saved only at the very end, so on a 400-meeting library
one new meeting meant a full unbounded rebuild that a kill threw away entirely.
That chain ended in a hard reboot on 2026-07-29. Three properties now hold, and
each one is load-bearing:

1. **Per-stem freshness.** The manifest records a fingerprint *per meeting*, so a
   refresh re-embeds only the stems whose own source files moved, drops the rows
   of stems that are gone, and reuses everything else.
2. **The checkpoint is the index.** Every `CHECKPOINT_EVERY_STEMS` batch saves a
   complete, loadable index covering the stems finished so far. A kill therefore
   leaves the next run a smaller diff rather than a blank slate, and no separate
   resume file can go stale against the vectors.
3. **Bounded memory.** LOCAL16's `MemoryWatchdog` is checked between batches and
   MLX's buffer cache is dropped after each one, so the embed pass aborts with a
   named reason instead of swapping the machine to death.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import logging
import re
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal, Protocol

import numpy as np

from . import egress_guard, events, resource_guard, transcript_corrections
from .chunking import chunked_windows
from .prefetch_model import model_is_cached

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

#: Manifest schema. v1 carried one whole-library fingerprint and nothing else, so
#: it can only be rebuilt from, not refreshed; v2 (AI11) adds the per-stem
#: fingerprint map that makes an incremental refresh and a resume possible.
INDEX_SCHEMA_VERSION = 2

#: How many meetings one embed batch covers before the index is written back to
#: disk. Small enough that a kill (the daemon SIGTERMs `mp ask` at 10 minutes)
#: costs at most a handful of meetings' work, large enough that the rewrite is a
#: rounding error against the embedding itself. The watchdog is checked once per
#: batch too, which is where the sampling throttle earns its keep.
CHECKPOINT_EVERY_STEMS = 8

#: Stage name on the watchdog abort and its event, so a postmortem can tell an
#: `mp ask` index build apart from a local summarize on the same floor.
EMBED_STAGE = "ask index embed"

_TOKEN = re.compile(r"[a-z0-9]+")

EmbedKind = Literal["query", "passage"]


class EmbedderUnavailableError(RuntimeError):
    """The embedding model cannot be loaded on this run, with a user-actionable
    reason. Raised before any weights are touched, so nothing heavy starts."""


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

    def release(self) -> None:
        """Drop whatever weights this backend is holding (AI11).

        Not a close: a later `embed` reloads. It exists because `mp ask` holds
        the retrieval embedder for the index's whole lifetime while the answer
        step spawns a multi-GB model of its own, and by then retrieval is over,
        so the two never need to be resident at once.
        """


def _clear_mlx_cache() -> None:
    """Drop MLX's Metal buffer cache. No-op wherever MLX is absent (CI, the
    hashing path), which is why every caller can call it unconditionally.

    Nothing in this repo used to call it at all, so an embed pass's buffers grew
    for the whole run: one of the three unbounded copies AI11 traced from the
    2026-07-29 incident."""
    try:
        import mlx.core as mx  # pyright: ignore[reportMissingImports]

        mx.clear_cache()
    except (ImportError, AttributeError):  # pragma: no cover - MLX-only path
        pass


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

    def release(self) -> None:
        """Nothing to release: this backend holds no weights."""


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
        self._model: Any = None
        self._tokenizer: Any = None

    def _ensure_loaded(self) -> tuple[Any, Any]:
        """Load on first use and hand the pair back, so callers hold a non-None
        model + tokenizer rather than re-reading the optional attributes."""
        if self._model is None:
            # AI11 / SEC13: an armed guard pins `HF_HUB_OFFLINE`, so an uncached
            # model here died on a raw huggingface traceback surfaced verbatim in
            # the Ask pane. Fail closed with the same shape `summarize_local._spawn`
            # uses for the answer model: what happened, why now, and the one
            # command that fixes it. A refusal, not a fallback: downloading inside
            # a regulated / NDA run is what the guard exists to prevent.
            if egress_guard.is_armed() and not model_is_cached(self.model_id):
                raise EmbedderUnavailableError(
                    f"Embedding model {self.model_id!r} is not in the local HuggingFace "
                    f"cache, and this is a regulated/NDA run, so it cannot be downloaded "
                    f"now. Fetch it outside a zero-egress meeting first:\n"
                    f"    mp prefetch-model {self.model_id}"
                )
            from mlx_embeddings.utils import load  # pyright: ignore[reportMissingImports]

            log.info("loading MLX embedding model %s", self.model_id)
            self._model, self._tokenizer = load(self.model_id)
        return self._model, self._tokenizer

    def embed(self, texts: list[str], kind: EmbedKind = "passage") -> np.ndarray:
        if not texts:
            return np.zeros((0, 0), dtype=np.float32)
        # Load (and so run the AI11 preflight) before importing MLX, so a run
        # that cannot have the model says why in one actionable sentence rather
        # than dying on whichever import happens to fail first.
        model, tokenizer = self._ensure_loaded()

        import mlx.core as mx  # pyright: ignore[reportMissingImports]

        prefix = "query: " if kind == "query" else "passage: "
        prepared = [prefix + t for t in texts]
        rows: list[np.ndarray] = []
        for start in range(0, len(prepared), self.batch_size):
            batch = prepared[start : start + self.batch_size]
            enc = tokenizer.batch_encode_plus(
                batch, return_tensors="mlx", padding=True, truncation=True, max_length=512
            )
            out = model(enc["input_ids"], attention_mask=enc["attention_mask"])
            emb = out.text_embeds
            mx.eval(emb)  # mlx is lazy; force the compute before leaving mlx-land
            rows.append(np.array(emb, dtype=np.float32))
            # AI11: the row is a numpy copy now, so the Metal buffers behind it
            # are dead weight. Without this they accumulate across every batch of
            # the run, which is the growth the free-RAM watchdog would otherwise
            # have to absorb on its own.
            _clear_mlx_cache()
        return _l2_normalize(np.vstack(rows))

    def release(self) -> None:
        """Drop the model + tokenizer and the Metal cache behind them (AI11).
        Idempotent, and not terminal: `_ensure_loaded` reloads on the next call."""
        if self._model is None and self._tokenizer is None:
            return
        log.info("releasing MLX embedding model %s", self.model_id)
        self._model = None
        self._tokenizer = None
        _clear_mlx_cache()


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


def chunk_stem(
    root: Path, stem: str, *, chunk_chars: int = CHUNK_CHARS, overlap: int = CHUNK_OVERLAP
) -> list[Chunk]:
    """One meeting's windows. Empty when it has neither a summary nor a
    transcript, which is a legitimate outcome, not a failure: such a stem is
    still *current* in the manifest, so a refresh does not retry it forever."""
    root = Path(root).expanduser()
    parts: list[str] = []
    summary_md = root / f"{stem}.summary.md"
    if summary_md.exists():
        parts.append(summary_md.read_text(encoding="utf-8", errors="ignore"))
    transcript_md = root / f"{stem}.md"
    if transcript_md.exists():
        # PIPE9 / FEAT3: embed the transcript the Library actually shows,
        # i.e. with the speaker-label and text-correction overlays applied, so
        # `mp ask` cites corrected lines. Raw file when no overlay (the common path).
        overlaid = transcript_corrections.overlaid_markdown(transcript_md)
        parts.append(
            overlaid if overlaid is not None
            else transcript_md.read_text(encoding="utf-8", errors="ignore")
        )
    if not parts:
        return []
    title = _read_title(root, stem)
    text = "\n\n".join(parts)
    return [
        Chunk(stem=stem, title=title, index=window.index, text=window.text)
        for window in chunked_windows(text, max_chars=chunk_chars, overlap_chars=overlap)
    ]


def chunk_library(root: Path, *, chunk_chars: int = CHUNK_CHARS, overlap: int = CHUNK_OVERLAP) -> list[Chunk]:
    """One `Chunk` per window of each meeting's `summary.md` + `md` transcript.
    Meetings with neither are skipped (same corpus `mp ask` searches).

    Whole-library, so it holds the whole corpus as strings; the incremental
    refresh calls `chunk_stem` per batch instead and never materializes more than
    a batch at a time. Kept for a from-scratch `EmbeddingIndex.build`."""
    root = Path(root).expanduser()
    if not root.is_dir():
        return []
    chunks: list[Chunk] = []
    for stem in _library_stems(root):
        chunks.extend(chunk_stem(root, stem, chunk_chars=chunk_chars, overlap=overlap))
    return chunks


class EmbeddingIndex:
    """A flat vector index over the library: L2-normalized rows + the chunks
    they came from. Small enough (low thousands of rows) that exact cosine via a
    single dense dot beats any ANN structure, which is also why AI3 can reuse it
    as-is before scale justifies SQLite/FTS (see TECH-A3)."""

    def __init__(self, embedder: Embedder, chunks: list[Chunk], vectors: np.ndarray, *, model: str, dim: int, fingerprint: str = "", stems: dict[str, str] | None = None) -> None:
        self.embedder = embedder
        self.chunks = chunks
        self.vectors = vectors
        self.model = model
        self.dim = dim
        # Fingerprint of the source library at build time (AI3). Now only a
        # coarse "was this index complete when it was written" stamp: AI11's
        # refresh decides reuse per stem, and a mid-build checkpoint deliberately
        # carries an empty one so nothing can mistake it for a finished index.
        self.fingerprint = fingerprint
        # AI11: stem -> its own source fingerprint, for every meeting this index
        # is current for. The whole point of the refresh: a stem present here with
        # a matching fingerprint keeps its vectors, everything else is re-embedded,
        # and a stem that is gone from disk takes its rows with it.
        self.stems: dict[str, str] = dict(stems or {})

    def release_embedder(self) -> None:
        """Drop the embedding model's weights (AI11). Retrieval is over by the
        time `mp ask` calls this; holding e5 resident while the answer model
        spawns just stacks two models in one process for no benefit."""
        self.embedder.release()

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
        fingerprint = library_fingerprint(root)
        stems = library_stem_fingerprints(root)
        chunks = chunk_library(root, chunk_chars=chunk_chars, overlap=overlap)
        if not chunks:
            return cls(embedder, [], np.zeros((0, 0), dtype=np.float32), model=embedder.name, dim=0, fingerprint=fingerprint, stems=stems)
        vectors = embedder.embed([c.text for c in chunks], kind="passage")
        return cls(embedder, chunks, vectors, model=embedder.name, dim=int(vectors.shape[1]), fingerprint=fingerprint, stems=stems)

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
                {
                    "schema_version": INDEX_SCHEMA_VERSION,
                    "model": self.model,
                    "dim": self.dim,
                    "count": len(self.chunks),
                    "fingerprint": self.fingerprint,
                    "stems": self.stems,
                },
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
        raw_stems = manifest.get("stems")
        stems = (
            {str(k): str(v) for k, v in raw_stems.items()}
            if isinstance(raw_stems, dict) else {}
        )
        return cls(
            embedder,
            chunks,
            vectors,
            model=str(manifest.get("model", "")),
            dim=int(manifest.get("dim", vectors.shape[1] if vectors.ndim == 2 else 0)),
            fingerprint=str(manifest.get("fingerprint", "")),
            stems=stems,
        )


#: The per-meeting source files that feed one stem's chunks and its title. The
#: same set `library_fingerprint` globs, sliced per stem so a change can be
#: attributed to the one meeting it belongs to instead of invalidating all 400.
#: PIPE9 / FEAT3: the two overlay sidecars are in here because a correction or a
#: speaker rename rewrites only the sidecar, and leaving them out would have
#: `mp ask` quoting text the Library no longer shows.
STEM_SOURCE_SUFFIXES = (
    ".md",
    ".summary.md",
    ".summary.json",
    ".transcript_corrections.json",
    ".speaker_labels.json",
)


def _fingerprint_lines(lines: list[str]) -> str:
    h = hashlib.blake2b(digest_size=16)
    for line in sorted(lines):
        h.update(line.encode("utf-8"))
    return h.hexdigest()


def _stat_line(p: Path) -> str | None:
    try:
        st = p.stat()
    except OSError:
        return None
    return f"{p.name}\t{st.st_mtime_ns}\t{st.st_size}"


def stem_fingerprint(root: Path, stem: str) -> str:
    """One meeting's (name, mtime, size) hash over `STEM_SOURCE_SUFFIXES`. Never
    reads file bodies, so fingerprinting a 400-meeting library is a stat storm at
    worst, not a read of the 80 MB of transcripts underneath it."""
    root = Path(root).expanduser()
    lines = [line for line in (_stat_line(root / f"{stem}{sfx}") for sfx in STEM_SOURCE_SUFFIXES) if line]
    return _fingerprint_lines(lines)


def library_stem_fingerprints(root: Path) -> dict[str, str]:
    """Every stem the index covers, mapped to its own fingerprint (AI11). This is
    what the manifest stores and what a refresh diffs against."""
    root = Path(root).expanduser()
    if not root.is_dir():
        return {}
    return {stem: stem_fingerprint(root, stem) for stem in _library_stems(root)}


def library_fingerprint(root: Path) -> str:
    """A cheap, stable hash over the source files that feed the index: each file's
    (name, mtime, size). Adds, removals, and in-place edits all change it. Never
    reads file bodies, so it is fast even on a large library.

    Since AI11 this is a completeness stamp rather than the reuse decision: it is
    written only by a refresh that finished, so an interrupted build's checkpoint
    carries an empty one. Reuse itself is decided per stem."""
    root = Path(root).expanduser()
    if not root.is_dir():
        return "empty"
    lines: list[str] = []
    # PIPE9 / FEAT3: the overlay sidecars feed the chunk text too, so a correction
    # or speaker rename (which rewrites only the sidecar, not `<stem>.md`) must
    # invalidate the cached index, else `mp ask` keeps quoting stale text.
    for pattern in ("*.md", "*.summary.json", "*.transcript_corrections.json", "*.speaker_labels.json"):
        for p in root.glob(pattern):
            line = _stat_line(p)
            if line:
                lines.append(line)
    return _fingerprint_lines(lines)


@dataclass(frozen=True)
class IndexProgress:
    """One beat of an index refresh, handed to `refresh_index`'s `on_progress`.
    The caller decides what to do with it; `mp ask` turns it into the stdout
    heartbeat the daemon reads."""

    stems_done: int
    stems_total: int
    chunks_done: int


@dataclass(frozen=True)
class RefreshPlan:
    """What one refresh owes the index, decided purely from two fingerprint maps
    so the diff is unit-testable without embedding anything."""

    stale: list[str]      # re-chunk and re-embed: new, edited, or never finished
    removed: list[str]    # gone from disk: drop their rows
    unchanged: list[str]  # keep their vectors as they are

    @property
    def is_noop(self) -> bool:
        return not self.stale and not self.removed


def plan_refresh(prior: dict[str, str], current: dict[str, str]) -> RefreshPlan:
    """Diff the manifest's per-stem fingerprints against the library's.

    A stem missing from `prior` is stale, which is what makes a resume work: an
    interrupted build wrote a manifest naming only the stems it finished, so the
    rest come back as stale on the next run and nothing already embedded is
    touched again.
    """
    stale = sorted(stem for stem, fp in current.items() if prior.get(stem) != fp)
    removed = sorted(set(prior) - set(current))
    fresh = set(stale)
    unchanged = sorted(stem for stem in current if stem not in fresh)
    return RefreshPlan(stale=stale, removed=removed, unchanged=unchanged)


def _empty_vectors() -> np.ndarray:
    return np.zeros((0, 0), dtype=np.float32)


def _load_reusable(index_dir: Path, embedder: Embedder) -> "EmbeddingIndex | None":
    """The persisted index, when it is one this run may build on. None (rebuild
    from scratch) for a missing, corrupt, pre-AI11, or differently-embedded cache.

    The vectors / chunks pairing is validated here rather than at the use site, so
    everything downstream can index one by the other without re-checking.
    """
    if not (index_dir / "manifest.json").exists():
        return None
    try:
        meta = json.loads((index_dir / "manifest.json").read_text(encoding="utf-8"))
        if not isinstance(meta, dict):
            return None
        # A hashing-built index under an MLX embedder would have vectors of the
        # wrong dimension, so the model has to match before anything else.
        if meta.get("model") != embedder.name:
            return None
        if int(meta.get("schema_version", 1)) < INDEX_SCHEMA_VERSION:
            log.info("cached index at %s predates per-stem freshness; rebuilding it once", index_dir)
            return None
        index = EmbeddingIndex.load(index_dir, embedder)
    except (OSError, ValueError, KeyError, TypeError) as e:
        log.warning("cached index at %s unreadable (%s); rebuilding", index_dir, e)
        return None
    if index.vectors.ndim != 2 or index.vectors.shape[0] != len(index.chunks):
        log.warning(
            "cached index at %s has %s vectors for %d chunks; rebuilding",
            index_dir, index.vectors.shape, len(index.chunks),
        )
        return None
    return index


def _keep(prior: "EmbeddingIndex | None", keep: set[str]) -> tuple[list[Chunk], np.ndarray]:
    """The prior index's chunks + rows for the stems still current."""
    if prior is None or not keep or not prior.chunks:
        return [], _empty_vectors()
    rows = [i for i, c in enumerate(prior.chunks) if c.stem in keep]
    if not rows:
        return [], _empty_vectors()
    return [prior.chunks[i] for i in rows], prior.vectors[rows]


def _assemble(
    embedder: Embedder,
    chunks: list[Chunk],
    blocks: list[np.ndarray],
    *,
    stems: dict[str, str],
    fingerprint: str,
) -> "EmbeddingIndex":
    """Stack the accumulated vector blocks and pair them with their chunks,
    ordered by (stem, window) so a resumed build lands the same rows in the same
    order a single-pass build would."""
    filled = [b for b in blocks if b.size]
    vectors = np.vstack(filled).astype(np.float32) if filled else _empty_vectors()
    if vectors.shape[0] == len(chunks) and len(chunks) > 1:
        order = sorted(range(len(chunks)), key=lambda i: (chunks[i].stem, chunks[i].index))
        chunks = [chunks[i] for i in order]
        vectors = vectors[order]
    dim = int(vectors.shape[1]) if vectors.ndim == 2 and vectors.shape[0] else 0
    return EmbeddingIndex(
        embedder, list(chunks), vectors,
        model=embedder.name, dim=dim, fingerprint=fingerprint, stems=dict(stems),
    )


def _persist(index: "EmbeddingIndex", index_dir: Path) -> None:
    """Best-effort save. A cache that cannot be written costs speed, never
    correctness, so it warns and the run continues on the in-memory index."""
    try:
        index.save(index_dir)
    except OSError as e:
        log.warning("could not persist index to %s: %s", index_dir, e)


def refresh_index(
    root: Path,
    index_dir: Path,
    embedder: Embedder | None = None,
    *,
    rebuild: bool = False,
    watchdog: resource_guard.MemoryWatchdog | None = None,
    on_progress: Callable[[IndexProgress], None] | None = None,
    chunk_chars: int = CHUNK_CHARS,
    overlap: int = CHUNK_OVERLAP,
) -> "EmbeddingIndex":
    """Bring the persisted index up to date with the library, incrementally.

    Only the stems whose own source files changed are re-chunked and re-embedded;
    removed stems lose their rows; everything else keeps the vectors it already
    had. The index is written back every `CHECKPOINT_EVERY_STEMS` meetings, so a
    kill mid-build resumes from the last checkpoint instead of starting over
    (the daemon SIGTERMs `mp ask` at ten minutes, which on a large library used
    to mean an infinite rebuild loop that never once produced an answer).

    `watchdog` is checked between batches and raises `resource_guard.LowMemoryError`
    rather than letting the machine swap; the work done so far is already on disk
    by then, so the next run picks up where the abort left it.
    """
    root = Path(root).expanduser()
    index_dir = Path(index_dir).expanduser()
    embedder = embedder or default_embedder()

    prior = None if rebuild else _load_reusable(index_dir, embedder)
    current = library_stem_fingerprints(root)
    plan = plan_refresh(prior.stems if prior is not None else {}, current)

    if prior is not None and plan.is_noop:
        log.info(
            "reusing embedding index at %s (%d chunks over %d meetings)",
            index_dir, len(prior.chunks), len(current),
        )
        return prior

    started = time.monotonic()
    events.emit(
        "pipeline", "ask_index_refresh_started",
        stems_total=len(current), stems_stale=len(plan.stale),
        stems_removed=len(plan.removed), stems_reused=len(plan.unchanged),
        rebuild=rebuild,
    )
    log.info(
        "embedding index: %d meetings, %d to embed, %d removed, %d reused",
        len(current), len(plan.stale), len(plan.removed), len(plan.unchanged),
    )

    chunks, kept_vectors = _keep(prior, set(plan.unchanged))
    blocks: list[np.ndarray] = [kept_vectors]
    done: dict[str, str] = {stem: current[stem] for stem in plan.unchanged}
    embedded_chunks = 0

    for start in range(0, len(plan.stale), CHECKPOINT_EVERY_STEMS):
        batch = plan.stale[start : start + CHECKPOINT_EVERY_STEMS]
        # LOCAL16's watchdog, sampling-throttled, so calling it per batch costs
        # nothing. It raises; the checkpoint below is what makes that survivable.
        if watchdog is not None:
            watchdog.check(stage=EMBED_STAGE)
        batch_chunks: list[Chunk] = []
        for stem in batch:
            batch_chunks.extend(chunk_stem(root, stem, chunk_chars=chunk_chars, overlap=overlap))
        if batch_chunks:
            # Embed first, so a backend that raises leaves the accumulated state
            # untouched rather than one list ahead of the other.
            blocks.append(embedder.embed([c.text for c in batch_chunks], kind="passage"))
            chunks.extend(batch_chunks)
            embedded_chunks += len(batch_chunks)
        for stem in batch:
            done[stem] = current[stem]
        # The checkpoint IS the index: a complete, loadable one covering the stems
        # finished so far, with an empty completeness stamp so nothing mistakes it
        # for a finished refresh. Collapsing the blocks here also keeps the stack
        # from re-walking every earlier batch on the next checkpoint.
        checkpoint = _assemble(embedder, chunks, blocks, stems=done, fingerprint="")
        _persist(checkpoint, index_dir)
        chunks, blocks = checkpoint.chunks, [checkpoint.vectors]
        if on_progress is not None:
            on_progress(IndexProgress(
                stems_done=len(done), stems_total=len(current), chunks_done=len(chunks),
            ))

    index = _assemble(embedder, chunks, blocks, stems=done, fingerprint=library_fingerprint(root))
    _persist(index, index_dir)
    events.emit(
        "pipeline", "ask_index_refresh_done",
        stems_embedded=len(plan.stale), stems_total=len(current),
        chunks_embedded=embedded_chunks, chunks_total=len(index.chunks),
        duration_s=round(time.monotonic() - started, 2),
    )
    return index


def load_or_build(
    root: Path,
    index_dir: Path,
    embedder: Embedder | None = None,
    *,
    rebuild: bool = False,
    watchdog: resource_guard.MemoryWatchdog | None = None,
    on_progress: Callable[[IndexProgress], None] | None = None,
) -> "EmbeddingIndex":
    """Load a persisted index, refreshing whatever part of it went stale.

    The name every caller already uses; `refresh_index` is where the work lives.
    Reuse requires the embedder model to match the manifest (a hashing-built
    index under an MLX embedder would have the wrong dimension), and then holds
    per meeting rather than for the library as a whole.
    """
    return refresh_index(
        root, index_dir, embedder,
        rebuild=rebuild, watchdog=watchdog, on_progress=on_progress,
    )
