"""Correction loop: file format, run-sidecar IO, and ``mp corrections-stats``.

ADR 0015 (corrections tab) is the rationale; this schema is the on-disk contract lock.

Two artifacts live next to each meeting and feed Phase 3 training:

* ``<recordings>/<stem>.run.json`` (run sidecar): written by
  ``mp run-all`` at the end of the summarize stage. Snapshots which
  backend + model produced the original summary so the correction
  record stays accurate even if the user flips backends afterwards.

* ``~/Library/Application Support/MeetingPipe/corrections/<stem>.json``
  (correction record): written by the daemon when the user clicks
  "Looks good" or "Edit summary" on a published meeting. One file per
  meeting, overwritten on re-correction.

Phase 3 training globs the corrections dir, joins each record with
its run sidecar (for transcript metadata), and emits ``(transcript,
corrected_summary)`` pairs.

Readiness gate (Phase 3 LoRA training): ``count >= 20`` AND
``sum(transcript_chars) >= 200_000``. Both must pass; the stats
command reports progress on each so the user can see what's needed.
"""
from __future__ import annotations

import json
import logging
import os
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

log = logging.getLogger("mp.corrections")

CORRECTIONS_DIR = Path(
    os.path.expanduser("~/Library/Application Support/MeetingPipe/corrections")
)

READINESS_MIN_COUNT = 20
READINESS_MIN_TRANSCRIPT_CHARS = 200_000


# ---------------------------------------------------------------------------
# Run sidecar (orchestrate -> disk)
# ---------------------------------------------------------------------------


