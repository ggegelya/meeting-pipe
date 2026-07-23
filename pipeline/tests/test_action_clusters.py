"""AI7: near-duplicate clustering of a recurring series' action items.

The production embedder is MLX-only, so these drive `cluster_actions` through
explicit fakes (and the shipped `HashingEmbedder`, which is what CI would pick
anyway) rather than asserting on a model that is not installed on the runner.
"""
from __future__ import annotations

import json

import numpy as np
import pytest

from mp import action_clusters
from mp.actions import OpenAction, discover


def _action(stem: str, task: str, *, workflow: str | None = "Standup",
            owner: str | None = None) -> OpenAction:
    return OpenAction(
        stem=stem, title=stem, task=task, owner=owner, due=None,
        confidence="medium", workflow=workflow,
    )


class DirectedEmbedder:
    """Maps each task text to a caller-chosen unit vector, so a test states the
    similarity structure it wants instead of hoping a real model produces it."""

    name = "fake-directed"

    def __init__(self, vectors: dict[str, list[float]]) -> None:
        self.vectors = vectors

    def embed(self, texts, kind="passage"):  # noqa: ARG002 - Embedder protocol
        rows = np.array([self.vectors[t] for t in texts], dtype=np.float32)
        norms = np.linalg.norm(rows, axis=1, keepdims=True)
        norms[norms == 0.0] = 1.0
        return rows / norms


def test_restatements_in_one_workflow_group_together():
    actions = [
        _action("20260701-100000", "Send the roadmap deck to the team"),
        _action("20260708-100000", "Send the roadmap deck to the team"),
        _action("20260715-100000", "Book the venue for the offsite"),
    ]
    embedder = DirectedEmbedder({
        "Send the roadmap deck to the team": [1.0, 0.0],
        "Book the venue for the offsite": [0.0, 1.0],
    })
    ids = action_clusters.cluster_actions(actions, embedder=embedder, threshold=0.9)

    assert ids[0] == ids[1], "the same commitment restated must share a cluster"
    assert ids[2] != ids[0], "an unrelated commitment keeps its own cluster"
    assert sorted(set(ids)) == [0, 1], "cluster ids are contiguous from zero"


def test_similar_tasks_in_different_workflows_never_merge():
    """The workflow is the series key (AI6's rule): two meeting series that happen
    to phrase a commitment identically are still two commitments."""
    actions = [
        _action("20260701-100000", "Review the budget", workflow="Standup"),
        _action("20260702-100000", "Review the budget", workflow="Client sync"),
    ]
    embedder = DirectedEmbedder({"Review the budget": [1.0, 0.0]})
    ids = action_clusters.cluster_actions(actions, embedder=embedder, threshold=0.5)

    assert ids[0] != ids[1]


def test_untagged_meetings_are_always_singletons():
    """A meeting with no workflow has no series, so it has no restatements."""
    actions = [
        _action("20260701-100000", "Review the budget", workflow=None),
        _action("20260702-100000", "Review the budget", workflow=""),
    ]
    embedder = DirectedEmbedder({"Review the budget": [1.0, 0.0]})
    ids = action_clusters.cluster_actions(actions, embedder=embedder, threshold=0.5)

    assert ids[0] != ids[1]
    assert sorted(ids) == [0, 1]


def test_named_owners_gate_the_merge():
    """Semantic similarity alone would fold two people's identical promises into
    one; a mismatched named owner blocks it, an unattributed one does not."""
    actions = [
        _action("20260701-100000", "Send the deck", owner="Sam"),
        _action("20260708-100000", "Send the deck", owner="Alex"),
        _action("20260715-100000", "Send the deck", owner=None),
    ]
    embedder = DirectedEmbedder({"Send the deck": [1.0, 0.0]})
    ids = action_clusters.cluster_actions(actions, embedder=embedder, threshold=0.5)

    assert ids[0] != ids[1], "two named owners must not share a commitment"
    assert ids[2] == ids[0], "an unattributed restatement joins the first compatible cluster"


def test_owner_match_is_case_insensitive():
    actions = [
        _action("20260701-100000", "Send the deck", owner="Sam"),
        _action("20260708-100000", "Send the deck", owner=" sam "),
    ]
    embedder = DirectedEmbedder({"Send the deck": [1.0, 0.0]})
    ids = action_clusters.cluster_actions(actions, embedder=embedder, threshold=0.5)

    assert ids[0] == ids[1]


def test_below_threshold_stays_separate():
    actions = [
        _action("20260701-100000", "Send the deck"),
        _action("20260708-100000", "Cancel the vendor contract"),
    ]
    embedder = DirectedEmbedder({
        "Send the deck": [1.0, 0.0],
        "Cancel the vendor contract": [0.8, 0.6],   # cos = 0.8 against the first
    })
    assert action_clusters.cluster_actions(actions, embedder=embedder, threshold=0.9) == [0, 1]
    assert action_clusters.cluster_actions(actions, embedder=embedder, threshold=0.7) == [0, 0]


