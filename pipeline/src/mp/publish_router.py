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

from . import events, storage
from .corrections import report_sidecar_write_failed
from .transcript_corrections import publish_text
from .config import Config, effective_sinks, zero_egress
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
#: The `state` of the marker `fanout` writes before any sink runs (PIPE34). A run whose final
#: write then fails leaves this, never the previous run's outcome. Swift badges it like `none`.
PUBLISH_STATE_UNKNOWN = "unknown"


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

    A missing *secret* is the third case and is neither of those (PIPE16): the
    sink is returned as an `UnavailablePublisher`, so it is present in the run's
    result as a failure rather than absent from it. Skipped is what the user
    half-configured; failed is what they configured and could not reach, and
    only the second may not be quietly rounded up to `publish_state == "full"`.
    """
    out: list[MeetingPublisher] = []
    # effective_sinks applies the regulated/NDA egress clamp once (drops the
    # Notion sink under a zero-egress mode), so _build_one no longer carries
    # its own copy of that check. (TECH-ARCH1, folding in TECH-SEC2.)
    for name in effective_sinks(cfg):
        pub = _build_synced_refusal(name, cfg) or _build_one(name, cfg)
        if pub is not None:
            out.append(pub)
    return out


#: The `reason` a refused-for-sync sink carries in `<stem>.publish.json` (SEC18).
SYNCED_TARGET_REASON = "synced_target"


class SyncedTargetError(RuntimeError):
    """A zero-egress run's file sink points inside a cloud-sync folder (SEC18).

    The clamp keeps every *network* call off the wire, but a sink that writes into a
    folder a sync client owns uploads the same summary and transcript from underneath
    it, which is the promise the clamp exists to keep. Recorded as a failed sink with
    `reason: synced_target` so the exit-3 all-sinks-failed contract and the Library
    row's failure copy apply unchanged; the summary itself is still in the library.
    """

    reason = SYNCED_TARGET_REASON

    def __init__(self, sink: str, target: Path, provider_name: str) -> None:
        self.sink = sink
        self.target = target
        self.provider_name = provider_name
        super().__init__(
            f"{SYNCED_TARGET_REASON}: the {sink} sink writes to {target}, which {provider_name} "
            "syncs, and regulated mode or an NDA workflow promises nothing leaves this Mac. "
            "Point the sink at a folder outside the synced tree."
        )


def _local_target(name: str, cfg: Config) -> Path | None:
    """The folder a local-writing sink would write into, or None for a sink with no
    local target (Notion) or one left unconfigured (which `_build_one` skips)."""
    if name == "filesystem":
        return Path(cfg.filesystem.output_dir).expanduser()
    if name == "obsidian" and cfg.obsidian.vault_path:
        return Path(cfg.obsidian.vault_path).expanduser()
    # No `lan` here: a network mount is not a sync folder, and `detect_sync_provider`
    # walks every ancestor with `listxattr`, which a stale SMB mount can hang.
    return None


def _build_synced_refusal(name: str, cfg: Config) -> UnavailablePublisher | None:
    """SEC18: under zero egress, stand in for a file sink whose target a sync client
    owns. Checked for the filesystem and Obsidian targets, not only the filesystem one the
    sink clamp currently leaves, so relaxing the clamp cannot reopen the hole."""
    if not zero_egress(cfg):
        return None
    target = _local_target(name, cfg)
    if target is None:
        return None
    from .cloudsync import detect_sync_provider
    provider = detect_sync_provider(target)
    if provider is None:
        return None
    log.error("%s sink refused: %s is synced by %s under zero egress", name, target, provider.name)
    return UnavailablePublisher(name, SyncedTargetError(name, target, provider.name))


class UnavailablePublisher:
    """A sink that could not be constructed, standing in for it so the failure is
    *recorded* rather than aborting the fan-out (PIPE16).

    `_build_one` used to let `require_env`'s `sys.exit(2)` out of
    `build_publishers`, which `fanout` calls before any publisher runs, so one
    missing `NOTION_TOKEN` killed the Obsidian and filesystem sinks configured
    beside it, in direct contradiction of this module's own opening contract.

    Skipping the sink silently, the way an empty `obsidian.vault_path` is
    skipped, would have been the smaller change and is the wrong one: a skipped
    sink is absent from `per_sink`, so `publish_state` would read `"full"` for a
    run that reached one fewer destination than it was told to. Failing here
    instead means the run is honest in every direction at once: the other sinks
    publish, the state reads `"partial"`, `<stem>.publish.json` records which sink
    failed and why, a `publisher.sink_failed` event is emitted, and a
    notion-only workflow still exits 3 through `all_sinks_failed` so the row gets
    the publish-only retry rather than paying the summarizer again.
    """

    def __init__(self, name: str, error: Exception) -> None:
        self.name = name
        self._error = error

    def upsert(self, **_kwargs: Any) -> dict[str, Any]:
        raise self._error


def _build_one(name: str, cfg: Config) -> MeetingPublisher | None:
    if name == "notion":
        # The zero-egress clamp that used to drop this sink lives in
        # config.effective_sinks now (TECH-ARCH1 / TECH-SEC2): build_publishers
        # routes through it, so a "notion" name reaching here is already
        # allowed to egress.
        from .publish_notion import NotionRestPublisher
        from .config import MissingSecretError, require_env
        if not cfg.notion.database_id:
            log.warning("notion.database_id is empty; Notion sink will fail at upsert")
        try:
            token = require_env("NOTION_TOKEN")
        except MissingSecretError as e:
            log.error("notion sink unavailable: %s", e)
            return UnavailablePublisher(name, e)
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
        # TECH-FEAT1: on-prem mounted share. Zero egress no longer reaches this
        # branch (`effective_sinks` leaves only the filesystem sink, SEC18); the
        # reachability check fires at upsert time, not config-load time.
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
    # PIPE34: before any sink runs, replace the previous run's outcome with an `unknown`
    # marker, so a final write that fails cannot leave the old outcome looking current.
    if not _write_pending_marker(summary_json):
        reason = f"{publish_sidecar_path(summary_json).name} could not be replaced or removed"
        log.error("publish aborted before any sink ran: %s", reason)
        return {
            "page_id": None, "page_url": None, "sinks": {}, "failures": [("publish.json", reason)],
            "sidecar_write_failed": True,
        }
    log.debug("publish: configured sinks=%s, built=%s",
              ",".join(cfg.output.sinks) or "(none)", ",".join(p.name for p in pubs) or "(none)")
    if not pubs:
        log.warning("no publishers configured; returning local-only result")
        # No sink ran, which is not the same as every sink failing: a regulated
        # run with only the Notion sink configured lands here and is a clean
        # success. `all_sinks_failed` keeps the two apart (PIPE1).
        #
        # WF10 splits "no sink ran" once more, for `publish_state`: nothing was
        # *meant* to run (the resolved sink list is empty: a workflow with no
        # destinations, or the egress clamp dropping its only sink) reads
        # "local", a settled meeting kept in the Library. Sinks were configured
        # and `build_publishers` skipped every one (an obsidian sink with no
        # vault path) stays "none", so the half-configuration still surfaces.
        result = {
            "page_id": None,
            "page_url": None,
            "sinks": {},
            "failures": [],
            "regulated": cfg.modes.regulated_mode,
            "no_sinks_configured": not effective_sinks(cfg),
        }
        if not _write_publish_sidecar(summary_json, result):
            result["sidecar_write_failed"] = True
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
    # PIPE51: one publish view of the transcript (the Library's speaker names and
    # line edits applied), resolved once and handed to every sink.
    transcript_text = publish_text(transcript_md)

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
                transcript_text=transcript_text,
            )
            per_sink[p.name] = res
            events.emit("publisher", "sink_completed", sink=p.name, file=stem,
                        idempotent=bool(res.get("idempotent")))
        except Exception as e:  # noqa: BLE001
            log.error("sink %s failed: %s", p.name, e)
            from .failure_details import emit_failure
            failure = emit_failure(e, operation="publish", provider=p.name)
            per_sink[p.name] = {"error": str(e), "error_type": type(e).__name__, "failure": failure}
            if isinstance(e, SyncedTargetError):
                per_sink[p.name]["reason"] = e.reason
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
    if not _write_publish_sidecar(summary_json, out):
        # PIPE34: the sinks ran, but the outcome is not on disk, so the daemon would read the
        # `unknown` marker. That is a failed publish (exit 3): Republish records it, and each
        # sink that landed kept its own sidecar, so the retry updates rather than duplicates.
        out["sidecar_write_failed"] = True
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
    some failed, ``"none"`` when every sink failed or none of the configured ones
    ran, and ``"local"`` when no sink was configured at all (WF10: `fanout` marks
    that with ``no_sinks_configured``, since only it can see the resolved sink
    list). A failed sink is recorded in the per-sink map as a dict carrying an
    ``error`` key.

    The four values are a cross-tree vocabulary pinned by CI4's
    `publish-result-golden.json`; six Swift sites branch on the literals.
    """
    sinks = result.get("sinks") or {}
    if not sinks:
        return "local" if result.get("no_sinks_configured") else "none"
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


