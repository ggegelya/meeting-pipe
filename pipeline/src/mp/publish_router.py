"""Multi-sink orchestrator helper.

Builds the configured publisher list from `Config.output.sinks` and
runs each sequentially against a `MeetingSummary`. Failures in one
sink log + emit `sink_failed` events but do not abort the rest, since
the user explicitly opted into "publish to all of these" and a
transient Notion outage shouldn't lose the local Obsidian copy.

Idempotency is per-sink: each publisher gets its own
`<wav-dir>/<stem>.<sink-name>.json` sidecar so re-runs are safe. The
naming convention is fixed by `MeetingPublisher.name` (P3.1).
"""
from __future__ import annotations

import logging
from pathlib import Path
from typing import Any

from . import events
from .config import Config, effective_sinks
from .schemas import MeetingSummary
from .services import MeetingPublisher

log = logging.getLogger("mp.publish_router")


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
        return {
            "page_id": None,
            "page_url": None,
            "sinks": {},
            "regulated": cfg.modes.regulated_mode,
        }

    summary = MeetingSummary.model_validate_json(
        summary_json.read_text(encoding="utf-8")
    )
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

    primary = next(iter(per_sink.values())) if per_sink else {}
    out = {
        "page_id": primary.get("page_id"),
        "page_url": primary.get("page_url"),
        "sinks": per_sink,
        "failures": failures,
    }
    return out
