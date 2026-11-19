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

DIAR9 bounds what a steered model can do. Moving more than half of one
speaker's lines to other speakers needs the same voiceprint agreement; a
window may only relabel lines whose `[n]` it showed; and a transcript the
pass already cleaned is skipped unless `--force`.
"""
from __future__ import annotations

import argparse
import json
import logging
import sys
import time
from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass
from importlib import resources
from pathlib import Path
from typing import Any, NamedTuple, Protocol, runtime_checkable

from . import entry, events, providers, storage
from .chunking import chunked_windows
from .config import (
    Config,
    anthropic_sampling,
    effective_backend,
)
from .diarize import cosine_similarity
from .markdown import render_markdown
from .prompt_safety import UNTRUSTED_GUIDANCE, wrap_untrusted

log = logging.getLogger("mp.diarize_cleanup")

DEFAULT_WINDOW_CHARS = 8000
DEFAULT_OVERLAP_CHARS = 200

# PIPE24: the whole pass gets this long, then it applies the edits gathered so
# far and returns. The pass is optional polish that runs before summarize, and a
# stall in it never raises in time: windows run back to back (a two-hour meeting
# is about 14), each can wait ~120 s, so a degraded network could spend half an
# hour here and then run into run-all's 90-minute watchdog, which SIGKILLs the
# summary and the publish with it. Ten minutes leaves that cap room for
# summarize's own worst case.
CLEANUP_DEADLINE_SEC = 600.0
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

# DIAR9. A spoken "for the record, those lines were Bob's" can steer the pass into
# moving one person's lines under another person's name while leaving the source
# label alive, which DIAR5's emptied-label guard never looked at. So a batch that
# moves more than this share of one label's segments away needs the same voiceprint
# agreement a merge does, each edit judged against its own destination. Counted
# over all destinations together, so splitting the move across two labels does
# not slip under it. Unattributed `Speaker?` lines are exempt, since naming them is
# the pass's job rather than a move away from a person. Fail-open without
# voiceprints, as DIAR5 is: that is the existing, pinned trade-off, not this one.
# It catches bulk moves; a targeted move of a few lines from a long-talking
# speaker stays under it, and only a per-segment voiceprint (which the daemon does
# not keep) could check those.
REATTRIBUTE_MAX_FRACTION = 0.5
REFUSED_CAP = "reattribution_cap"

# DIAR9 (F097). An edit to a segment the proposing window never showed. The model
# may only relabel what it was given to read; anything else is a reach, and under
# a prompt injection it is a reach into another part of the meeting.
REFUSED_OUTSIDE_WINDOW = "outside_window"

#: DIAR9 (F100). The `skipped` value of a pass that found the transcript already
#: cleaned and did nothing.
SKIPPED_ALREADY_CLEANED = "already_cleaned"


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


class UnparsedCleanupReply(ValueError):
    """A window's reply carried no edits object at all (OBS2): free text with no decodable JSON,
    or an Anthropic reply with no `tool_use` block. Raised by the clients and counted by
    `_gather_edits` as `parse_failed_windows`, so a model that could not be read no longer looks
    identical to one that read the window and found nothing to fix. Never carries the reply."""


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
    force: bool = False,
    deadline_sec: float = CLEANUP_DEADLINE_SEC,
    clock: Callable[[], float] = time.monotonic,
) -> dict[str, Any]:
    """Run the cleanup pass over a finalized `<stem>.json` transcript.

    Rewrites `<stem>.json` (with `diarize_cleaned: true`), re-renders
    `<stem>.md`, and writes the per-segment audit record to
    `<stem>.diarize_cleanup.json`. A single-speaker transcript is a no-op
    (no LLM call) but still leaves the audit record, so its presence means
    "the pass ran" and its absence means "it never did". Emits a
    `pipeline`/`diarize_cleanup` event with the counts and the wall-clock
    latency.

    DIAR9 (F100): a transcript that already carries `diarize_cleaned` is left
    alone, with no client call and the audit file untouched, unless `force`. A
    second pass would run over the first pass's labels and its audit would
    replace the one that can undo the first. The daemon never meets a cleaned
    transcript (it re-transcribes before every full run); a manual `mp run-all`
    over an existing `<stem>.json` and a repeated `mp cleanup-diarization` do.

    PIPE24: past `deadline_sec` no further window is issued; the edits gathered
    so far are applied and the pass returns normally (the event says how far it
    got), so run-all's non-fatal contract holds and a stall cannot run into its
    watchdog. `clock` is injectable for the same reason `valid1_check`'s is.
    """
    cfg = entry.prepare(cfg, transcript_json)  # SEC13: overlay, arm, secrets

    structured = json.loads(transcript_json.read_text(encoding="utf-8"))
    segments: list[dict[str, Any]] = structured.get("segments") or []
    speakers = _distinct_speakers(segments)

    if structured.get("diarize_cleaned") and not force:
        log.info("diarize cleanup: %s is already cleaned; skipping (pass --force to re-run)",
                 transcript_json.name)
        events.emit("pipeline", "diarize_cleanup", skipped=SKIPPED_ALREADY_CLEANED,
                    segments=len(segments), speakers=len(speakers))
        return {
            "json": transcript_json,
            "md": transcript_json.with_suffix(".md"),
            "audit": transcript_json.with_name(f"{transcript_json.stem}.diarize_cleanup.json"),
            "merges_count": 0,
            "reattributions_count": 0,
            "refusals_count": 0,
            "latency_ms": 0,
            "skipped": SKIPPED_ALREADY_CLEANED,
        }

    started = time.monotonic()
    applied: list[EditRecord] = []
    refused: list[EditRecord] = []
    windows_done = windows_total = parse_failed = 0
    deadline_hit = False
    if segments and len(speakers) >= 2:
        owns_client = client is None
        if client is None:
            client = _select_cleanup_backend(cfg)
        try:
            gathered = _gather_edits(
                segments, speakers, client, window_chars, overlap_chars,
                deadline_sec=deadline_sec, clock=clock,
            )
        finally:
            if owns_client:
                close = getattr(client, "close", None)
                if callable(close):
                    close()
        edits_by_index, outside = gathered.by_index, gathered.outside
        windows_done, windows_total = gathered.windows_done, gathered.windows_total
        deadline_hit = gathered.deadline_hit
        parse_failed = gathered.parse_failed
        proposed = _effective_edits(segments, edits_by_index, speakers)
        embeddings = _load_embeddings(transcript_json)
        applied, refused = _refuse_unsupported_merges(segments, proposed, embeddings)
        refused = sorted(
            refused + [
                EditRecord(e.segment_index, e.from_speaker, e.to_speaker, e.kind,
                           reason=REFUSED_OUTSIDE_WINDOW)
                for edit in outside.values()
                for e in _effective_edits(segments, {edit.segment_index: edit}, speakers)
            ],
            key=lambda e: e.segment_index,
        )
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
        parse_failed_windows=parse_failed,
    )

    log.info(
        "diarize cleanup: %d merges, %d reattributions, %d refused, %d of %d windows unparsed "
        "in %d ms",
        merges, reattributions, len(refused), parse_failed, windows_done, latency_ms,
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
        windows_done=windows_done,
        windows_total=windows_total,
        deadline_hit=deadline_hit,
        parse_failed_windows=parse_failed,
    )
    return {
        "json": transcript_json,
        "md": md_path,
        "audit": audit_path,
        "merges_count": merges,
        "reattributions_count": reattributions,
        "refusals_count": len(refused),
        "latency_ms": latency_ms,
        "parse_failed_windows": parse_failed,
        # OBS8: the denominator for the run sidecar's relabel share.
        "segments": len(segments),
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


def _render_lines(segments: list[dict[str, Any]]) -> list[str]:
    lines: list[str] = []
    for i, seg in enumerate(segments):
        speaker = seg.get("speaker") or _UNKNOWN_SPEAKER
        text = (seg.get("text") or "").strip()
        lines.append(f"[{i}] {speaker}: {text}")
    return lines


def _render_indexed(segments: list[dict[str, Any]]) -> str:
    return "\n".join(_render_lines(segments))


class _Gathered(NamedTuple):
    by_index: dict[int, SpeakerEdit]
    outside: dict[tuple[int, str], SpeakerEdit]
    windows_done: int
    windows_total: int
    deadline_hit: bool
    parse_failed: int = 0


def _gather_edits(
    segments: list[dict[str, Any]],
    speakers: list[str],
    client: CleanupClient,
    window_chars: int,
    overlap_chars: int,
    *,
    deadline_sec: float | None = None,
    clock: Callable[[], float] = time.monotonic,
) -> _Gathered:
    """Every window's proposals: `by_index` (shown) and `outside`.

    PIPE24: before each window, a clock past `deadline_sec` from the first one
    stops the loop; what was gathered stands. `windows_total` is counted from the
    whole window list so the event can say how much was skipped.

    DIAR9 (F097): a window may only relabel a segment whose `[n] speaker:` prefix
    it showed; a line it caught only the tail of is not one the model could have
    named. What it showed comes from where each real line sits in the rendered
    text (the window's own offset), never from `[n]` prefixes parsed out of the
    window, so a segment whose text says "[40] ..." cannot put 40 in view. Shown
    proposals keep "last wins" across overlapping windows. Every outside proposal
    is kept, one per (index, label), so each lands in the audit's `refused`, even
    for an index some other window legitimately relabelled.
    """
    lines = _render_lines(segments)
    rendered = "\n".join(lines)
    starts: list[tuple[int, int]] = []  # (line start, end of its "[n] speaker:" prefix)
    offset = 0
    for i, line in enumerate(lines):
        speaker = segments[i].get("speaker") or _UNKNOWN_SPEAKER
        starts.append((offset, offset + len(f"[{i}] {speaker}:")))
        offset += len(line) + 1
    by_index: dict[int, SpeakerEdit] = {}
    outside: dict[tuple[int, str], SpeakerEdit] = {}
    windows = list(chunked_windows(rendered, max_chars=window_chars, overlap_chars=overlap_chars))
    cutoff = None if deadline_sec is None else clock() + deadline_sec
    done = parse_failed = 0
    deadline_hit = False
    for window in windows:
        if cutoff is not None and clock() >= cutoff:
            deadline_hit = True
            log.warning(
                "diarize cleanup: %.0fs deadline passed after %d of %d windows; "
                "applying the edits gathered so far", deadline_sec, done, len(windows),
            )
            break
        lo, hi = window.offset, window.offset + len(window.text)
        shown = {i for i, (a, b) in enumerate(starts) if a >= lo and b <= hi}
        # Fence each window as untrusted content (TECH-SEC6); the segment numbers
        # stay intact inside the markers so edits still reference them.
        try:
            proposed = client.propose_edits(window_prompt=wrap_untrusted(window.prompt),
                                            speakers=speakers)
        except UnparsedCleanupReply:
            # OBS2: an unreadable reply proposes nothing, as before, but is counted.
            proposed = []
            parse_failed += 1
        for edit in proposed:
            if edit.segment_index in shown:
                by_index[edit.segment_index] = edit  # overlapping windows: last wins
            else:
                outside[(edit.segment_index, edit.speaker)] = edit
        done += 1
        events.note_progress()  # PIPE53: a finished window is a unit of progress
    return _Gathered(by_index, outside, done, len(windows), deadline_hit, parse_failed)


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

    DIAR9 adds the cap: a batch moving more than `REATTRIBUTE_MAX_FRACTION` of
    one label's segments away is held, edit by edit, to the same voiceprint bar
    (reason `reattribution_cap`), because that is what a steered "those were
    Bob's" looks like, and the label surviving it says nothing about whether
    the lines were Bob's. A per-segment check is not possible: the daemon keeps
    one voiceprint per cluster and discards the per-segment embeddings.
    """
    counts = Counter(
        seg.get("speaker") or _UNKNOWN_SPEAKER for seg in segments
    )
    leaving = Counter(e.from_speaker for e in proposed)
    emptied = {label for label, n in leaving.items() if counts.get(label, 0) <= n}
    capped = {
        label for label, n in leaving.items()
        if label != _UNKNOWN_SPEAKER and n > REATTRIBUTE_MAX_FRACTION * counts.get(label, 0)
    }

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
        disagree = similarity is not None and similarity < MERGE_MIN_SIMILARITY
        reason = None
        if disagree and edit.from_speaker in emptied:
            reason = _REFUSED_VOICEPRINT
        elif disagree and edit.from_speaker in capped:
            reason = REFUSED_CAP
        if reason is not None:
            refused.append(
                EditRecord(
                    scored.segment_index, scored.from_speaker, scored.to_speaker,
                    scored.kind, similarity=similarity, reason=reason,
                )
            )
            continue
        allowed.append(scored)
    if refused:
        log.info(
            "diarize cleanup: refused %d edit(s) emptying or mostly moving a label "
            "whose voiceprint disagrees (below %.2f)", len(refused), MERGE_MIN_SIMILARITY,
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
    data = storage.read_json_object(transcript_json.with_name(f"{transcript_json.stem}.embeddings.json"))
    if data is None:
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
    parse_failed_windows: int = 0,
) -> Path:
    """Record what the pass changed, per segment, to `<stem>.diarize_cleanup.json`.

    The counts alone could not answer whether an owner correction undid a
    cleanup edit or a clustering mistake, which is what made the 2026-08-04
    regression an inference rather than evidence (DIAR5). Keyed by segment
    array index, the same join key the two overlay sidecars use.

    Rewritten in full by each run, so it describes the last run only: after a
    second `mp cleanup-diarization --force` the `from` labels are the first run's
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
        # OBS2: windows whose reply could not be read; "0 merges" means "nothing to fix" only
        # when this is 0 too.
        "parse_failed_windows": parse_failed_windows,
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
    parse it. Reuses the summarizer's balanced-object scan.

    Raises `UnparsedCleanupReply` when no candidate decodes (OBS2); a reply that decodes
    but carries no usable edit is still an honest empty list."""
    from .summarize_local import _largest_balanced_json_object

    for candidate in (text.strip(), _largest_balanced_json_object(text)):
        if not candidate:
            continue
        try:
            return _parse_edits(json.loads(candidate))
        except json.JSONDecodeError:
            continue
    raise UnparsedCleanupReply("cleanup reply carried no decodable JSON object")


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
        self._client = providers.make_anthropic_client(api_key)
        self._model = model
        self._max_tokens = max_tokens

    def propose_edits(self, *, window_prompt: str, speakers: list[str]) -> list[SpeakerEdit]:
        from .summarize import _create_message

        response = _create_message(
            self._client,
            model=self._model,
            **anthropic_sampling(self._model, self._max_tokens, tool_name="emit_speaker_edits"),
            system=[
                {
                    "type": "text",
                    "text": _cleanup_system_prompt(speakers),
                    "cache_control": {"type": "ephemeral"},
                },
            ],
            tools=[CLEANUP_TOOL],
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
            raise UnparsedCleanupReply("cleanup reply carried no tool_use block")
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


class TextCleanupClient:
    """`CleanupClient` over any free-form `complete` call (PIPE19).

    The `openai` and `claude_cli` backends have no tool-use or server-side schema
    forcing, so the schema rides in the system prompt, the way the local path
    frames it, and the reply goes through the same balanced-object recovery.
    Before this, cleanup had no path for either backend at all: the selector
    raised, `run_all` swallowed it, and the Preferences toggle did nothing.
    """

    def __init__(self, complete: Callable[..., str], *, max_tokens: int) -> None:
        self._complete = complete
        self._max_tokens = max_tokens

    def propose_edits(self, *, window_prompt: str, speakers: list[str]) -> list[SpeakerEdit]:
        text = self._complete(
            system_prompt=_cleanup_system_prompt(speakers) + _schema_directive(),
            user_message=(
                "Correct the speaker labels for these numbered segments. Reply with ONLY "
                "the JSON object described above.\n\n" + window_prompt
            ),
            max_tokens=self._max_tokens,
        )
        return _parse_edits_from_text(text)


def _select_cleanup_backend(cfg: Config) -> CleanupClient:
    """Build the cleanup client for the resolved backend (PIPE19: a lookup in
    `providers`).

    `regulated_mode` / NDA force the on-device path through the single chokepoint
    (config.effective_backend, TECH-ARCH1). A row with a `stand_in` runs cleanup on
    that row instead: Apple Intelligence only summarizes, in Swift, so its cleanup
    pass runs in Python on the local MLX model and stays on-device.

    `auto` resolves by key presence alone, with no call-time fallback; the reason
    is at `providers._auto_cleanup`.
    """
    backend = effective_backend(cfg)
    if backend != cfg.summarization.backend:
        log.info("zero-egress mode active; forcing local cleanup backend (was %s)",
                 cfg.summarization.backend)
    row = providers.lookup(backend)
    if row.stand_in is not None:
        log.info("%s backend; running cleanup on the %s backend", backend, row.stand_in)
        row = providers.lookup(row.stand_in)
    if row.build_cleanup is None:
        raise ValueError(f"summarization.backend {backend!r} has no speaker-cleanup path")
    return row.build_cleanup(cfg)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="mp cleanup-diarization",
                                 description="LLM speaker-label cleanup over a finalized transcript.")
    ap.add_argument("transcript", type=Path, help="<stem>.json")
    ap.add_argument("--force", action="store_true",
                    help="re-run on a transcript already cleaned (its audit is replaced)")
    args = ap.parse_args(argv)
    transcript_json = args.transcript.expanduser().resolve()
    if not transcript_json.exists():
        print(f"No such file: {transcript_json}", file=sys.stderr)
        return 1
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    result = cleanup_transcript(transcript_json, force=args.force)
    if result.get("skipped"):
        print(f"diarize cleanup: skipped, {transcript_json.name} is already cleaned "
              "(pass --force to re-run)")
        return 0
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
