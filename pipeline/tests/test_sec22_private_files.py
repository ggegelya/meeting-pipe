"""SEC22: voiceprints and embeddings are written private, atomically, and can be forgotten."""
from __future__ import annotations

import ast
import json
import os
import re
import stat
from pathlib import Path

import pytest

from mp import orchestrate, storage
from mp.roster import EMBEDDING_DIM, RosterStore
from mp.roster_cmd import _relabel_transcript
from mp.roster_cmd import main as roster_main
from mp.voiceprint import VoiceprintStore


def _emb(seed: float = 1.0) -> list[float]:
    v = [0.0] * EMBEDDING_DIM
    v[0] = seed
    return v


def _mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


@pytest.fixture(autouse=True)
def _umask_022():
    old = os.umask(0o022)
    yield
    os.umask(old)


# ----- every biometric writer lands 0600 -----


def test_the_voiceprint_is_0600_in_a_0700_directory(tmp_path: Path) -> None:
    cfg = tmp_path / "meeting-pipe"
    VoiceprintStore(cfg / "voiceprint.json").update(_emb())
    assert _mode(cfg / "voiceprint.json") == 0o600
    assert _mode(cfg) == 0o700


def test_the_roster_is_0600_in_a_0700_directory(tmp_path: Path) -> None:
    cfg = tmp_path / "meeting-pipe"
    RosterStore(cfg / "roster.json").enroll("Alice", _emb())
    assert _mode(cfg / "roster.json") == 0o600
    assert _mode(cfg) == 0o700


def test_a_rewrite_keeps_0600(tmp_path: Path) -> None:
    store = RosterStore(tmp_path / "roster.json")
    store.enroll("Alice", _emb())
    store.enroll("Alice", _emb(0.9))
    store.rename("Alice", "Alicia")
    assert _mode(tmp_path / "roster.json") == 0o600


def test_an_existing_0755_config_dir_is_tightened(tmp_path: Path) -> None:
    cfg = tmp_path / "meeting-pipe"
    cfg.mkdir()
    cfg.chmod(0o755)
    RosterStore(cfg / "roster.json").enroll("Alice", _emb())
    assert _mode(cfg) == 0o700


def test_ensure_private_dir_creates_and_tightens(tmp_path: Path) -> None:
    new = storage.ensure_private_dir(tmp_path / "a" / "b")
    assert _mode(new) == 0o700
    loose = tmp_path / "loose"
    loose.mkdir()
    loose.chmod(0o755)
    storage.ensure_private_dir(loose)
    assert _mode(loose) == 0o700


def test_the_per_meeting_embeddings_sidecar_is_0600_at_creation(tmp_path: Path) -> None:
    wav = tmp_path / "20260601-0900.wav"
    wav.write_bytes(b"")
    orchestrate._write_embeddings_sidecar(wav, {"0": _emb()}, {"0": "THEM-A"}, {"THEM-A": "Bob"})
    path = tmp_path / "20260601-0900.embeddings.json"
    assert _mode(path) == 0o600
    assert json.loads(path.read_text())["embeddings"]["THEM-A"][0] == 1.0


def test_a_roster_rename_rewrites_the_transcript_pair_and_sidecar_0600(tmp_path: Path) -> None:
    wav = tmp_path / "20260601-0900.wav"
    wav.write_bytes(b"")
    for name, body in {
        "20260601-0900.json": json.dumps({"segments": [{"start": 0, "end": 1, "text": "hi", "speaker": "THEM-A"}]}),
        "20260601-0900.md": "# t\n",
        "20260601-0900.embeddings.json": json.dumps({"embeddings": {"THEM-A": _emb()}}),
    }.items():
        p = tmp_path / name
        p.write_text(body)
        p.chmod(0o644)
    _relabel_transcript(wav, "THEM-A", "Alice")
    for name in ("20260601-0900.json", "20260601-0900.md", "20260601-0900.embeddings.json"):
        assert _mode(tmp_path / name) == 0o600, name
    assert "Alice" in json.loads((tmp_path / "20260601-0900.embeddings.json").read_text())["embeddings"]


# ----- forget cascades into the meetings' embeddings -----


def _sidecar(lib: Path, stem: str, embeddings: dict, near: dict | None = None) -> Path:
    payload: dict = {"schema_version": 2, "embeddings": embeddings}
    if near:
        payload["near_misses"] = near
    p = lib / f"{stem}.embeddings.json"
    p.write_text(json.dumps(payload))
    return p


