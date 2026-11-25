"""`mp prefetch-model <repo_id>` -- pre-download a HuggingFace MLX model.

Used by the daemon when the user switches `summarization.backend` to
"local" or "auto" so the first meeting does not appear stuck for
several minutes downloading. Without this, `mlx_lm.server` blocks
on its first model load while the HF download runs invisibly inside
the subprocess.

Output: one JSON object per line on stdout. The daemon's
ModelDownloadSupervisor reads this stream and surfaces progress in
the menu bar. Schema:

    {"event":"started",  "repo_id":"...", "total_bytes":N, "cached_bytes":N}
    {"event":"progress", "repo_id":"...", "downloaded_bytes":N, "total_bytes":N, "percent":0.42}
    {"event":"complete", "repo_id":"...", "path":"/.../snapshots/<hash>"}
    {"event":"failed",   "repo_id":"...", "error":"...", "error_type":"..."}

Same events are mirrored to ``~/Library/Logs/MeetingPipe/pipeline_events.jsonl``
(category="prefetch") via ``mp.events.emit``.

Idempotent. If the model is already fully cached, emits one
``started`` with `total_bytes == cached_bytes`, then jumps straight
to ``complete``. The daemon's "is the model cached" check is the
authoritative one; this command just always-runs and short-circuits.

This is the one command that deliberately does not arm the egress guard
(SEC13): downloading a model is the whole point, and a cached model is what
lets a later regulated / NDA run stay offline. `summarize_local._spawn` fails
closed with a pointer here when a zero-egress run meets an uncached model.
"""
from __future__ import annotations

import argparse
import json
import logging
import sys
import threading
import time
from pathlib import Path
from typing import Any

from . import entry, events, local_snapshot, storage

log = logging.getLogger("mp.prefetch_model")


def _emit(event: str, repo_id: str, **attrs: Any) -> None:
    """Write one JSON line to stdout AND the JSONL event log.

    stdout is the live channel the daemon tails. `events.jsonl` is the
    historical record so a postmortem can replay why a download failed.
    """
    record: dict[str, Any] = {"event": event, "repo_id": repo_id, **attrs}
    sys.stdout.write(json.dumps(record, sort_keys=True) + "\n")
    sys.stdout.flush()
    events.emit("prefetch", event, repo_id=repo_id, **attrs)


def hf_cache_dir(repo_id: str) -> Path:
    """HuggingFace caches at `~/.cache/huggingface/hub/models--<sanitized>/`.
    Sanitisation replaces `/` with `--` per huggingface_hub conventions."""
    return local_snapshot.hf_cache_dir(repo_id)


def model_is_cached(repo_id: str) -> bool:
    """Whether `repo_id` has weights on disk already, i.e. whether a load can
    succeed with the network off. Deliberately coarse: it answers "is there a
    downloaded snapshot here", not "is it the current revision", because the
    caller (SEC13's zero-egress spawn gate) only needs to know whether going
    offline will strand the model load."""
    snapshots = hf_cache_dir(repo_id) / "snapshots"
    return snapshots.is_dir() and any(snapshots.iterdir())


def _incremental_bytes(path: Path, counted: dict[str, int]) -> int:
    """Running byte total under `path`, statting only files not yet measured or
    still in progress. `counted` (path -> size) is mutated in place so a later
    tick reuses a finished file's size instead of re-statting the whole tree
    every 2 s during a multi-GB download (HYG1). A finished blob's size is
    stable; only HF's in-progress `*.incomplete` blobs keep getting statted.
    """
    if not path.exists():
        return 0
    seen: set[str] = set()
    for p in path.rglob("*"):
        key = str(p)
        seen.add(key)
        if key in counted and not key.endswith(".incomplete"):
            continue
        try:
            if p.is_file() and not p.is_symlink():
                counted[key] = p.stat().st_size
        except OSError:
            continue
    # Drop vanished entries (an `.incomplete` renamed on completion) so a
    # finished blob is never counted under both its temp and final name.
    for stale in counted.keys() - seen:
        del counted[stale]
    return sum(counted.values())


