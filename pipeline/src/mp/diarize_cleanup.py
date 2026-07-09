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
"""
from __future__ import annotations

import json
import logging
import os
import sys
import time
from dataclasses import dataclass
from importlib import resources
from pathlib import Path
from typing import Any, Protocol, runtime_checkable

import anthropic

from . import entry, events
from .chunking import chunked_windows
from .config import Config, effective_backend, require_env
from .markdown import render_markdown
from .prompt_safety import UNTRUSTED_GUIDANCE, wrap_untrusted

log = logging.getLogger("mp.diarize_cleanup")

DEFAULT_WINDOW_CHARS = 8000
DEFAULT_OVERLAP_CHARS = 200
_UNKNOWN_SPEAKER = "Speaker?"
_VALID_KINDS = ("merge", "reattribute")


@dataclass(frozen=True)
class SpeakerEdit:
    """One proposed speaker-label correction for a numbered segment."""

    segment_index: int
    speaker: str
    kind: str  # "merge" | "reattribute"


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

    Rewrites `<stem>.json` (with `diarize_cleaned: true`) and re-renders
    `<stem>.md`. A single-speaker transcript is a no-op (no LLM call).
    Emits a `pipeline`/`diarize_cleanup` event with the merge and
    reattribution counts and the wall-clock latency.
    """
    cfg = entry.prepare(cfg, transcript_json)  # SEC13: overlay, arm, secrets

    structured = json.loads(transcript_json.read_text(encoding="utf-8"))
    segments: list[dict[str, Any]] = structured.get("segments") or []
    speakers = _distinct_speakers(segments)

    started = time.monotonic()
    applied: list[SpeakerEdit] = []
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
        applied = _apply_edits(segments, edits_by_index, speakers)
    else:
        log.info("diarize cleanup: %d distinct speaker(s); nothing to clean", len(speakers))

    merges = sum(1 for e in applied if e.kind == "merge")
    reattributions = sum(1 for e in applied if e.kind == "reattribute")
    latency_ms = int((time.monotonic() - started) * 1000)

    structured["segments"] = segments
    structured["diarize_cleaned"] = True
    transcript_json.write_text(
        json.dumps(structured, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    md_path = transcript_json.with_suffix(".md")
    md_path.write_text(render_markdown(structured), encoding="utf-8")

    log.info(
        "diarize cleanup: %d merges, %d reattributions in %d ms",
        merges, reattributions, latency_ms,
    )
    events.emit(
        "pipeline", "diarize_cleanup",
        merges_count=merges,
        reattributions_count=reattributions,
        latency_ms=latency_ms,
        segments=len(segments),
        speakers=len(speakers),
    )
    return {
        "json": transcript_json,
        "md": md_path,
        "merges_count": merges,
        "reattributions_count": reattributions,
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


def _apply_edits(
    segments: list[dict[str, Any]],
    by_index: dict[int, SpeakerEdit],
    speakers: list[str],
) -> list[SpeakerEdit]:
    valid = set(speakers)
    applied: list[SpeakerEdit] = []
    for idx, edit in by_index.items():
        if not (0 <= idx < len(segments)):
            continue
        if edit.speaker not in valid:
            continue  # never honour an invented speaker
        if segments[idx].get("speaker") == edit.speaker:
            continue  # no-op
        segments[idx]["speaker"] = edit.speaker
        applied.append(edit)
    return applied


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
    """Resolve the cleanup LLM backend, mirroring summarize._select_backend.

    `regulated_mode` and the Apple Intelligence summary backend both pin
    the cleanup pass to the on-device MLX path (the Swift Foundation Model
    only summarizes; cleanup runs in Python and stays local for it).
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
        from .summarize import _parse_local_endpoint
        from .summarize_local import LocalSummaryClient

        host, port = _parse_local_endpoint(cfg.summarization.local_endpoint)
        return LocalCleanupClient(
            LocalSummaryClient(model=cfg.summarization.local_model, host=host, port=port),
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
        f"{result['reattributions_count']} reattributions "
        f"({result['latency_ms']} ms)"
    )
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