def test_embedder_failure_falls_back_to_singletons():
    """Fail-open: no embedder (MLX absent, or a cold fetch clamped under regulated
    mode) must leave every action visible and ungrouped, never drop one."""
    class Broken:
        name = "broken"

        def embed(self, texts, kind="passage"):  # noqa: ARG002 - Embedder protocol
            raise RuntimeError("no model")

    actions = [
        _action("20260701-100000", "Send the deck"),
        _action("20260708-100000", "Send the deck"),
    ]
    assert action_clusters.cluster_actions(actions, embedder=Broken()) == [0, 1]


def test_single_action_needs_no_embedder():
    """One action can have no restatement, so the model is never loaded."""
    class Exploding:
        name = "exploding"

        def embed(self, texts, kind="passage"):  # noqa: ARG002 - Embedder protocol
            raise AssertionError("embedder must not be called")

    assert action_clusters.cluster_actions(
        [_action("20260701-100000", "Send the deck")], embedder=Exploding()
    ) == [0]


def test_default_threshold_follows_the_embedder():
    """e5 and the hashing fallback sit on different similarity scales, so one
    constant cannot serve both."""
    assert action_clusters.default_threshold("hashing-512") == action_clusters.HASHING_THRESHOLD
    assert action_clusters.default_threshold(
        "mlx-community/multilingual-e5-small-mlx"
    ) == action_clusters.SEMANTIC_THRESHOLD


def test_hashing_embedder_groups_a_verbatim_restatement():
    """End-to-end on the backend CI actually has: a verbatim restatement (the
    common standup shape) groups under the shipped default threshold."""
    from mp.embed_index import HashingEmbedder

    actions = [
        _action("20260701-100000", "Follow up with legal on the MSA redlines"),
        _action("20260708-100000", "Follow up with legal on the MSA redlines"),
        _action("20260715-100000", "Order new laptops for the two new hires"),
    ]
    ids = action_clusters.cluster_actions(actions, embedder=HashingEmbedder())

    assert ids[0] == ids[1]
    assert ids[2] != ids[0]


# --- CLI surface -------------------------------------------------------------


@pytest.fixture
def library(tmp_path, monkeypatch):
    """A two-meeting Standup series restating one commitment, plus an untagged
    meeting. Returns the recordings dir."""
    monkeypatch.setattr("mp.entry.prepare", lambda *a, **k: None)

    def write(stem: str, tasks: list[dict], workflow: str | None) -> None:
        (tmp_path / f"{stem}.summary.json").write_text(
            json.dumps({"title": f"Meeting {stem}", "actions": tasks}), encoding="utf-8"
        )
        if workflow is not None:
            (tmp_path / f"{stem}.meta.json").write_text(
                json.dumps({"workflow_name": workflow}), encoding="utf-8"
            )

    write("20260701-100000", [{"task": "Follow up with legal on the MSA redlines"}], "Standup")
    write("20260708-100000", [{"task": "Follow up with legal on the MSA redlines"}], "Standup")
    write("20260715-100000", [{"task": "Order new laptops"}], None)
    return tmp_path


def test_discover_reads_the_workflow_from_the_meta_sidecar(library):
    by_stem = {a.stem: a for a in discover(library)}

    assert by_stem["20260701-100000"].workflow == "Standup"
    assert by_stem["20260715-100000"].workflow is None, "no sidecar reads as untagged"


def test_cli_out_writes_cluster_ids(library, tmp_path, capsys):
    from mp.actions import main

    out = tmp_path / "nested" / "clusters.json"
    assert main(["--open", "--cluster", "--dir", str(library), "--out", str(out)]) == 0
    assert capsys.readouterr().out == "", "--out writes the file instead of stdout"

    rows = json.loads(out.read_text(encoding="utf-8"))
    by_stem = {r["stem"]: r for r in rows}
    assert by_stem["20260701-100000"]["cluster"] == by_stem["20260708-100000"]["cluster"]
    assert by_stem["20260715-100000"]["cluster"] != by_stem["20260701-100000"]["cluster"]
    assert by_stem["20260701-100000"]["workflow"] == "Standup"


def test_cli_json_without_cluster_leaves_the_id_null(library, capsys):
    from mp.actions import main

    assert main(["--open", "--dir", str(library), "--json"]) == 0
    rows = json.loads(capsys.readouterr().out)

    assert rows, "the library has open actions"
    assert all(r["cluster"] is None for r in rows)


def test_cli_text_collapses_a_cluster_to_one_line(library, capsys):
    from mp.actions import main

    assert main(["--open", "--cluster", "--dir", str(library)]) == 0
    out = capsys.readouterr().out

    assert "2 open action item(s)" in out, "two clusters, not three instances"
    assert out.count("Follow up with legal on the MSA redlines") == 1
    assert "restated 2x" in out
    assert "[20260708-100000]" in out, "the newest restatement represents the series"
