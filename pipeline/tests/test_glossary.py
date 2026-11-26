"""Tests for the post-ASR glossary (ASR1).

Cover the exact substitution contract (case-insensitive, whole-word,
Unicode/Cyrillic-aware, longest-match-first), the per-workflow merge, the
opt-in fuzzy stage, and the orchestrate wiring that rewrites the finalized
transcript json + md.
"""
from __future__ import annotations

import json
from pathlib import Path

from mp.glossary import Glossary, load_glossary

# --- exact substitution -----------------------------------------------------

def test_exact_is_case_insensitive_and_whole_word():
    g = Glossary(terms={"kubernetes": "Kubernetes"})
    out, exact, fuzzy = g.apply("We run KUBERNETES and kubernetes, not kubernetesish.")
    assert out == "We run Kubernetes and Kubernetes, not kubernetesish."
    assert exact == 2
    assert fuzzy == 0


def test_longest_match_wins():
    g = Glossary(terms={"acme": "ACME", "acme corp": "ACME Corp"})
    assert g.apply("acme corp shipped")[0] == "ACME Corp shipped"
    assert g.apply("acme shipped")[0] == "ACME shipped"


def test_cyrillic_word_boundaries():
    # A Cyrillic key must match a whole Cyrillic word but not a longer one.
    g = Glossary(terms={"кубернетес": "Kubernetes"})
    assert g.apply("это кубернетес, да")[0] == "это Kubernetes, да"
    assert g.apply("кубернетесный кластер")[0] == "кубернетесный кластер"


def test_replacement_is_canonical_regardless_of_input_case():
    g = Glossary(terms={"post gres": "PostgreSQL"})
    assert g.apply("Post Gres is fast")[0] == "PostgreSQL is fast"


def test_empty_glossary_is_falsy_and_noop():
    g = Glossary()
    assert not g
    assert g.apply("nothing changes") == ("nothing changes", 0, 0)


# --- fuzzy stage ------------------------------------------------------------

def test_fuzzy_off_by_default():
    g = Glossary(terms={"kubernetes": "Kubernetes"})
    # "kubernetis" is edit-distance 1 from the canonical, but fuzzy is disabled.
    assert g.apply("we deployed kubernetis today") == ("we deployed kubernetis today", 0, 0)


def test_fuzzy_corrects_near_miss_when_enabled():
    g = Glossary(terms={"kubernetes": "Kubernetes"}, fuzzy_enabled=True, fuzzy_max_distance=1)
    out, exact, fuzzy = g.apply("we deployed kubernetis today")
    assert out == "we deployed Kubernetes today"
    assert (exact, fuzzy) == (0, 1)


def test_fuzzy_leaves_distant_words_alone():
    g = Glossary(terms={"grafana": "Grafana"}, fuzzy_enabled=True, fuzzy_max_distance=1)
    assert g.apply("the banana was ripe")[0] == "the banana was ripe"


def test_fuzzy_ignores_short_names():
    # "aws" (len 3) is below the fuzzy floor, so "avs" is not corrected.
    g = Glossary(terms={"aws": "AWS"}, fuzzy_enabled=True, fuzzy_max_distance=1)
    assert g.apply("the avs bucket")[0] == "the avs bucket"


# --- load_glossary + per-workflow merge -------------------------------------

def _write_glossary(tmp_path: Path, body: str) -> Path:
    p = tmp_path / "glossary.toml"
    p.write_text(body, encoding="utf-8")
    return p


def test_missing_file_is_noop(tmp_path: Path):
    g = load_glossary(path=tmp_path / "nope.toml")
    assert not g


def test_malformed_file_is_noop(tmp_path: Path):
    p = _write_glossary(tmp_path, "this is not = valid = toml")
    assert not load_glossary(path=p)


def test_global_terms_load(tmp_path: Path):
    p = _write_glossary(tmp_path, '[terms]\n"foo" = "Foo Corp"\n')
    g = load_glossary(path=p)
    assert g.apply("foo rocks")[0] == "Foo Corp rocks"


def test_per_workflow_overrides_global(tmp_path: Path):
    p = _write_glossary(
        tmp_path,
        '[terms]\n"foo" = "GlobalFoo"\n\n[workflow."Client X".terms]\n"foo" = "ClientFoo"\n',
    )
    # Without a workflow, the global value applies.
    assert load_glossary(path=p).apply("foo")[0] == "GlobalFoo"
    # With the workflow, its value wins on the clash.
    assert load_glossary(path=p, workflow_name="Client X").apply("foo")[0] == "ClientFoo"


def test_workflow_name_resolved_from_meta_sidecar(tmp_path: Path):
    p = _write_glossary(tmp_path, '[workflow."Weekly Sync".terms]\n"standup" = "Stand-up"\n')
    stem = "20260707-1000"
    (tmp_path / f"{stem}.meta.json").write_text(
        json.dumps({"workflow_name": "Weekly Sync"}), encoding="utf-8"
    )
    wav = tmp_path / f"{stem}.wav"
    g = load_glossary(wav, path=p)
    assert g.apply("the standup ran long")[0] == "the Stand-up ran long"


WF11_ID = "6F1C2B9A-0D3E-4F5A-9B8C-7D6E5F4A3B2C"


def _workflow_dir(tmp_path: Path, monkeypatch, name: str) -> None:
    import mp.workflows as workflows_mod

    wdir = tmp_path / "workflows"
    wdir.mkdir()
    (wdir / f"{WF11_ID}.toml").write_text(f'id = "{WF11_ID}"\nname = "{name}"\n', encoding="utf-8")
    monkeypatch.setattr(workflows_mod, "WORKFLOWS_DIR", wdir)


