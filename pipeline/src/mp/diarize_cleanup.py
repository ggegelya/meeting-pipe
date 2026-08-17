"""LLM-based diarization cleanup pass (TECH-DIAR1).

After FluidAudio (and the channel-aware fallback) assign speaker labels,
this pass asks an LLM to merge labels that clearly belong to one person
and to reattribute the obvious mistakes (a segment assigned to the wrong
speaker). It consumes the shared chunking primitive so a long transcript
is processed in context-fitting windows.

The pass is backend-aware: it honours the workflow's configured backend
and forces the on-device path under `regulated_mode` (and for the
Apple Intelligence summary backend, whose cleanup also stays local), so a
confidential transcript never leaves the machine for this step either.

Output is conservative by construction: a proposed edit is only applied
when its target label already exists in the transcript and actually
differs from the current label. The model can never invent a speaker.

Two DIAR5 additions sit on top of that. Every applied and refused edit is
written per segment to `<stem>.diarize_cleanup.json`, so a later
correction can be traced to a cleanup edit instead of inferred; and a
relabel that would empty its source label is refused unless the two
labels' voiceprints agree (`_refuse_unsupported_merges`).
"""
from __future__ import annotations

import json
import logging
import os
import sys
import time
from collections import Counter
from dataclasses import dataclass
from importlib import resources
from pathlib import Path
from typing import Any, Protocol, runtime_checkable

import anthropic

from . import entry, events, storage
from .chunking import chunked_windows
from .config import Config, effective_backend, parse_local_endpoint, require_env
from .diarize import cosine_similarity
from .markdown import render_markdown
from .prompt_safety import UNTRUSTED_GUIDANCE, wrap_untrusted

log = logging.getLogger("mp.diarize_cleanup")

DEFAULT_WINDOW_CHARS = 8000
DEFAULT_OVERLAP_CHARS = 200
_UNKNOWN_SPEAKER = "Speaker?"
_VALID_KINDS = ("merge", "reattribute")

AUDIT_SCHEMA_VERSION = 1

# A relabel that empties its source label merges two diarization clusters,
# whatever the model called it, so refuse one whose two voiceprints do not agree
# at the bar the roster already uses for "this embedding is that person"
# (`roster.MATCH_MIN`). Duplicated rather than imported because the comparisons
# differ (two per-meeting cluster centroids here, a centroid against a person's
# enrolled samples there) and should stay free to move apart.
#
# Measured over the owner's 36 cleaned meetings (DIAR5): the pass eliminated a
# label 8 times, and the most acoustically favourable destination for each of
# those 8 scored 0.089 to 0.554, so every one is refused here. The cost side is
# the same corpus read the other way: across 77 pairs the owner's corrections
# prove are different people, the highest similarity is 0.644, and it sits under
# this bar too.
MERGE_MIN_SIMILARITY = 0.65

_REFUSED_VOICEPRINT = "voiceprint_distance"


@dataclass(frozen=True)
class SpeakerEdit:
    """One proposed speaker-label correction for a numbered segment."""

    segment_index: int
    speaker: str
    kind: str  # "merge" | "reattribute"


@dataclass(frozen=True)
class EditRecord:
    """What one edit did to one segment, for the audit sidecar.

    `kind` is the model's own word for the edit and nothing validates it, so
    it is recorded but never acted on; `_refuse_unsupported_merges` decides
    what a merge is from the labels instead. `similarity` is the cosine
    between the two labels' voiceprints, or None when either has no embedding.
    `reason` is set only on a refusal.
    """

    segment_index: int
    from_speaker: str
    to_speaker: str
    kind: str
    similarity: float | None = None
    reason: str | None = None

    def as_json(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "segment_index": self.segment_index,
            "from": self.from_speaker,
            "to": self.to_speaker,
            "kind": self.kind,
        }
        if self.similarity is not None:
            out["similarity"] = round(self.similarity, 4)
        if self.reason is not None:
            out["reason"] = self.reason
        return out