def publish_failed(result: dict[str, Any]) -> bool:
    """The exit-3 test every fanout caller applies (PIPE1, PIPE34): every sink failed, or the
    outcome could not be recorded in `<stem>.publish.json`, which leaves the daemon an
    `unknown` marker (or, if even that failed, nothing) instead of this run's result."""
    return all_sinks_failed(result) or bool(result.get("sidecar_write_failed"))


def publish_failure_reason(result: dict[str, Any]) -> str:
    """One line naming why `publish_failed` holds, for the caller's log and stderr."""
    if result.get("sidecar_write_failed") and not all_sinks_failed(result):
        return f"the publish outcome could not be recorded in {PUBLISH_SIDECAR_SUFFIX.lstrip('.')}"
    return "; ".join(f"{name}: {err}" for name, err in result.get("failures", [])) or "every sink failed"


def published_sinks(result: dict[str, Any]) -> list[str]:
    """The sinks that landed, by name, sorted: what the logs carry instead of ``page_url`` (SEC38).

    A note path or page address embeds the meeting title's slug, so it stays in
    ``<stem>.publish.json`` (the Library's link) and never reaches a log line.
    """
    sinks = result.get("sinks") or {}
    return sorted(name for name, r in sinks.items() if isinstance(r, dict) and not r.get("error"))


