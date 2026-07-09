"""Multi-sink orchestrator helper.

Builds the configured publisher list from `Config.output.sinks` and
runs each sequentially against a `MeetingSummary`. Failures in one
sink log + emit `sink_failed` events but do not abort the rest, since
the user explicitly opted into "publish to all of these" and a
transient Notion outage shouldn't lose the local Obsidian copy.

Idempotency is per-sink: each publisher gets its own
`<wav-dir>/<stem>.<sink-name>.json` sidecar so re-runs are safe. The
naming convention is fixed by `MeetingPublisher.name` (P3.1).

Every fanout also writes one run-scoped `<stem>.publish.json` recording what
actually happened (PIPE1). The per-sink sidecars cannot answer that: a
publisher that raises never writes one, so a stale sidecar from an earlier
successful run survives and the daemon has no way to tell it from a fresh one.
That is how an all-sinks-failed run used to notify "Meeting published" with the
previous run's Notion URL.
"""
from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import events
from .config import Config, effective_sinks
from .schemas import MeetingSummary
from .services import MeetingPublisher

log = logging.getLogger("mp.publish_router")

# Exit code reserved for "every configured sink failed" (PIPE1). Distinct from 1
# (any other failure) and 2 (usage) so the daemon can attribute the failure to
# the publish stage without parsing stderr. Mirrored by
# `PipelineLauncher.publishFailedExitCode` in Swift.
EXIT_PUBLISH_FAILED = 3

#: Run-scoped result sidecar. Rewritten on every fanout, so it is never stale.
PUBLISH_SIDECAR_SUFFIX = ".publish.json"
PUBLISH_SIDECAR_SCHEMA_VERSION = 1


class PublisherBuildError(RuntimeError):
    """Raised when a sink listed in `output.sinks` can't be constructed
    (missing required config, unknown name). The orchestrator surfaces
    these at config-load time rather than mid-pipeline."""


def build_publishers(cfg: Config) -> list[MeetingPublisher]:
    """Build the ordered publisher list from `cfg.output.sinks`.

    Unknown sink names raise `PublisherBuildError`. Sinks that require
    config (e.g. obsidian needs a vault_path) but were left empty are
    skipped with a warning rather than raising, on the principle that
    a partially-configured install should still degrade gracefully -
    the user added "obsidian" to sinks but forgot to set vault_path.
    """
    out: list[MeetingPublisher] = []
    # effective_sinks applies the regulated/NDA egress clamp once (drops the
    # Notion sink under a zero-egress mode), so _build_one no longer carries
    # its own copy of that check. (TECH-ARCH1, folding in TECH-SEC2.)
    for name in effective_sinks(cfg):
        pub = _build_one(name, cfg)
        if pub is not None:
            out.append(pub)
    return out


def _build_one(name: str, cfg: Config) -> MeetingPublisher | None:
    if name == "notion":
        # The zero-egress clamp that used to drop this sink lives in
        # config.effective_sinks now (TECH-ARCH1 / TECH-SEC2): build_publishers
        # routes through it, so a "notion" name reaching here is already
        # allowed to egress.
        from .publish_notion import NotionRestPublisher
        from .config import require_env
        if not cfg.notion.database_id:
            log.warning("notion.database_id is empty; Notion sink will fail at upsert")
        token = require_env("NOTION_TOKEN")
        return NotionRestPublisher(token=token, cfg=cfg)
    if name == "obsidian":
        if not cfg.obsidian.vault_path:
            log.warning("obsidian sink listed but obsidian.vault_path is empty; skipping")
            return None
        from .publish_obsidian import ObsidianPublisher
        template = Path(cfg.obsidian.template_path).expanduser() if cfg.obsidian.template_path else None
        return ObsidianPublisher(
            vault_path=Path(cfg.obsidian.vault_path),
            folder=cfg.obsidian.folder,
            attach_audio=cfg.obsidian.attach_audio,
            attachments_subfolder=cfg.obsidian.attachments_subfolder,
            template_path=template,
            daily_note_backlink=cfg.obsidian.daily_note_backlink,
        )
    if name == "filesystem":
        from .publish_fs import FilesystemPublisher
        return FilesystemPublisher(output_dir=Path(cfg.filesystem.output_dir).expanduser())
    if name == "lan":
        # TECH-FEAT1: on-prem mounted share. Allowed under regulated mode
        # (effective_sinks only clamps the cloud Notion sink); the reachability
        # check fires at upsert time, not config-load time.
        from .publish_lan import LanPublisher
        return LanPublisher(
            mount_path=Path(cfg.lan.mount_path).expanduser(),
            host=cfg.lan.host,
        )
    raise PublisherBuildError(f"unknown sink in output.sinks: {name!r}")