# Tool / JSON schema the model fills in. Mirrors `SUMMARY_TOOL` in
# schemas.py: the Anthropic path forces this via tool_choice, the local
# path appends it to the prompt and extracts the JSON object.
CLEANUP_TOOL: dict[str, Any] = {
    "name": "emit_speaker_edits",
    "description": (
        "Emit speaker-label corrections for the numbered transcript segments. "
        "Include ONLY segments whose label should change. Call exactly once."
    ),
    "input_schema": {
        "type": "object",
        "properties": {
            "edits": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "segment_index": {
                            "type": "integer",
                            "description": "The [n] index of the segment to relabel.",
                        },
                        "speaker": {
                            "type": "string",
                            "description": (
                                "The corrected label. MUST already appear in the "
                                "transcript; never invent a new speaker."
                            ),
                        },
                        "kind": {"type": "string", "enum": list(_VALID_KINDS)},
                    },
                    "required": ["segment_index", "speaker", "kind"],
                    "additionalProperties": False,
                },
            },
        },
        "required": ["edits"],
        "additionalProperties": False,
    },
}


@runtime_checkable
class CleanupClient(Protocol):
    """Proposes speaker edits for one rendered transcript window."""

    def propose_edits(self, *, window_prompt: str, speakers: list[str]) -> list[SpeakerEdit]: ...


# ----- Public entry point -----


def cleanup_transcript(
    transcript_json: Path,
    cfg: Config | None = None,
    *,
    client: CleanupClient | None = None,
    window_chars: int = DEFAULT_WINDOW_CHARS,
    overlap_chars: int = DEFAULT_OVERLAP_CHARS,
) -> dict[str, Any]:
    """Run the cleanup pass over a finalized `<stem>.json` transcript.

    Rewrites `<stem>.json` (with `diarize_cleaned: true`), re-renders
    `<stem>.md`, and writes the per-segment audit record to
    `<stem>.diarize_cleanup.json`. A single-speaker transcript is a no-op
    (no LLM call) but still leaves the audit record, so its presence means
    "the pass ran" and its absence means "it never did". Emits a
    `pipeline`/`diarize_cleanup` event with the counts and the wall-clock
    latency.
    """
    cfg = entry.prepare(cfg, transcript_json)  # SEC13: overlay, arm, secrets

    structured = json.loads(transcript_json.read_text(encoding="utf-8"))
    segments: list[dict[str, Any]] = structured.get("segments") or []
    speakers = _distinct_speakers(segments)

    started = time.monotonic()
    applied: list[EditRecord] = []
    refused: list[EditRecord] = []
    if segments and len(speakers) >= 2:
        owns_client = client is None
        if client is None:
            client = _select_cleanup_backend(cfg)
        try:
            edits_by_index = _gather_edits(
                segments, speakers, client, window_chars, overlap_chars
            )
        finally:
            if owns_client:
                close = getattr(client, "close", None)
                if callable(close):
                    close()
        proposed = _effective_edits(segments, edits_by_index, speakers)
        embeddings = _load_embeddings(transcript_json)
        applied, refused = _refuse_unsupported_merges(segments, proposed, embeddings)
        _apply_edits(segments, applied)
    else:
        log.info("diarize cleanup: %d distinct speaker(s); nothing to clean", len(speakers))

    merges = sum(1 for e in applied if e.kind == "merge")
    reattributions = sum(1 for e in applied if e.kind == "reattribute")
    speakers_after = _distinct_speakers(segments)
    eliminated = [s for s in speakers if s not in set(speakers_after)]
    latency_ms = int((time.monotonic() - started) * 1000)

    structured["segments"] = segments
    structured["diarize_cleaned"] = True
    storage.atomic_write_text(
        transcript_json, json.dumps(structured, ensure_ascii=False, indent=2)
    )
    md_path = transcript_json.with_suffix(".md")
    storage.atomic_write_text(md_path, render_markdown(structured))
    audit_path = _write_audit(
        transcript_json,
        segments=len(segments),
        speakers_before=speakers,
        speakers_after=speakers_after,
        eliminated=eliminated,
        applied=applied,
        refused=refused,
        latency_ms=latency_ms,
    )

    log.info(
        "diarize cleanup: %d merges, %d reattributions, %d refused in %d ms",
        merges, reattributions, len(refused), latency_ms,
    )
    events.emit(
        "pipeline", "diarize_cleanup",
        merges_count=merges,
        reattributions_count=reattributions,
        refusals_count=len(refused),
        eliminated_count=len(eliminated),
        latency_ms=latency_ms,
        segments=len(segments),
        speakers=len(speakers),
    )
    return {
        "json": transcript_json,
        "md": md_path,
        "audit": audit_path,
        "merges_count": merges,
        "reattributions_count": reattributions,
        "refusals_count": len(refused),
        "latency_ms": latency_ms,
    }


