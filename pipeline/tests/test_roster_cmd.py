"""FEAT3-ROSTER: the `mp roster` CLI (enroll / list / forget)."""
from __future__ import annotations

import json

from mp.roster import EMBEDDING_DIM, RosterStore
from mp.roster_cmd import main as roster_main


def _emb(seed: float = 1.0) -> list[float]:
    v = [0.0] * EMBEDDING_DIM
    v[0] = seed
    return v


def _write_meeting(tmp_path, *, stem: str = "20260601-0900", label: str = "THEM-A"):
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    (tmp_path / f"{stem}.json").write_text(
        json.dumps(
            {
                "language": "en",
                "segments": [
                    {"start": 0.0, "end": 2.0, "text": "hi", "speaker": label},
                    {"start": 2.0, "end": 3.0, "text": "me", "speaker": "Me"},
                ],
                "finalized": True,
            }
        ),
        encoding="utf-8",
    )
    (tmp_path / f"{stem}.md").write_text("# transcript\n", encoding="utf-8")
    (tmp_path / f"{stem}.embeddings.json").write_text(
        json.dumps({"schema_version": 1, "embeddings": {label: _emb(), "Me": _emb(0.5)}}),
        encoding="utf-8",
    )
    return wav


def test_enroll_adds_to_roster_and_relabels_transcript(tmp_path, monkeypatch):
    monkeypatch.setattr("mp.roster.ROSTER_PATH", tmp_path / "roster.json")
    wav = _write_meeting(tmp_path)
    assert roster_main(["enroll", "--name", "Alice", "--label", "THEM-A", "--wav", str(wav)]) == 0

    assert RosterStore(tmp_path / "roster.json").names() == ["Alice"]
    data = json.loads((wav.parent / f"{wav.stem}.json").read_text(encoding="utf-8"))
    assert [s["speaker"] for s in data["segments"]] == ["Alice", "Me"]
    emb = json.loads((wav.parent / f"{wav.stem}.embeddings.json").read_text(encoding="utf-8"))
    assert "Alice" in emb["embeddings"] and "THEM-A" not in emb["embeddings"]


def test_enroll_unknown_label_returns_error(tmp_path, monkeypatch):
    monkeypatch.setattr("mp.roster.ROSTER_PATH", tmp_path / "roster.json")
    wav = _write_meeting(tmp_path)
    assert roster_main(["enroll", "--name", "Alice", "--label", "THEM-Z", "--wav", str(wav)]) == 2
    assert RosterStore(tmp_path / "roster.json").names() == []


def test_list_and_forget(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr("mp.roster.ROSTER_PATH", tmp_path / "roster.json")
    wav = _write_meeting(tmp_path)
    roster_main(["enroll", "--name", "Alice", "--label", "THEM-A", "--wav", str(wav)])

    assert roster_main(["list"]) == 0
    assert "Alice" in capsys.readouterr().out
    assert roster_main(["forget", "--name", "Alice"]) == 0
    assert roster_main(["forget", "--name", "Nobody"]) == 1