def _repo_metadata(
    repo_id: str, revision: str | None = None
) -> tuple[int | None, str | None]:
    """Best-effort (expected_on_disk_bytes, resolved_commit_sha) via the HF API.

    `revision` (SEC27) asks about that exact commit rather than the live `main`:
    a pinned model is sized and downloaded at its pin, so the answer cannot
    change under us.

    Both None when the call fails (no network, private repo without auth,
    huggingface_hub missing) so the caller falls back to a no-total progress
    mode and the default (unpinned) download. The sha lets the download pin to
    exactly the revision we inspected: a bare `snapshot_download` resolves the
    mutable `main` branch at download time, so the bytes fetched can differ from
    what was checked (SEC11)."""
    try:
        from huggingface_hub import HfApi  # pyright: ignore[reportMissingImports]
    except ImportError:
        return None, None
    try:
        info = HfApi().repo_info(repo_id, revision=revision, files_metadata=True)
    except Exception as e:  # noqa: BLE001
        log.warning("HfApi().repo_info failed: %s", e)
        return None, None
    total = 0
    # `repo_info` is typed as a Model/Dataset/Space union; only the model variant
    # declares `siblings`, and we only ever pass model repo ids.
    for sib in (getattr(info, "siblings", None) or []):
        # `size` is bytes per file when files_metadata=True; can be
        # None if the file lives in LFS without size metadata.
        if sib.size is not None:
            total += sib.size
    return (total or None), getattr(info, "sha", None)


def _snapshot_in_place(repo_id: str, revision: str | None) -> bool:
    """Is the snapshot this run is meant to leave behind already servable?

    Bytes on disk alone (the old test) said "complete" for a cache holding some
    other revision, which then failed the offline load (SEC27)."""
    if revision is None:
        return False
    path = local_snapshot.hf_cache_dir(repo_id) / "snapshots" / revision
    try:
        local_snapshot.verify_snapshot(path)
    except local_snapshot.SnapshotError:
        return False
    return True


def _record_custom_pin(repo_id: str, pinned: str | None, revision: str | None) -> None:
    """Remember the sha a custom model resolved to; a preset needs no record."""
    if pinned is not None or revision is None:
        return
    try:
        local_snapshot.record_pin(repo_id, revision)
    except (OSError, ValueError) as e:
        log.warning("could not record the revision pin for %s: %s", repo_id, e)


