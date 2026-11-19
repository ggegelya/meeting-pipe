"""Pinned, offline model snapshots for the local summarizer (SEC27).

`mlx_lm.server` used to be handed a bare Hugging Face repo id. With the network
up it then re-resolved the repo's `main` branch on every start and fetched any
file it was missing, `*.py` included, so a commit to an open community repo ran
on the owner's Mac at the next server start. Worse, mlx-lm's `load_model` will
`exec_module` a file named by `config.json`'s `model_file` key whatever
`trust_remote_code` says.

This module is the other half of the fix. Serving never talks to Hugging Face:

- every shipped preset carries a reviewed commit sha (`PINNED_REVISIONS`);
- `mp prefetch-model` downloads exactly that sha, never `*.py`, and records the
  sha it resolved for a custom model in `local-model-pins.json` (once, at
  prefetch time, never again at serve time);
- the server is started on the resolved `snapshots/<sha>` directory, offline,
  and refuses a snapshot that carries code (`verify_snapshot`).

Stdlib only: the shim (`local_model_server`) imports this before `mlx_lm`.
"""
from __future__ import annotations

import json
import logging
import os
import re
from pathlib import Path

from . import storage

log = logging.getLogger("mp.local_snapshot")

#: Reviewed commit per curated preset (`resource_guard.PRESETS`, mirrored by
#: `LocalModelPreset.all` in the daemon). Looked up from the Hub on 2026-11-16;
#: the 3B sha is the snapshot already in the owner's cache. Bumping one is a
#: deliberate act: review the diff of the repo between the two commits first.
PINNED_REVISIONS: dict[str, str] = {
    "mlx-community/Qwen2.5-3B-Instruct-4bit": "4f83f8f146fdf28b512a06562b671d7af4fab457",
    "mlx-community/Qwen2.5-7B-Instruct-4bit": "c26a38f6a37d0a51b4e9a1eb3026530fa35d9fed",
    "mlx-community/Qwen2.5-14B-Instruct-4bit": "dad510143ae5cdb1466778bde3161460f9e9f604",
}

PINS_FILE_NAME = "local-model-pins.json"

#: Names that are code or load as code (`spec_from_file_location` takes any of them).
_CODE_SUFFIXES = (".py", ".pyc", ".so", ".dylib")

_SHA_RE = re.compile(r"^[0-9a-f]{40}$")

#: The phrase Swift's `Meeting.failureSuggestsModelDownload` matches (UX21), so
#: the Library offers an in-app Download instead of the terminal command.
NOT_CACHED_PHRASE = "not in the local HuggingFace cache"


class SnapshotError(RuntimeError):
    """The model cannot be served from a pinned local snapshot."""


class SnapshotMissing(SnapshotError):
    """No pinned snapshot on disk; `mp prefetch-model` is the fix."""


class SnapshotRefused(SnapshotError):
    """The snapshot carries code or is not a loadable MLX model."""


def pins_path(home: Path | None = None) -> Path:
    return storage.app_support_dir(home) / PINS_FILE_NAME


def hf_cache_dir(repo_id: str, home: Path | None = None) -> Path:
    """`<hub>/models--<repo with / as -->`, the layout huggingface_hub writes.

    With no injected `home` it honours `HF_HUB_CACHE` then `HF_HOME`, as
    `snapshot_download` does, so a prefetch and a serve can never look in
    different places."""
    hub = storage.hf_hub_root(home)
    if home is None:
        if os.environ.get("HF_HUB_CACHE"):
            hub = Path(os.environ["HF_HUB_CACHE"])
        elif os.environ.get("HF_HOME"):
            hub = Path(os.environ["HF_HOME"]) / "hub"
    return hub / ("models--" + repo_id.replace("/", "--"))