def fanout(
    *,
    summary_json: Path,
    cfg: Config,
    transcript_md: Path | None,
    publishers: list[MeetingPublisher] | None = None,
) -> dict[str, Any]:
    """Run all configured publishers against `summary_json`. Returns the
    aggregate result.

    Each publisher's sidecar is `<wav-dir>/<stem>.<sink-name>.json`,
    derived from `summary_json` so the orchestrator passes one
    canonical path. The first sink's result is also returned at the
    top level (`page_id`, `page_url`) for backward compat with
    callers that expect Notion's shape; full per-sink results live in
    the `sinks` map.

    The summary JSON is parsed once here (not at the orchestrator) so
    test patches that stub `publish_fanout` do not need to materialize
    a valid `MeetingSummary` payload to satisfy a parse step that
    happens before the patch boundary.
    """
    pubs = publishers if publishers is not None else build_publishers(cfg)
    if not pubs:
        log.warning("no publishers configured; returning local-only result")
        # No sink ran, which is not the same as every sink failing: a regulated
        # run with only the Notion sink configured lands here and is a clean
        # success. `all_sinks_failed` keeps the two apart (PIPE1).
        result = {
            "page_id": None,
            "page_url": None,
            "sinks": {},
            "failures": [],
            "regulated": cfg.modes.regulated_mode,
        }
        _write_publish_sidecar(summary_json, result)
        return result

    summary = MeetingSummary.model_validate_json(
        summary_json.read_text(encoding="utf-8")
    )
    # Apply the daemon-extracted meeting title to every sink, not just Notion
    # (PIPE2/AUD-15). Lazy import mirrors `_build_one`'s convention and avoids a
    # publish_router <-> publish_notion import cycle.
    from .publish_notion import apply_meeting_title
    summary = apply_meeting_title(summary, summary_json)
    stem = summary_json.name.removesuffix(".summary.json")
    base = summary_json.parent

    per_sink: dict[str, Any] = {}
    failures: list[tuple[str, str]] = []
    for p in pubs:
        sidecar = base / f"{stem}.{p.name}.json"
        events.emit("publisher", "sink_started", sink=p.name, file=stem)
        try:
            res = p.upsert(
                summary=summary,
                transcript_md=transcript_md,
                sidecar_path=sidecar,
            )
            per_sink[p.name] = res
            events.emit("publisher", "sink_completed", sink=p.name, file=stem,
                        idempotent=bool(res.get("idempotent")))
        except Exception as e:  # noqa: BLE001
            log.error("sink %s failed: %s", p.name, e)
            per_sink[p.name] = {"error": str(e), "error_type": type(e).__name__}
            failures.append((p.name, str(e)))
            events.emit("publisher", "sink_failed", sink=p.name, file=stem,
                        error=str(e), error_type=type(e).__name__)

    landed = _landed_page(per_sink)
    out = {
        "page_id": landed.get("page_id"),
        "page_url": landed.get("page_url"),
        "sinks": per_sink,
        "failures": failures,
    }
    _write_publish_sidecar(summary_json, out)
    return out


def _landed_page(per_sink: dict[str, Any]) -> dict[str, Any]:
    """The first sink that succeeded *and* produced a page URL (PIPE1/AUD-30).

    The old rule was "whatever the first sink in configuration order returned",
    which reported no URL when a page-less sink (obsidian, filesystem) happened
    to be listed ahead of Notion, and which said nothing about whether the sink
    it picked had actually succeeded. Sinks that publish no page (the local ones)
    contribute no URL; a run where every page-producing sink failed reports none,
    rather than inheriting the last successful run's.
    """
    for res in per_sink.values():
        if isinstance(res, dict) and not res.get("error") and res.get("page_url"):
            return res
    return {}


def publish_state(result: dict[str, Any]) -> str:
    """Classify a `fanout` result for the Library row indicator (TECH-I6).

    ``"full"`` when every sink succeeded, ``"partial"`` when some succeeded and
    some failed, ``"none"`` when every sink failed or none ran. A failed sink is
    recorded in the per-sink map as a dict carrying an ``error`` key.
    """
    sinks = result.get("sinks") or {}
    if not sinks:
        return "none"
    failed = sum(1 for r in sinks.values() if isinstance(r, dict) and r.get("error"))
    if failed == 0:
        return "full"
    if failed >= len(sinks):
        return "none"
    return "partial"


def all_sinks_failed(result: dict[str, Any]) -> bool:
    """True when at least one publisher ran and every one of them failed (PIPE1).

    Deliberately narrower than ``publish_state(result) == "none"``, which also
    covers "no publisher ran at all". Nothing-to-do is a success (a regulated run
    whose only sink was Notion); everything-failed is the case where the pipeline
    must exit non-zero rather than let the daemon clear `<stem>.error.json` and
    announce a meeting that never landed anywhere.
    """
    sinks = result.get("sinks") or {}
    return bool(sinks) and all(
        isinstance(r, dict) and r.get("error") for r in sinks.values()
    )


def publish_sidecar_path(summary_json: Path) -> Path:
    stem = summary_json.name.removesuffix(".summary.json")
    return summary_json.parent / f"{stem}{PUBLISH_SIDECAR_SUFFIX}"


def _write_publish_sidecar(summary_json: Path, result: dict[str, Any]) -> None:
    """Record this run's publish outcome next to the summary (PIPE1).

    Rewritten on every fanout, so the daemon reading it always sees the run that
    just finished. Atomic, and best-effort: a write failure is logged but never
    turns a successful publish into a failed one. The daemon degrades to "no page
    URL" when the file is absent (every `run-all` short-circuit leaves none).
    """
    sinks = result.get("sinks") or {}
    payload = {
        "schema_version": PUBLISH_SIDECAR_SCHEMA_VERSION,
        "state": publish_state(result),
        "page_url": result.get("page_url"),
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "sinks": {
            name: {
                "ok": not (isinstance(res, dict) and res.get("error")),
                "page_url": res.get("page_url") if isinstance(res, dict) else None,
                "error": res.get("error") if isinstance(res, dict) else None,
            }
            for name, res in sinks.items()
        },
    }
    path = publish_sidecar_path(summary_json)
    try:
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(path)
    except OSError as e:
        log.warning("publish sidecar write failed: %s", e)