# ----- Core logic -----


def _distinct_speakers(segments: list[dict[str, Any]]) -> list[str]:
    """Real speaker labels in first-seen order. Drops empty / `Speaker?`."""
    seen: list[str] = []
    for seg in segments:
        spk = seg.get("speaker")
        if spk and spk != _UNKNOWN_SPEAKER and spk not in seen:
            seen.append(spk)
    return seen


def _render_indexed(segments: list[dict[str, Any]]) -> str:
    lines: list[str] = []
    for i, seg in enumerate(segments):
        speaker = seg.get("speaker") or _UNKNOWN_SPEAKER
        text = (seg.get("text") or "").strip()
        lines.append(f"[{i}] {speaker}: {text}")
    return "\n".join(lines)


def _gather_edits(
    segments: list[dict[str, Any]],
    speakers: list[str],
    client: CleanupClient,
    window_chars: int,
    overlap_chars: int,
) -> dict[int, SpeakerEdit]:
    rendered = _render_indexed(segments)
    by_index: dict[int, SpeakerEdit] = {}
    for window in chunked_windows(rendered, max_chars=window_chars, overlap_chars=overlap_chars):
        # Fence each window as untrusted content (TECH-SEC6); the segment numbers
        # stay intact inside the markers so edits still reference them.
        for edit in client.propose_edits(window_prompt=wrap_untrusted(window.prompt), speakers=speakers):
            by_index[edit.segment_index] = edit  # overlapping windows: last wins
    return by_index


def _effective_edits(
    segments: list[dict[str, Any]],
    by_index: dict[int, SpeakerEdit],
    speakers: list[str],
) -> list[EditRecord]:
    """The proposed edits that would actually change a label, in segment order.

    One filter for both the guard and the apply, so the two cannot drift apart
    about which edits count. Drops an out-of-range index, an invented speaker
    (the label must already be in the transcript), and a no-op.
    """
    valid = set(speakers)
    out: list[EditRecord] = []
    for idx in sorted(by_index):
        edit = by_index[idx]
        if not (0 <= idx < len(segments)):
            continue
        if edit.speaker not in valid:
            continue  # never honour an invented speaker
        current = segments[idx].get("speaker") or _UNKNOWN_SPEAKER
        if current == edit.speaker:
            continue  # no-op
        out.append(EditRecord(idx, current, edit.speaker, edit.kind))
    return out