def _read_pins(home: Path | None) -> dict[str, str]:
    try:
        data = json.loads(pins_path(home).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {
        k: v for k, v in data.items()
        if isinstance(k, str) and isinstance(v, str) and _SHA_RE.match(v)
    }


def record_pin(repo_id: str, sha: str, home: Path | None = None) -> None:
    """Remember the sha a custom model was prefetched at. A preset never needs
    this (its pin is in code). Atomic 0600 write; raises `OSError`."""
    if not _SHA_RE.match(sha):
        raise ValueError(f"not a full commit sha: {sha!r}")
    pins = _read_pins(home)
    pins[repo_id] = sha
    path = pins_path(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    storage.atomic_write_text(path, json.dumps(pins, indent=2, sort_keys=True))


def pin_for(repo_id: str, home: Path | None = None) -> str | None:
    """The sha `repo_id` is served at: the code-pinned one for a preset, else the
    one `mp prefetch-model` recorded for a custom model, else None."""
    return PINNED_REVISIONS.get(repo_id) or _read_pins(home).get(repo_id)


def snapshot_dir(repo_id: str, home: Path | None = None) -> Path | None:
    """Where the pinned snapshot of `repo_id` lives (it may not exist), or None
    when there is no pin to look for.

    A custom model with no recorded pin falls back to its only snapshot
    directory, if there is exactly one: a model prefetched before SEC27, read
    off disk, never resolved over the network. Two or more is ambiguous (an
    earlier unpinned run fetched a newer `main`), so the answer is None and the
    owner re-runs `mp prefetch-model`, which records a pin."""
    base = hf_cache_dir(repo_id, home)
    pin = pin_for(repo_id, home)
    if pin is not None:
        return base / "snapshots" / pin
    snaps = base / "snapshots"
    try:
        found = [p for p in snaps.iterdir() if p.is_dir()]
    except OSError:
        return None
    if len(found) == 1:
        log.warning(
            "%s has no recorded revision pin; serving its only cached snapshot %s. "
            "Run `mp prefetch-model %s` to record one.",
            repo_id, found[0].name, repo_id,
        )
        return found[0]
    return None


def verify_snapshot(path: Path) -> None:
    """Raise `SnapshotRefused` unless `path` is a plain MLX weights directory.

    Refuses `config.json` naming a `model_file` (mlx-lm `exec_module`s it), an
    `auto_map`, and any `.py` / `.pyc` / `.so` / `.dylib` anywhere in the tree. Walks without following symlinks, so a
    link inside the snapshot cannot hide a file from the scan; the files a HF
    snapshot links to live in `blobs/`, which is not served."""
    config = path / "config.json"
    try:
        cfg = json.loads(config.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise SnapshotRefused(f"{path}: config.json is missing or unreadable ({e})") from e
    if not isinstance(cfg, dict):
        raise SnapshotRefused(f"{path}: config.json is not a JSON object")
    if "model_file" in cfg:
        raise SnapshotRefused(
            f"{path}: config.json names a model_file, which mlx-lm would execute; refusing to serve it"
        )
    # `auto_map` is how a repo asks transformers for its own code. Serving never
    # sets trust_remote_code, so it could only fail later; refuse it here.
    for name in ("config.json", "tokenizer_config.json"):
        try:
            data = json.loads((path / name).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(data, dict) and "auto_map" in data:
            raise SnapshotRefused(f"{path}: {name} declares auto_map (custom code); refusing to serve it")
    has_weights = False
    for _root, dirs, files in os.walk(path, followlinks=False):
        for name in (*dirs, *files):
            if name.lower().endswith(_CODE_SUFFIXES):
                raise SnapshotRefused(
                    f"{path}: contains {name!r}; a model snapshot with Python files is refused"
                )
        has_weights = has_weights or any(f.endswith(".safetensors") for f in files)
    if not has_weights:
        raise SnapshotRefused(f"{path}: no .safetensors weights")


def resolve_for_serving(repo_id: str, home: Path | None = None) -> Path:
    """The verified snapshot directory to hand `--model`, or a typed refusal.

    `SnapshotMissing` carries the UX21 phrase and the exact prefetch command, so
    the Library's "Download model" affordance fires on it."""
    path = snapshot_dir(repo_id, home)
    if path is None or not path.is_dir():
        wanted = pin_for(repo_id, home)
        at = f" at revision {wanted[:12]}" if wanted else ""
        raise SnapshotMissing(
            f"Model {repo_id!r}{at} is {NOT_CACHED_PHRASE}, and the local server "
            f"only serves a pinned offline snapshot. Download it first:\n"
            f"    mp prefetch-model {repo_id}"
        )
    verify_snapshot(path)
    return path


def snapshot_is_cached(repo_id: str, home: Path | None = None) -> bool:
    """Is a servable pinned snapshot on disk? Needs no `refs/main`, which a
    sha-pinned prefetch never writes."""
    try:
        resolve_for_serving(repo_id, home)
    except SnapshotError:
        return False
    return True


def repo_id_from_snapshot(path: str) -> str | None:
    """Inverse of `snapshot_dir`: `.../models--a--b/snapshots/<sha>` -> `a/b`.
    None for any other path (a custom local directory), so callers keep the
    string as it was."""
    p = Path(path)
    if p.parent.name != "snapshots":
        return None
    name = p.parent.parent.name
    if not name.startswith("models--"):
        return None
    return name[len("models--"):].replace("--", "/", 1) if "--" in name[len("models--"):] else None