def _meeting(tmp_path: Path, meta: dict) -> Path:
    stem = "20260707-1100"
    (tmp_path / f"{stem}.meta.json").write_text(json.dumps(meta), encoding="utf-8")
    return tmp_path / f"{stem}.wav"


def test_wf11_a_renamed_workflows_meeting_finds_its_moved_table_by_id(tmp_path: Path, monkeypatch):
    """The meeting recorded "Weekly Sync"; the workflow is now "Team Sync" and its
    table moved with the rename. The sidecar's id resolves to the current name."""
    _workflow_dir(tmp_path, monkeypatch, "Team Sync")
    p = _write_glossary(tmp_path, '[workflow."Team Sync".terms]\n"standup" = "Stand-up"\n')
    wav = _meeting(tmp_path, {"workflow_id": WF11_ID.lower(), "workflow_name": "Weekly Sync"})
    assert load_glossary(wav, path=p).apply("the standup ran long")[0] == "the Stand-up ran long"


def test_wf11_an_unknown_or_absent_id_falls_back_to_the_recorded_name(tmp_path: Path, monkeypatch):
    _workflow_dir(tmp_path, monkeypatch, "Team Sync")
    p = _write_glossary(tmp_path, '[workflow."Weekly Sync".terms]\n"standup" = "Stand-up"\n')
    unknown = _meeting(tmp_path, {"workflow_id": "00000000-0000-0000-0000-000000000000",
                                  "workflow_name": "Weekly Sync"})
    assert load_glossary(unknown, path=p).apply("standup")[0] == "Stand-up"
    absent = _meeting(tmp_path, {"workflow_name": "Weekly Sync"})
    assert load_glossary(absent, path=p).apply("standup")[0] == "Stand-up"


def test_wf11_a_table_stranded_by_an_earlier_rename_is_found_under_the_recorded_name(
    tmp_path: Path, monkeypatch
):
    """Renamed before WF11 moved tables: the id resolves to "Team Sync", which has no table
    (or only an empty one the editor left), so the recorded name's table still applies."""
    _workflow_dir(tmp_path, monkeypatch, "Team Sync")
    p = _write_glossary(tmp_path, '[workflow."Weekly Sync".terms]\n"standup" = "Stand-up"\n')
    wav = _meeting(tmp_path, {"workflow_id": WF11_ID, "workflow_name": "Weekly Sync"})
    assert load_glossary(wav, path=p).apply("standup")[0] == "Stand-up"
    p = _write_glossary(
        tmp_path,
        '[workflow."Team Sync".terms]\n\n[workflow."Weekly Sync".terms]\n"standup" = "Stand-up"\n',
    )
    assert load_glossary(wav, path=p).apply("standup")[0] == "Stand-up"


def test_wf11_the_current_names_table_wins_alone_over_the_recorded_names(tmp_path: Path, monkeypatch):
    _workflow_dir(tmp_path, monkeypatch, "Team Sync")
    p = _write_glossary(
        tmp_path,
        '[workflow."Team Sync".terms]\n"standup" = "Daily"\n\n'
        '[workflow."Weekly Sync".terms]\n"standup" = "Stand-up"\n"retro" = "Retro"\n',
    )
    wav = _meeting(tmp_path, {"workflow_id": WF11_ID, "workflow_name": "Weekly Sync"})
    assert load_glossary(wav, path=p).terms == {"standup": "Daily"}


def test_fuzzy_settings_load(tmp_path: Path):
    p = _write_glossary(
        tmp_path,
        '[terms]\n"kubernetes" = "Kubernetes"\n\n[fuzzy]\nenabled = true\nmax_distance = 1\n',
    )
    g = load_glossary(path=p)
    assert g.fuzzy_enabled is True
    assert g.apply("kubernetis")[0] == "Kubernetes"


# --- orchestrate wiring -----------------------------------------------------

def test_apply_glossary_rewrites_json_and_md(tmp_path: Path, monkeypatch):
    from mp import orchestrate

    stem = "20260707-1100"
    wav = tmp_path / f"{stem}.wav"
    json_path = tmp_path / f"{stem}.json"
    md_path = tmp_path / f"{stem}.md"
    structured = {
        "audio_path": str(wav),
        "language": "en",
        "segments": [{"start": 0.0, "end": 1.0, "text": "we met acme today", "speaker": "A"}],
    }
    json_path.write_text(json.dumps(structured), encoding="utf-8")
    md_path.write_text("stale", encoding="utf-8")

    monkeypatch.setattr(orchestrate, "load_glossary", lambda _wav: Glossary(terms={"acme": "ACME Corp"}))
    orchestrate.apply_glossary(wav, {"json": json_path, "md": md_path})

    assert "ACME Corp" in json.loads(json_path.read_text(encoding="utf-8"))["segments"][0]["text"]
    assert "ACME Corp" in md_path.read_text(encoding="utf-8")


def test_apply_glossary_noop_leaves_files_untouched(tmp_path: Path, monkeypatch):
    from mp import orchestrate

    stem = "20260707-1200"
    wav = tmp_path / f"{stem}.wav"
    json_path = tmp_path / f"{stem}.json"
    md_path = tmp_path / f"{stem}.md"
    json_path.write_text('{"segments": [{"text": "no terms here"}]}', encoding="utf-8")
    md_path.write_text("original md", encoding="utf-8")

    monkeypatch.setattr(orchestrate, "load_glossary", lambda _wav: Glossary(terms={"acme": "ACME Corp"}))
    orchestrate.apply_glossary(wav, {"json": json_path, "md": md_path})

    # Nothing matched, so the finalized files are left byte-identical.
    assert md_path.read_text(encoding="utf-8") == "original md"