def prefetch(repo_id: str) -> int:
    """Download `repo_id` to the HF cache, emitting JSONL progress.

    Returns the process exit code. 0 = success or already-cached,
    1 = failure (also emits a `failed` event before returning).
    """
    cache_dir = hf_cache_dir(repo_id)
    # SEC27: a preset downloads its reviewed pin, never whatever `main` is today.
    # A custom model resolves `main` once, here, and the sha is recorded on
    # success so serving never has to resolve it again.
    pinned = local_snapshot.PINNED_REVISIONS.get(repo_id)
    total_bytes, resolved = _repo_metadata(repo_id, revision=pinned)
    revision = pinned or resolved
    cached_bytes = storage.bytes_on_disk(cache_dir)

    _emit(
        "started",
        repo_id,
        total_bytes=total_bytes if total_bytes is not None else 0,
        cached_bytes=cached_bytes,
        revision=revision or "main",
    )

    # Already fully cached: emit one progress (so the UI can show 100%)
    # then complete immediately. Repeat call after a successful prior
    # download is ~free.
    if (
        total_bytes is not None
        and cached_bytes >= total_bytes
        and _snapshot_in_place(repo_id, revision)
    ):
        _record_custom_pin(repo_id, pinned, revision)
        _emit(
            "complete",
            repo_id,
            path=str(cache_dir),
            cached_bytes=cached_bytes,
            total_bytes=total_bytes,
            revision=revision or "main",
        )
        return 0

    try:
        from huggingface_hub import snapshot_download  # pyright: ignore[reportMissingImports]
    except ImportError:
        _emit(
            "failed",
            repo_id,
            error="huggingface_hub not installed; reinstall the pipeline venv",
            error_type="ImportError",
        )
        return 1

    # Run the actual download on a worker thread so this thread can
    # poll the cache directory for progress reporting. snapshot_download
    # itself does not surface byte-level callbacks portably across
    # huggingface_hub versions; directory polling is the lowest-common-
    # denominator approach that works on every release.
    result_holder: dict[str, Any] = {"path": None, "error": None, "error_type": None}

    def _download() -> None:
        try:
            # revision pins to the sha resolved above; None falls back to the
            # library default (main) so an offline / metadata-less repo still works.
            # `ignore_patterns` (SEC27): a model snapshot never needs Python, and
            # mlx-lm would execute a `model_file` it found there.
            path = snapshot_download(
                repo_id, revision=revision, tqdm_class=None, ignore_patterns=["*.py"]
            )
            result_holder["path"] = path
        except Exception as e:  # noqa: BLE001
            result_holder["error"] = str(e)
            result_holder["error_type"] = type(e).__name__

    worker = threading.Thread(target=_download, daemon=True)
    worker.start()

    # Poll loop: emit a progress event every ~2 seconds until the
    # download thread exits. Cap on no-op events so a hung download
    # eventually times out at the daemon end (the daemon is the
    # supervising layer, not us).
    counted: dict[str, int] = {}
    last_emit = 0.0
    while worker.is_alive():
        time.sleep(2)
        now_bytes = _incremental_bytes(cache_dir, counted)
        # Throttle: only emit if either bytes grew OR 10s passed since
        # the last event (so the daemon's UI still ticks).
        if now_bytes > cached_bytes or (time.monotonic() - last_emit) > 10:
            cached_bytes = now_bytes
            percent = (cached_bytes / total_bytes) if total_bytes else 0.0
            _emit(
                "progress",
                repo_id,
                downloaded_bytes=cached_bytes,
                total_bytes=total_bytes if total_bytes is not None else 0,
                percent=round(percent, 4),
            )
            last_emit = time.monotonic()

    worker.join()

    if result_holder["error"] is not None:
        _emit(
            "failed",
            repo_id,
            error=result_holder["error"],
            error_type=result_holder["error_type"],
        )
        return 1

    # SEC27: refuse to call a snapshot complete that the server would refuse to
    # serve (code in the repo, no weights), instead of surfacing that later, at
    # the first meeting, as an opaque startup failure.
    snapshot_path = Path(str(result_holder["path"]))
    try:
        local_snapshot.verify_snapshot(snapshot_path)
    except local_snapshot.SnapshotError as e:
        _emit("failed", repo_id, error=str(e), error_type=type(e).__name__)
        return 1
    # No metadata (offline, private repo) means no sha up front; the snapshot
    # directory the download landed in is named by the sha it resolved.
    _record_custom_pin(repo_id, pinned, revision or snapshot_path.name)

    final_bytes = storage.bytes_on_disk(cache_dir)
    _emit(
        "complete",
        repo_id,
        path=str(result_holder["path"]),
        cached_bytes=final_bytes,
        total_bytes=total_bytes if total_bytes is not None else final_bytes,
        revision=revision or "main",
    )
    return 0


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="mp prefetch-model",
        description="Pre-download a HuggingFace MLX model with progress reporting.",
    )
    p.add_argument("repo_id", help="HuggingFace repo id, e.g. mlx-community/Qwen2.5-3B-Instruct-4bit")
    args = p.parse_args(argv)

    entry.configure_logging()  # stderr, so stdout stays a pure JSONL stream
    return prefetch(args.repo_id)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