def test_forget_embeddings_strips_the_name_and_leaves_everything_else(tmp_path: Path) -> None:
    a = _sidecar(tmp_path, "m1", {"Alice": _emb(), "THEM-B": _emb(2)})
    b = _sidecar(tmp_path, "m2", {"Alice": _emb(), "Me": _emb(3)}, near={"THEM-C": "Alice", "THEM-D": "Zed"})
    c = _sidecar(tmp_path, "m3", {"Me": _emb(3)}, near={"THEM-X": "Zed"})
    untouched = c.read_bytes()

    assert RosterStore.forget_embeddings("Alice", tmp_path) == 2

    da, db = (json.loads(p.read_text()) for p in (a, b))
    assert set(da["embeddings"]) == {"THEM-B"}
    assert set(db["embeddings"]) == {"Me"} and db["near_misses"] == {"THEM-D": "Zed"}
    assert c.read_bytes() == untouched                       # a file without her is not rewritten
    assert _mode(a) == 0o600 and _mode(b) == 0o600


def test_forget_embeddings_drops_an_emptied_near_misses_and_skips_unreadable_files(tmp_path: Path) -> None:
    only = _sidecar(tmp_path, "m1", {"Me": _emb()}, near={"THEM-A": "Alice"})
    (tmp_path / "bad.embeddings.json").write_text("{nope")
    assert RosterStore.forget_embeddings("Alice", tmp_path) == 1
    assert "near_misses" not in json.loads(only.read_text())
    assert (tmp_path / "bad.embeddings.json").read_text() == "{nope"


def test_the_cli_forget_leaves_embeddings_unless_asked(tmp_path: Path, monkeypatch, capsys) -> None:
    """The daemon's Undo naming runs `forget`; it must keep the voices a re-name needs (FEAT24)."""
    monkeypatch.setattr("mp.roster.ROSTER_PATH", tmp_path / "roster.json")
    RosterStore(tmp_path / "roster.json").enroll("Alice", _emb())
    p = _sidecar(tmp_path, "m1", {"Alice": _emb()})
    before = p.read_bytes()
    assert roster_main(["forget", "--name", "Alice"]) == 0
    assert p.read_bytes() == before


def test_the_cli_purge_reports_the_count_and_emits_an_event(tmp_path: Path, monkeypatch, capsys) -> None:
    monkeypatch.setattr("mp.roster.ROSTER_PATH", tmp_path / "roster.json")
    RosterStore(tmp_path / "roster.json").enroll("Alice", _emb())
    p = _sidecar(tmp_path, "m1", {"Alice": _emb(), "Me": _emb(2)})
    emitted: list[tuple] = []
    monkeypatch.setattr("mp.events.emit", lambda cat, action, **kw: emitted.append((cat, action, kw)))
    assert roster_main(["forget", "--name", "Alice", "--purge-embeddings", "--library", str(tmp_path)]) == 0
    assert "embeddings removed from 1 meeting" in capsys.readouterr().out
    assert "Alice" not in json.loads(p.read_text())["embeddings"]
    assert emitted == [("pipeline", "roster_embeddings_forgotten", {"files": 1})]   # no name in the log