def _refuse_unsupported_merges(
    segments: list[dict[str, Any]],
    proposed: list[EditRecord],
    embeddings: dict[str, list[float]],
) -> tuple[list[EditRecord], list[EditRecord]]:
    """Split `proposed` into (allowed, refused) on voiceprint evidence (DIAR5).

    An edit that moves the LAST segments off its source label merges two
    diarization clusters, and that is the expensive failure: it puts one
    person's words under another person's name, where a label the pass leaves
    alone is at worst an unnamed cluster the owner can name. So a
    label-emptying edit is refused unless the two labels' voiceprints clear
    `MERGE_MIN_SIMILARITY`.

    Deliberately keyed off which labels the edits empty rather than off
    `SpeakerEdit.kind`: the model picks that word itself and nothing checks
    it, and both kinds perform the same mutation, so a safety property hung
    on it is one the model can opt out of. A per-segment reattribution that
    leaves its source label alive is untouched, because there the two labels
    are two different people by construction and their distance says nothing.

    Fail-open with no evidence: a label with no embedding (`speaker_unknown`,
    a channel-fallback id, a missing sidecar) is allowed through, and the
    audit record shows the absent similarity so "allowed because close" reads
    differently from "allowed because unmeasurable".

    One pass, not a fixpoint: refusing some of a label's edits can leave it
    alive, and its other edits are still evaluated as the merge they were
    proposed as.
    """
    counts = Counter(
        seg.get("speaker") or _UNKNOWN_SPEAKER for seg in segments
    )
    leaving = Counter(e.from_speaker for e in proposed)
    emptied = {label for label, n in leaving.items() if counts.get(label, 0) <= n}

    allowed: list[EditRecord] = []
    refused: list[EditRecord] = []
    for edit in proposed:
        source = embeddings.get(edit.from_speaker)
        target = embeddings.get(edit.to_speaker)
        similarity = cosine_similarity(source, target) if source and target else None
        scored = EditRecord(
            edit.segment_index, edit.from_speaker, edit.to_speaker, edit.kind,
            similarity=similarity,
        )
        if (
            edit.from_speaker in emptied
            and similarity is not None
            and similarity < MERGE_MIN_SIMILARITY
        ):
            refused.append(
                EditRecord(
                    scored.segment_index, scored.from_speaker, scored.to_speaker,
                    scored.kind, similarity=similarity, reason=_REFUSED_VOICEPRINT,
                )
            )
            continue
        allowed.append(scored)
    if refused:
        log.info(
            "diarize cleanup: refused %d edit(s) merging labels whose voiceprints "
            "disagree (below %.2f)", len(refused), MERGE_MIN_SIMILARITY,
        )
    return allowed, refused


def _apply_edits(segments: list[dict[str, Any]], applied: list[EditRecord]) -> None:
    """Write the allowed edits into `segments`, in place."""
    for edit in applied:
        segments[edit.segment_index]["speaker"] = edit.to_speaker


def _load_embeddings(transcript_json: Path) -> dict[str, list[float]]:
    """Per-label voiceprints from `<stem>.embeddings.json`, keyed by the same
    labels the transcript carries at this point (the finalizer wrote both).
    Fail-open: a missing or malformed sidecar means no evidence, not an error."""
    path = transcript_json.with_name(f"{transcript_json.stem}.embeddings.json")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    embeddings = data.get("embeddings")
    if not isinstance(embeddings, dict):
        return {}
    return {
        label: vec
        for label, vec in embeddings.items()
        if isinstance(label, str) and isinstance(vec, list) and vec
    }


def _write_audit(
    transcript_json: Path,
    *,
    segments: int,
    speakers_before: list[str],
    speakers_after: list[str],
    eliminated: list[str],
    applied: list[EditRecord],
    refused: list[EditRecord],
    latency_ms: int,
) -> Path:
    """Record what the pass changed, per segment, to `<stem>.diarize_cleanup.json`.

    The counts alone could not answer whether an owner correction undid a
    cleanup edit or a clustering mistake, which is what made the 2026-08-04
    regression an inference rather than evidence (DIAR5). Keyed by segment
    array index, the same join key the two overlay sidecars use.

    Rewritten in full by each run, so it describes the last run only: after a
    second `mp cleanup-diarization` the `from` labels are the first run's
    `to` labels, and reverting it recovers that intermediate state, not the
    finalizer's.
    """
    path = transcript_json.with_name(f"{transcript_json.stem}.diarize_cleanup.json")
    payload = {
        "schema_version": AUDIT_SCHEMA_VERSION,
        "segments": segments,
        "labels_before": speakers_before,
        "labels_after": speakers_after,
        "labels_eliminated": eliminated,
        "merges_count": sum(1 for e in applied if e.kind == "merge"),
        "reattributions_count": sum(1 for e in applied if e.kind == "reattribute"),
        "refusals_count": len(refused),
        "latency_ms": latency_ms,
        "edits": [e.as_json() for e in applied],
        "refused": [e.as_json() for e in refused],
    }
    storage.atomic_write_text(path, json.dumps(payload, ensure_ascii=False, indent=2))
    return path