def publish_sidecar_path(summary_json: Path) -> Path:
    stem = summary_json.name.removesuffix(".summary.json")
    return summary_json.parent / f"{stem}{PUBLISH_SIDECAR_SUFFIX}"


def _write_pending_marker(summary_json: Path) -> bool:
    """Replace `<stem>.publish.json` with an `unknown` marker before any sink runs (PIPE34).

    True when the old outcome is gone: the marker landed, or it could not be written but
    the old file was removed. False only when neither happened, and the caller must not
    publish, since the outcome could not be recorded either way.
    """
    path = publish_sidecar_path(summary_json)
    payload = {
        "schema_version": PUBLISH_SIDECAR_SCHEMA_VERSION,
        "state": PUBLISH_STATE_UNKNOWN,
        "page_url": None,
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "sinks": {},
    }
    try:
        storage.atomic_write_text(path, json.dumps(payload, ensure_ascii=False, indent=2))
        return True
    except OSError as e:
        report_sidecar_write_failed("publish", e)
    try:
        path.unlink(missing_ok=True)
        return True
    except OSError as e:
        log.error("previous publish sidecar could not be removed either: %s", e)
        return False


def record_pre_sink_failure(summary_json: Path, sink_names: list[str], message: str) -> bool:
    """PIPE54: record a publish that stopped before any sink ran, because the summary on disk
    does not validate against `MeetingSummary`.

    `fanout` wrote the `unknown` pending marker and then raised on the parse, so without this the
    daemon reads `unknown`. Every resolved sink is recorded as failed with `message`, so the state
    is the existing `"none"` and nothing new enters the CI4 vocabulary. Returns whether it landed.
    """
    result = {
        "page_url": None,
        "sinks": {name: {"error": message, "error_type": "ValidationError"} for name in sink_names},
    }
    return _write_publish_sidecar(summary_json, result)


def _write_publish_sidecar(summary_json: Path, result: dict[str, Any]) -> bool:
    """Record this run's publish outcome next to the summary (PIPE1).

    Rewritten on every fanout, so the daemon reading it always sees the run that
    just finished. Atomic. Returns whether it landed: since PIPE34 a failed write is
    a failed publish, because what is left on disk is the pending marker `fanout`
    wrote first (`unknown`), not this run's outcome. The daemon degrades to "no page
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
                "failure": res.get("failure") if isinstance(res, dict) else None,
                # SEC18: present only on a failure that names a machine-readable cause
                # (`synced_target`); absent otherwise, so the CI4 golden shape is unchanged.
                **({"reason": res["reason"]} if isinstance(res, dict) and res.get("reason") else {}),
            }
            for name, res in sinks.items()
        },
    }
    path = publish_sidecar_path(summary_json)
    try:
        storage.atomic_write_text(path, json.dumps(payload, ensure_ascii=False, indent=2))
    except OSError as e:
        report_sidecar_write_failed("publish", e)
        return False
    return True