def test_purging_a_name_that_is_not_on_the_roster_still_cleans_the_meetings(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr("mp.roster.ROSTER_PATH", tmp_path / "roster.json")
    _sidecar(tmp_path, "m1", {"Alice": _emb()})
    assert roster_main(["forget", "--name", "Alice", "--purge-embeddings", "--library", str(tmp_path)]) == 0


# ----- the ratchet: a hand-rolled writer cannot appear (SEC22, PIPE30) -----
#
# One fence for both tasks (PIPE30 item 4): a temp-and-replace outside the
# helper, and a plain `.write_text(` to a library-suffixed path, each refused
# unless the file is on its allowlist with a reason.

_SRC = Path(__file__).resolve().parents[1] / "src" / "mp"
# A temp-file-then-rename write: `tmp.replace(`, `tmp_path.replace(`, `os.replace(`.
_HAND_ROLLED = re.compile(r"\b(?:tmp\w*|temp\w*)\.replace\(|\bos\.replace\(")
#: Files that still hand-roll one, each with its reason. Everything else goes
#: through `storage.atomic_write_text` (0600). Adding to this list needs a reason
#: that is not "it was easier": the biometric writers were here until SEC22.
_ALLOWED = {
    "storage.py": "the helper itself",
    "publish_lan.py": "files on a network share, whose modes are the share's (PIPE30 item 2)",
    "backup.py": "renames a finished archive: a binary file, modes are STOR8's",
    "merge_meetings.py": "renames an ffmpeg-merged audio file into place, not a text write",
    "restore.py": "renames each extracted archive member into place (STOR17): tarfile writes the temp",
}


def _offenders(root: Path) -> list[str]:
    return sorted(
        p.name for p in root.glob("*.py")
        if p.name not in _ALLOWED and _HAND_ROLLED.search(p.read_text(encoding="utf-8"))
    )


def test_no_new_hand_rolled_atomic_write_outside_the_allowlist() -> None:
    assert _offenders(_SRC) == [], (
        "hand-rolled temp-and-replace write; use storage.atomic_write_text (0600), "
        "or add the file to _ALLOWED with a reason"
    )


def test_every_allowlist_entry_still_hand_rolls_one() -> None:
    """A file that stopped hand-rolling leaves the list, so the list stays a
    statement of what is true rather than a pile of old permissions."""
    stale = sorted(
        name for name in _ALLOWED
        if not _HAND_ROLLED.search((_SRC / name).read_text(encoding="utf-8"))
    )
    assert stale == []


def test_the_fence_fails_on_a_planted_example(tmp_path: Path) -> None:
    (tmp_path / "voiceprint2.py").write_text(
        "tmp = path.with_name('x.tmp')\ntmp.write_text('x')\ntmp.replace(path)\n"
    )
    (tmp_path / "fine.py").write_text("storage.atomic_write_text(path, 'x')\n")
    assert _offenders(tmp_path) == ["voiceprint2.py"]


#: Suffixes of files that live in the library (or a sink's copy of one), where a
#: plain `write_text` truncates the only copy when it is killed mid-write.
_LIBRARY_SUFFIXES = (
    ".summary.json", ".summary.md", ".meta.json", ".publish.json", ".run.json",
    ".empty.json", ".notion.json", ".obsidian.json", ".filesystem.json", ".lan.json",
    ".transcript.md", ".actions.json", ".READY_FOR_MANUAL.md", ".apple_pending.json",
    ".embeddings.json", ".speaker_labels.json", ".transcript_corrections.json",
    "with_suffix('.json')", "with_suffix('.md')",
)
_WRITE_TEXT_ALLOWED = {
    "storage.py": "the helper itself",
    "publish_notion.py": "the <stem>.notion.json sidecar writer is PIPE23 scope item 4",
}


def _direct_library_writes(root: Path) -> list[str]:
    """`<file>:<line>` for every `X.write_text(` where X, or what X was assigned
    from in the same function, names a library suffix. An AST walk, so a
    user-named `--out` path (an argument, not a suffix) never matches."""
    hits: list[str] = []
    for path in sorted(root.glob("*.py")):
        if path.name in _WRITE_TEXT_ALLOWED:
            continue
        tree = ast.parse(path.read_text(encoding="utf-8"))
        for scope in ast.walk(tree):
            if not isinstance(scope, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Module)):
                continue
            assigned: dict[str, list[str]] = {}
            for node in ast.walk(scope):
                if isinstance(node, ast.Assign):
                    for target in node.targets:
                        if isinstance(target, ast.Name):
                            assigned.setdefault(target.id, []).append(ast.unparse(node.value))
            for node in ast.walk(scope):
                if not (
                    isinstance(node, ast.Call)
                    and isinstance(node.func, ast.Attribute)
                    and node.func.attr == "write_text"
                ):
                    continue
                receiver = node.func.value
                texts = [ast.unparse(receiver)]
                if isinstance(receiver, ast.Name):
                    texts += assigned.get(receiver.id, [])
                if any(suffix in text for text in texts for suffix in _LIBRARY_SUFFIXES):
                    hits.append(f"{path.name}:{node.lineno}")
    return sorted(set(hits))


def test_no_plain_write_text_to_a_library_file() -> None:
    assert _direct_library_writes(_SRC) == [], (
        "a plain write_text to a library file truncates the only copy when killed; "
        "use storage.atomic_write_text, or add the file to _WRITE_TEXT_ALLOWED with a reason"
    )


def test_the_write_text_fence_fails_on_a_planted_summary_write(tmp_path: Path) -> None:
    (tmp_path / "planted.py").write_text(
        "def f(root, stem, s):\n"
        "    out = root / f'{stem}.summary.json'\n"
        "    out.write_text(s)\n"
        "    (root / f'{stem}.meta.json').write_text(s)\n"
    )
    (tmp_path / "report.py").write_text(
        "def g(args, s):\n    args.out.write_text(s)\n"
    )
    assert _direct_library_writes(tmp_path) == ["planted.py:3", "planted.py:4"]