def _parse_edits(obj: Any) -> list[SpeakerEdit]:
    """Coerce a `{"edits": [...]}` object into a list of SpeakerEdit,
    dropping malformed entries rather than raising."""
    if not isinstance(obj, dict):
        return []
    out: list[SpeakerEdit] = []
    for raw in obj.get("edits") or []:
        if not isinstance(raw, dict):
            continue
        idx = raw.get("segment_index")
        speaker = raw.get("speaker")
        if not isinstance(idx, int) or not isinstance(speaker, str) or not speaker:
            continue
        kind = raw.get("kind")
        if kind not in _VALID_KINDS:
            kind = "reattribute"
        out.append(SpeakerEdit(segment_index=idx, speaker=speaker, kind=kind))
    return out


def _parse_edits_from_text(text: str) -> list[SpeakerEdit]:
    """Extract the JSON object from a free-form local-model reply and
    parse it. Reuses the summarizer's balanced-object scan."""
    from .summarize_local import _largest_balanced_json_object

    for candidate in (text.strip(), _largest_balanced_json_object(text)):
        if not candidate:
            continue
        try:
            return _parse_edits(json.loads(candidate))
        except json.JSONDecodeError:
            continue
    return []


# ----- Prompt + schema framing -----


def _load_cleanup_prompt() -> str:
    return resources.files("mp.prompts").joinpath("diarize_cleanup.md").read_text(encoding="utf-8")


def _cleanup_system_prompt(speakers: list[str]) -> str:
    roster = ", ".join(f"`{s}`" for s in speakers)
    return (
        _load_cleanup_prompt()
        + f"\n\nThe speaker labels currently present in this transcript are: {roster}.\n"
        + "\n" + UNTRUSTED_GUIDANCE  # TECH-SEC6: segments are untrusted content
    )


def _schema_directive() -> str:
    schema = json.dumps(CLEANUP_TOOL["input_schema"], indent=2)
    return (
        "\n\nReply with ONLY a single JSON object that validates against this JSON "
        "Schema. No prose, no Markdown fences, no commentary.\n\n"
        f"```json-schema\n{schema}\n```"
    )


def _local_response_format() -> dict[str, Any]:
    return {
        "type": "json_schema",
        "json_schema": {
            "name": "speaker_edits",
            "schema": CLEANUP_TOOL["input_schema"],
            "strict": True,
        },
    }


# ----- Concrete backends -----


class AnthropicCleanupClient:
    """`CleanupClient` backed by Anthropic tool-use (schema forced)."""

    def __init__(self, *, api_key: str, model: str, max_tokens: int) -> None:
        self._client = anthropic.Anthropic(api_key=api_key)
        self._model = model
        self._max_tokens = max_tokens

    def propose_edits(self, *, window_prompt: str, speakers: list[str]) -> list[SpeakerEdit]:
        from .summarize import _create_message

        response = _create_message(
            self._client,
            model=self._model,
            max_tokens=self._max_tokens,
            system=[
                {
                    "type": "text",
                    "text": _cleanup_system_prompt(speakers),
                    "cache_control": {"type": "ephemeral"},
                },
            ],
            tools=[CLEANUP_TOOL],
            tool_choice={"type": "tool", "name": "emit_speaker_edits"},
            messages=[
                {
                    "role": "user",
                    "content": (
                        "Correct the speaker labels for these numbered segments. "
                        "Call `emit_speaker_edits` exactly once.\n\n" + window_prompt
                    ),
                }
            ],
        )
        blocks = [b for b in response.content if b.type == "tool_use"]
        if not blocks:
            return []
        return _parse_edits(blocks[0].input)


