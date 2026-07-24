"""Near-duplicate clustering of action items across a recurring series (AI7).

Recurring meetings restate the same commitments, so `<stem>.summary.json`
accumulates near-duplicates across a series: Facts and the digest list one
promise once per occurrence, and resolving a single instance leaves its clones
open. This groups the restatements so a repeated commitment reads, and resolves,
as one thing.

The series key is the **workflow**, the same explicit key AI6 uses for
recurring-series continuity: no fuzzy series inference, and an action on a
meeting with no workflow is always its own cluster. Within one workflow, task
texts are embedded with the on-device embedder `embed_index` already ships (MLX
multilingual-e5-small in production, the hashing fallback on CI) and merged
greedily against a running centroid.

Two guards keep the merge honest:

- **Owner compatibility is a hard gate.** Semantic similarity alone would fold
  "Sam sends the deck" into "Alex sends the deck"; two actions merge only when
  their owners match case-insensitively or at least one is unattributed.
- **The threshold follows the embedder.** e5 similarities sit high and
  compressed (unrelated short sentences still score ~0.8), while the hashing
  fallback is lexical overlap on a much wider scale, so one constant cannot
  serve both. `default_threshold` picks per backend.

Fully on-device and fail-open: when no embedder can run (MLX absent, or a cold
model fetch blocked by the egress guard under regulated mode) every action falls
back to a singleton cluster, so a caller never loses actions to a clustering
failure. Over-merging is the expensive error here (it silently resolves an
unrelated commitment), so both defaults sit on the conservative side.
"""
from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:  # pragma: no cover - import cycle: actions imports this lazily
    from .actions import OpenAction

log = logging.getLogger("mp.action_clusters")

# Cosine floor for "the same commitment, restated". Keyed by embedder family
# because the two backends live on different similarity scales; see the module
# docstring. Deliberately conservative: an under-merge leaves a duplicate row,
# an over-merge resolves something the owner never finished.
SEMANTIC_THRESHOLD = 0.90
HASHING_THRESHOLD = 0.72


def default_threshold(embedder_name: str) -> float:
    """The cosine floor to use for `embedder_name`. `HashingEmbedder` names
    itself `hashing-<dim>`; everything else is a real semantic model."""
    return HASHING_THRESHOLD if embedder_name.startswith("hashing-") else SEMANTIC_THRESHOLD


def _owners_compatible(a: str | None, b: str | None) -> bool:
    """True when two actions may belong to the same commitment. An unattributed
    action is compatible with anything; two named owners must be the same person."""
    left = (a or "").strip().lower()
    right = (b or "").strip().lower()
    return not left or not right or left == right


def _series_groups(actions: list["OpenAction"]) -> dict[str, list[int]]:
    """Indices bucketed by workflow, keeping only the workflows with something to
    merge. An action with no workflow has no series, so it never enters a bucket."""
    groups: dict[str, list[int]] = {}
    for i, a in enumerate(actions):
        key = (a.workflow or "").strip()
        if key:
            groups.setdefault(key, []).append(i)
    return {wf: idxs for wf, idxs in groups.items() if len(idxs) > 1}


def cluster_actions(
    actions: list["OpenAction"],
    *,
    threshold: float | None = None,
    embedder: Any | None = None,
) -> list[int]:
    """Assign each action a cluster id, parallel to `actions`.

    Ids are contiguous from 0 and unique per cluster; an action that merges with
    nothing gets its own. `threshold` overrides the embedder-derived default.
    Deterministic for a given input order (`discover` sorts by stem), so a repeat
    run over an unchanged library returns the same grouping.
    """
    assigned: list[int | None] = [None] * len(actions)
    groups = _series_groups(actions)
    if groups:
        try:
            # Heavy + darwin-only in production: keep it out of the import path of
            # every `mp actions` run (the pipeline's lazy-import contract).
            import numpy as np

            from .embed_index import default_embedder

            emb = embedder if embedder is not None else default_embedder()
            flat = [i for idxs in groups.values() for i in idxs]
            vectors = emb.embed([actions[i].task.strip() for i in flat], kind="passage")
        except Exception as e:  # noqa: BLE001 - fail-open, see the module docstring
            log.warning("action clustering unavailable (%s); leaving actions ungrouped", e)
            return list(range(len(actions)))

        floor = threshold if threshold is not None else default_threshold(
            str(getattr(emb, "name", ""))
        )
        row_of = {idx: row for row, idx in enumerate(flat)}
        next_id = 0
        for idxs in groups.values():
            centroids: list[Any] = []
            owners: list[str | None] = []
            members: list[list[int]] = []
            for idx in idxs:
                vec = vectors[row_of[idx]]
                best, best_sim = -1, -1.0
                for c, centroid in enumerate(centroids):
                    if not _owners_compatible(owners[c], actions[idx].owner):
                        continue
                    sim = float(centroid @ vec)
                    if sim > best_sim:
                        best, best_sim = c, sim
                if best >= 0 and best_sim >= floor:
                    members[best].append(idx)
                    # Running mean, re-normalized so the next cosine stays a cosine.
                    size = len(members[best])
                    centroid = centroids[best] * ((size - 1) / size) + vec / size
                    norm = float(np.linalg.norm(centroid)) or 1.0
                    centroids[best] = centroid / norm
                    # An unattributed member never widens the cluster's owner; a
                    # named one pins a cluster that had none.
                    if not (owners[best] or "").strip():
                        owners[best] = actions[idx].owner
                else:
                    centroids.append(vec)
                    owners.append(actions[idx].owner)
                    members.append([idx])
            for group_members in members:
                for idx in group_members:
                    assigned[idx] = next_id
                next_id += 1

    # Everything the series pass did not touch is its own cluster.
    next_free = max((c for c in assigned if c is not None), default=-1) + 1
    for i, c in enumerate(assigned):
        if c is None:
            assigned[i] = next_free
            next_free += 1
    return [c for c in assigned if c is not None]