def write_run_sidecar(
    *,
    recordings_dir: Path,
    stem: str,
    transcript_path: Path,
    transcript_chars: int,
    summary_json_path: Path,
    backend: str,
    model: str,
    adapter_path: str = "",
    ts: str | None = None,
) -> Path:
    """Snapshot the run that produced ``<stem>.summary.json``.

    Returns the absolute path of the written sidecar. Written atomically
    via a temp-file + rename so a crashing pipeline never leaves a
    half-written sidecar that breaks downstream readers.

    ``backend`` / ``model`` / ``adapter_path`` describe the engine that actually
    answered, not the one config asked for (LOCAL11): a warm ``mlx_lm.server``
    can be serving weights an earlier config selected, and attributing the
    summary to the current config would quietly launder that. ``adapter_path`` is
    "" for every backend but a local one serving a LoRA adapter.
    """
    payload: dict[str, Any] = {
        "schema_version": 1,
        "stem": stem,
        "transcript_path": str(transcript_path),
        "transcript_chars": int(transcript_chars),
        "summary_json_path": str(summary_json_path),
        "backend": backend,
        "model": model,
        "adapter_path": adapter_path,
        "ts": ts or _now_utc_iso(),
    }
    out = recordings_dir / f"{stem}.run.json"
    tmp = out.with_suffix(out.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    os.replace(tmp, out)
    return out


def write_empty_marker(
    *,
    recordings_dir: Path,
    stem: str,
    reason: str,
    ts: str | None = None,
) -> Path:
    """Write ``<stem>.empty.json`` for a recording the pipeline finished but
    intentionally produced no summary for (no detected speech).

    Without it the Library has no terminal sidecar to read, so an empty
    recording spins in "Processing" until the staleness window flips it to a
    misleading "Failed". The marker lets the Library show a terminal "No speech"
    state instead. Atomic via temp + rename, matching ``write_run_sidecar``.
    """
    payload: dict[str, Any] = {
        "schema_version": 1,
        "stem": stem,
        "reason": reason,
        "ts": ts or _now_utc_iso(),
    }
    out = recordings_dir / f"{stem}.empty.json"
    tmp = out.with_suffix(out.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    os.replace(tmp, out)
    return out


def set_publish_state(sidecar_path: Path, publish_state: str) -> None:
    """Record the resolved publish outcome onto an existing run sidecar (TECH-I6).

    The run sidecar is written before publish (it snapshots backend + model);
    once `fanout` returns, this merges a ``publish_state`` key so the Library can
    badge a partial or failed publish. Atomic and best-effort: a missing or
    unreadable sidecar is a no-op.
    """
    try:
        payload = json.loads(sidecar_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return
    if not isinstance(payload, dict):
        return
    payload["publish_state"] = publish_state
    tmp = sidecar_path.with_suffix(sidecar_path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    os.replace(tmp, sidecar_path)


def read_run_sidecar(path: Path) -> dict[str, Any] | None:
    """Best-effort read; returns ``None`` on any IO / parse failure.

    The stats command tolerates missing sidecars (older recordings
    pre-Phase-2) by counting them with empty backend/model.
    """
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def _now_utc_iso() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z")
    )


# ---------------------------------------------------------------------------
# Stats (mp corrections-stats)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class CorrectionRecord:
    stem: str
    verdict: str
    backend: str
    model: str
    transcript_chars: int
    has_corrected: bool
    edit_distances: dict[str, float]
    """Per-field normalized Levenshtein (0.0-1.0) when ``has_corrected``."""


def load_records(corrections_dir: Path) -> list[CorrectionRecord]:
    """Read every ``*.json`` file in ``corrections_dir`` and join with run
    sidecars when discoverable from ``transcript_path``."""
    if not corrections_dir.exists():
        return []
    out: list[CorrectionRecord] = []
    for path in sorted(corrections_dir.glob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception as e:
            log.warning("skipping unreadable correction %s: %s", path, e)
            continue
        rec = _record_from(data)
        if rec is not None:
            out.append(rec)
    return out


def _record_from(data: dict[str, Any]) -> CorrectionRecord | None:
    verdict = data.get("verdict")
    if verdict not in {"good", "bad", "edited"}:
        return None
    transcript_path = data.get("transcript_path") or ""
    stem = data.get("stem") or _stem_from_transcript(transcript_path)
    backend = data.get("backend") or ""
    model = data.get("model_id") or data.get("model") or ""

    transcript_chars = _resolve_transcript_chars(data, transcript_path)

    edits: dict[str, float] = {}
    has_corrected = False
    if verdict == "edited":
        original = data.get("original_summary") or {}
        corrected = data.get("corrected_summary") or {}
        if isinstance(original, dict) and isinstance(corrected, dict):
            has_corrected = True
            edits = _per_field_edit_distance(original, corrected)

    return CorrectionRecord(
        stem=stem,
        verdict=verdict,
        backend=backend,
        model=model,
        transcript_chars=transcript_chars,
        has_corrected=has_corrected,
        edit_distances=edits,
    )


def _stem_from_transcript(transcript_path: str) -> str:
    if not transcript_path:
        return ""
    name = os.path.basename(transcript_path)
    return name[:-3] if name.endswith(".md") else name


def _resolve_transcript_chars(
    data: dict[str, Any], transcript_path: str
) -> int:
    """Prefer the run sidecar's pre-computed count; fall back to stat'ing
    the transcript file directly. 0 when neither is available."""
    if not transcript_path:
        return 0
    p = Path(transcript_path)
    sidecar = p.with_suffix(".run.json") if p.suffix else Path(str(p) + ".run.json")
    side = read_run_sidecar(sidecar)
    if side and isinstance(side.get("transcript_chars"), int):
        return int(side["transcript_chars"])
    try:
        return len(Path(transcript_path).read_text(encoding="utf-8"))
    except Exception:
        return 0


# ---- Edit distance ---------------------------------------------------------


_TEXT_FIELDS = ("title", "summary", "decisions", "questions")


def _per_field_edit_distance(
    original: dict[str, Any], corrected: dict[str, Any]
) -> dict[str, float]:
    """Normalized Levenshtein per field (and ``actions.task``).

    Each field's value is flattened to a single newline-joined string,
    then Levenshtein is computed and normalized by the longer string's
    length so values stay in [0, 1]. Empty-on-both-sides → 0.
    """
    out: dict[str, float] = {}
    for f in _TEXT_FIELDS:
        out[f] = _normalized_levenshtein(
            _flatten(original.get(f)), _flatten(corrected.get(f))
        )
    out["actions.task"] = _normalized_levenshtein(
        _flatten_actions(original.get("actions")),
        _flatten_actions(corrected.get("actions")),
    )
    return out


def _flatten(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\n".join(str(v) for v in value if v is not None)
    return str(value)


def _flatten_actions(actions: Any) -> str:
    if not isinstance(actions, list):
        return ""
    return "\n".join(
        (a.get("task") or "") for a in actions if isinstance(a, dict)
    )


def _normalized_levenshtein(a: str, b: str) -> float:
    if a == b:
        return 0.0
    longest = max(len(a), len(b))
    if longest == 0:
        return 0.0
    return _levenshtein(a, b) / float(longest)


def _levenshtein(a: str, b: str) -> int:
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        curr = [i] + [0] * len(b)
        for j, cb in enumerate(b, 1):
            cost = 0 if ca == cb else 1
            curr[j] = min(curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost)
        prev = curr
    return prev[-1]


# ---- Aggregation -----------------------------------------------------------


def aggregate(records: Iterable[CorrectionRecord]) -> dict[str, Any]:
    records = list(records)
    total = len(records)
    by_verdict: dict[str, int] = {"good": 0, "edited": 0, "bad": 0}
    by_backend: dict[str, dict[str, int]] = {}
    by_model: dict[str, dict[str, int]] = {}
    transcript_chars = 0

    for r in records:
        by_verdict[r.verdict] = by_verdict.get(r.verdict, 0) + 1
        transcript_chars += r.transcript_chars
        backend_key = r.backend or "(unknown)"
        model_key = r.model or "(unknown)"
        _bump(by_backend, backend_key, r.verdict)
        _bump(by_model, model_key, r.verdict)

    # Mean per-field edit distance across edited records only.
    edits_acc: dict[str, list[float]] = {}
    for r in records:
        if not r.has_corrected:
            continue
        for k, v in r.edit_distances.items():
            edits_acc.setdefault(k, []).append(v)
    edits_mean = {k: (sum(v) / len(v)) for k, v in edits_acc.items() if v}

    ready = (
        total >= READINESS_MIN_COUNT
        and transcript_chars >= READINESS_MIN_TRANSCRIPT_CHARS
    )

    return {
        "total": total,
        "by_verdict": by_verdict,
        "by_backend": by_backend,
        "by_model": by_model,
        "transcript_chars": transcript_chars,
        "edits_mean": edits_mean,
        "ready": ready,
    }


def _bump(table: dict[str, dict[str, int]], key: str, verdict: str) -> None:
    bucket = table.setdefault(
        key, {"total": 0, "good": 0, "edited": 0, "bad": 0}
    )
    bucket["total"] += 1
    bucket[verdict] = bucket.get(verdict, 0) + 1


# ---- Markdown report -------------------------------------------------------


def render_report(stats: dict[str, Any]) -> str:
    lines: list[str] = ["# Correction corpus", ""]
    total = stats["total"]
    v = stats["by_verdict"]
    lines.append(
        f"Total: {total} corrections "
        f"(good: {v.get('good', 0)} / edited: {v.get('edited', 0)} / bad: {v.get('bad', 0)})"
    )

    chars = stats["transcript_chars"]
    pct_count = min(100, int(100 * total / max(1, READINESS_MIN_COUNT)))
    pct_chars = min(100, int(100 * chars / max(1, READINESS_MIN_TRANSCRIPT_CHARS)))
    gate = "ready" if stats["ready"] else "not yet"
    lines.append("")
    lines.append(f"Phase 3 readiness: {gate}")
    lines.append(
        f"  count:   {total} / {READINESS_MIN_COUNT} ({pct_count}%)"
    )
    lines.append(
        f"  corpus:  {chars:,} / {READINESS_MIN_TRANSCRIPT_CHARS:,} chars ({pct_chars}%)"
    )

    by_backend = stats["by_backend"]
    if by_backend:
        lines += ["", "## Per backend", ""]
        lines += _render_table(by_backend)

    by_model = stats["by_model"]
    if by_model:
        lines += ["", "## Per model", ""]
        lines += _render_table(by_model)

    edits = stats["edits_mean"]
    if edits:
        lines += [
            "",
            "## Edit intensity",
            "",
            "Mean normalized Levenshtein (edited only, 0.0 = unchanged, 1.0 = fully rewritten).",
            "",
        ]
        for field in ("title", "summary", "decisions", "actions.task", "questions"):
            if field in edits:
                lines.append(f"  {field:<14} {edits[field]:.2f}")

    lines.append("")
    return "\n".join(lines)


def _render_table(table: dict[str, dict[str, int]]) -> list[str]:
    out = [f"  {'name':<48} {'total':>5} {'good':>5} {'edited':>6} {'bad':>4}"]
    for key in sorted(table):
        b = table[key]
        out.append(
            f"  {key:<48} {b.get('total', 0):>5} "
            f"{b.get('good', 0):>5} {b.get('edited', 0):>6} {b.get('bad', 0):>4}"
        )
    return out


# ---- CLI -------------------------------------------------------------------


def main(argv: list[str]) -> int:
    """``mp corrections-stats [--dir PATH] [--json]`` entry point.

    ``--dir`` overrides the default location (mostly for tests).
    ``--json`` emits the aggregate dict as JSON instead of Markdown.
    """
    corrections_dir = CORRECTIONS_DIR
    as_json = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in {"-h", "--help"}:
            print(
                "usage: mp corrections-stats [--dir PATH] [--json]",
                file=sys.stderr,
            )
            return 0
        if a == "--dir":
            i += 1
            if i >= len(argv):
                print("missing value for --dir", file=sys.stderr)
                return 2
            corrections_dir = Path(argv[i]).expanduser()
        elif a == "--json":
            as_json = True
        else:
            print(f"unknown arg: {a}", file=sys.stderr)
            return 2
        i += 1

    records = load_records(corrections_dir)
    stats = aggregate(records)

    if as_json:
        print(json.dumps(stats, indent=2, sort_keys=True))
    else:
        print(render_report(stats))
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