class LocalCleanupClient:
    """`CleanupClient` reusing a managed `LocalSummaryClient` server."""

    def __init__(self, local: Any, *, max_tokens: int) -> None:
        self._local = local
        self._max_tokens = max_tokens

    def propose_edits(self, *, window_prompt: str, speakers: list[str]) -> list[SpeakerEdit]:
        system = _cleanup_system_prompt(speakers) + _schema_directive()
        user = (
            "Correct the speaker labels for these numbered segments. Reply with ONLY "
            "the JSON object described above.\n\n" + window_prompt
        )
        text = self._local.complete(
            system_prompt=system,
            user_message=user,
            max_tokens=self._max_tokens,
            response_format=_local_response_format(),
        )
        return _parse_edits_from_text(text)

    def close(self) -> None:
        self._local.close()


def _select_cleanup_backend(cfg: Config) -> CleanupClient:
    """Resolve the cleanup LLM backend.

    `regulated_mode` and the Apple Intelligence summary backend both pin
    the cleanup pass to the on-device MLX path (the Swift Foundation Model
    only summarizes; cleanup runs in Python and stays local for it).

    `auto` resolves here by key presence alone. Unlike summarize and engine,
    which share `backend_fallback.run_with_local_fallback`, cleanup does not
    fall back at call time, and does not need to: `run_all` already treats a
    cleanup failure as non-fatal and summarizes the un-cleaned transcript, so a
    retry on a second backend would buy tidier speaker labels at the price of a
    second model call on an optional polish pass. (Before PIPE7 this docstring
    claimed to mirror `summarize._select_backend`, which it never did.)
    """
    # Shared regulated/NDA force-local rule via the single chokepoint
    # (config.effective_backend, TECH-ARCH1); the apple/auto collapse below is
    # this site's own (cleanup runs in Python even when the summary is Apple).
    backend = effective_backend(cfg)
    if backend != cfg.summarization.backend:
        log.info("zero-egress mode active; forcing local cleanup backend (was %s)",
                 cfg.summarization.backend)
    if backend == "apple_intelligence":
        log.info("apple_intelligence backend; running cleanup on the local MLX backend")
        backend = "local"
    if backend == "auto":
        backend = "anthropic" if os.environ.get("ANTHROPIC_API_KEY") else "local"

    if backend == "local":
        from .summarize_local import LocalSummaryClient

        host, port = parse_local_endpoint(cfg.summarization.local_endpoint)
        return LocalCleanupClient(
            LocalSummaryClient(
                model=cfg.summarization.local_model, host=host, port=port,
                # LOCAL16: the configured floor, not the default, so turning the
                # watchdog down (or off) means the same thing on every local path.
                memory_floor_pct=cfg.summarization.local_memory_floor_pct,
            ),
            max_tokens=cfg.summarization.max_tokens,
        )
    if backend == "anthropic":
        return AnthropicCleanupClient(
            api_key=require_env("ANTHROPIC_API_KEY"),
            model=cfg.summarization.model,
            max_tokens=cfg.summarization.max_tokens,
        )
    raise ValueError(f"unknown summarization.backend: {backend!r}")


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: mp cleanup-diarization <transcript.json>", file=sys.stderr)
        return 2
    transcript_json = Path(argv[0]).expanduser().resolve()
    if not transcript_json.exists():
        print(f"No such file: {transcript_json}", file=sys.stderr)
        return 1
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    result = cleanup_transcript(transcript_json)
    print(
        f"diarize cleanup: {result['merges_count']} merges, "
        f"{result['reattributions_count']} reattributions, "
        f"{result['refusals_count']} refused "
        f"({result['latency_ms']} ms)"
    )
    print(f"  audit: {result['audit']}")
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
