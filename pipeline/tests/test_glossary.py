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
    orchestrate._apply_glossary(wav, {"json": json_path, "md": md_path})

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
    orchestrate._apply_glossary(wav, {"json": json_path, "md": md_path})

    # Nothing matched, so the finalized files are left byte-identical.
    assert md_path.read_text(encoding="utf-8") == "original md"
