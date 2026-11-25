import json
import os
from pathlib import Path

from mp.summarize import RenderedTranscript, _load_system_prompt, render_model_transcript
from mp.summarize_local import LocalSummaryClient, compose_user_message
from mp.summary_language import expected_summary_language
from mp.train_adapter import (
    DEFAULT_MAX_SEQ_LENGTH,
    Pair,
    PromptSettings,
    _make_pair,
    base_system_prompt,
    build_lora_command,
    build_pairs,
    build_run_pairs,
    collect_pairs,
    fit_to_budget,
    gate_ready,
    held_out_stems,
    read_split_manifest,
    split_pairs,
    trained_stems,
    write_dataset,
    write_split_manifest,
)


def _write_correction(
    directory: Path, stem: str, *, verdict: str = "edited",
    corrected: dict | None = None, transcript_path: str = "",
) -> None:
    rec: dict = {"verdict": verdict, "stem": stem, "transcript_path": transcript_path}
    if corrected is not None:
        rec["corrected_summary"] = corrected
    (directory / f"{stem}.json").write_text(json.dumps(rec), encoding="utf-8")


# TYPE2 (B006): a module constant, not a literal in the signature, and never mutated;
# None already means "no summary file", so it cannot be the default.
_DEFAULT_SUMMARY = {"title": "S"}


def _write_run(
    directory: Path, stem: str, *, backend: str = "anthropic",
    summary: dict | None = _DEFAULT_SUMMARY, transcript: str | None = "transcript",
) -> None:
    """A run sidecar plus the transcript and summary it points at, as `mp run-all`
    leaves them on disk. `summary=None` writes none."""
    transcript_path = directory / f"{stem}.md"
    summary_path = directory / f"{stem}.summary.json"
    if transcript is not None:
        transcript_path.write_text(transcript, encoding="utf-8")
    if summary is not None:
        summary_path.write_text(json.dumps(summary), encoding="utf-8")
    (directory / f"{stem}.run.json").write_text(json.dumps({
        "stem": stem,
        "backend": backend,
        "transcript_path": str(transcript_path),
        "summary_json_path": str(summary_path),
    }), encoding="utf-8")


def test_build_pairs_uses_edited_records_with_readable_transcripts(tmp_path: Path):
    corr = tmp_path / "corrections"
    corr.mkdir()
    _write_correction(corr, "a", corrected={"title": "A"}, transcript_path="/t/a.md")
    _write_correction(corr, "b", corrected={"title": "B"}, transcript_path="/t/b.md")
    # A 'good' verdict has no corrected summary -> skipped.
    _write_correction(corr, "c", verdict="good", transcript_path="/t/c.md")
    # An edited record whose transcript is gone -> skipped.
    _write_correction(corr, "d", corrected={"title": "D"}, transcript_path="/gone.md")

    transcripts = {"/t/a.md": "transcript A", "/t/b.md": "transcript B"}
    pairs = build_pairs(
        corr,
        render=lambda p: (RenderedTranscript(transcripts[str(p)], [], False)
                          if str(p) in transcripts else None),
    )
    assert len(pairs) == 2  # a and b only
    assert "transcript A" in pairs[0].prompt
    assert json.loads(pairs[0].completion) == {"title": "A"}


def _scratch_meeting(directory: Path, stem: str = "20260101-090000", *, structured: bool = True) -> Path:
    """A meeting as the pipeline leaves it: `<stem>.md`, optionally `<stem>.json`, and a
    `<stem>.summary.json` with an evidence map."""
    md = directory / f"{stem}.md"
    md.write_text("# Transcript\n\n**Alice**: We will ship the export on Friday.\n"
                  "**Bob**: Good, and I will tell the QA team today.\n", encoding="utf-8")
    if structured:
        (directory / f"{stem}.json").write_text(json.dumps({"language": "en", "segments": [
            {"start": 0.0, "end": 12.0, "speaker": "Alice", "text": "We will ship the export on Friday."},
            {"start": 75.0, "end": 90.0, "speaker": "Bob", "text": "Good, and I will tell the QA team today."},
        ]}), encoding="utf-8")
    return md


_STORED = {
    "title": "Export sync",
    "summary": ["Export ships Friday.", "QA hears today."],
    "decisions": ["Ship Friday."],
    "actions": [{"task": "Tell QA", "owner": "Bob", "due": None, "confidence": "high",
                 "evidence": [{"quote": "I will tell the QA team", "t": 75.0}]}],
    "questions": [],
    "attendees": ["Alice", "Bob"],
    "detected_language": "en",
    "evidence": {"summary": [[{"quote": "ship the export on Friday", "t": 0.0}], []]},
}


def test_pairs_carry_the_turns_the_local_server_actually_sends(tmp_path: Path):
    """LOCAL27: the pair's system and user turns are what `LocalSummaryClient` sends for
    the same meeting, through the one builder: the `[mm:ss]` render and the language
    reinforcement included. The old pin checked the prompt pieces, never the client."""
    md = _scratch_meeting(tmp_path)
    settings = PromptSettings("ACME regulated SaaS", "auto")
    pair = _make_pair(stem="s", rendered=render_model_transcript(md), summary=_STORED,
                      source="runs", settings=settings)

    rendered = render_model_transcript(md)
    client = LocalSummaryClient(manage_subprocess=False, summary_language="auto")
    target = expected_summary_language("auto", rendered.text)
    served = client._messages_for(_load_system_prompt("ACME regulated SaaS", "auto"), rendered.text, target)
    assert pair.messages()[:2] == served
    assert "[0:00]" in pair.prompt and "[1:15]" in pair.prompt
    assert target == "en" and pair.system != base_system_prompt("ACME regulated SaaS", "auto")
    completion = json.loads(pair.completion)
    assert completion["summary"][0] == {"text": "Export ships Friday.",
                                        "evidence": [{"quote": "ship the export on Friday", "t": 0.0}]}
    assert "evidence" not in completion


def test_a_meeting_with_only_markdown_trains_on_the_markdown_fallback(tmp_path: Path):
    md = _scratch_meeting(tmp_path, structured=False)
    pair = _make_pair(stem="s", rendered=render_model_transcript(md), summary=_STORED,
                      source="runs", settings=PromptSettings())
    assert pair.prompt == compose_user_message(md.read_text(encoding="utf-8"))
    assert "[0:00]" not in pair.prompt


def test_split_pairs_reserves_valid_and_only_carves_test_when_large():
    small = [Pair(prompt=str(i), completion=str(i)) for i in range(2)]
    s = split_pairs(small)
    assert (len(s["train"]), len(s["valid"]), len(s["test"])) == (1, 1, 0)

    big = [Pair(prompt=str(i), completion=str(i)) for i in range(20)]
    b = split_pairs(big)
    assert (len(b["train"]), len(b["valid"]), len(b["test"])) == (16, 2, 2)
    # Nothing lost or duplicated.
    assert len(b["train"]) + len(b["valid"]) + len(b["test"]) == 20


def test_write_dataset_emits_chat_messages_jsonl(tmp_path: Path):
    splits = {
        "train": [Pair("p1", "c1", system="s1")],
        "valid": [Pair("p2", "c2", system="s2")],
        "test": [],
    }
    write_dataset(splits, tmp_path)
    for name in ("train", "valid", "test"):
        assert (os.stat(tmp_path / f"{name}.jsonl").st_mode & 0o777) == 0o600
    train = (tmp_path / "train.jsonl").read_text(encoding="utf-8").strip().splitlines()
    assert json.loads(train[0]) == {"messages": [
        {"role": "system", "content": "s1"},
        {"role": "user", "content": "p1"},
        {"role": "assistant", "content": "c1"},
    ]}
    assert (tmp_path / "valid.jsonl").exists()
    assert (tmp_path / "test.jsonl").read_text(encoding="utf-8") == ""


def test_fit_to_budget_drops_meetings_that_would_be_truncated():
    """mlx_lm.lora truncates the tail, which is the summary, so an over-long example
    teaches nothing at all. Dropping is loud; truncating would be silent."""
    short = Pair("u", "c", system="s")
    long_one = Pair("u" * 100_000, "c", system="s")
    kept, dropped = fit_to_budget([short, long_one], max_seq_length=4096)
    assert kept == [short]
    assert dropped == [long_one]


def test_with_the_default_budget_a_short_meeting_is_kept(tmp_path: Path):
    """LOCAL27: the real system turn alone was over the old default, so every pair was
    dropped. A short meeting fits the new default."""
    pair = _make_pair(stem="s", rendered=render_model_transcript(_scratch_meeting(tmp_path)),
                      summary=_STORED, source="runs", settings=PromptSettings())
    kept, dropped = fit_to_budget([pair], DEFAULT_MAX_SEQ_LENGTH)
    assert kept == [pair] and dropped == []


def test_a_budget_below_the_system_turn_refuses_and_names_it(tmp_path: Path, monkeypatch, capsys):
    from mp import train_adapter

    monkeypatch.setattr(train_adapter.entry, "prepare", lambda **_: train_adapter.entry.Config())
    rc = train_adapter.main(["--adapter-path", str(tmp_path / "a"), "--max-seq-length", "2048"])
    assert rc == 2
    err = capsys.readouterr().err
    assert "system turn" in err and "--max-seq-length" in err
    assert not (tmp_path / "a").exists(), "refused before writing anything"


def test_build_run_pairs_distils_cloud_runs_and_skips_local_ones(tmp_path: Path):
    rec = tmp_path / "raw"
    rec.mkdir()
    _write_run(rec, "cloud1", summary={"title": "One"})
    _write_run(rec, "cloud2", summary={"title": "Two"})
    # A local-backend run teaches the local model nothing -> skipped.
    _write_run(rec, "selftrained", backend="local")
    # Missing summary / missing transcript -> skipped.
    _write_run(rec, "nosummary", summary=None)
    _write_run(rec, "notranscript", transcript=None)

    pairs = build_run_pairs(rec)
    assert [p.stem for p in pairs] == ["cloud1", "cloud2"]
    assert pairs[0].source == "runs"
    assert "transcript" in pairs[0].prompt
    assert json.loads(pairs[0].completion) == {"title": "One"}
    assert pairs[0].transcript_chars == len("transcript")
    assert pairs[0].system == base_system_prompt()


def test_build_run_pairs_honours_exclude_stems(tmp_path: Path):
    rec = tmp_path / "raw"
    rec.mkdir()
    _write_run(rec, "a")
    _write_run(rec, "b")
    assert [p.stem for p in build_run_pairs(rec, exclude_stems={"a"})] == ["b"]


def test_collect_pairs_both_prefers_the_corrected_summary(tmp_path: Path):
    corr = tmp_path / "corrections"
    corr.mkdir()
    rec = tmp_path / "raw"
    rec.mkdir()
    _write_run(rec, "shared", summary={"title": "cloud version"})
    _write_run(rec, "cloudonly", summary={"title": "cloud only"})
    _write_correction(corr, "shared", corrected={"title": "owner version"},
                      transcript_path=str(rec / "shared.md"))

    pairs = collect_pairs("both", corrections_dir=corr, recordings_dir=rec)
    # 'shared' appears once, as the correction; the runs fill adds only 'cloudonly'.
    assert [(p.stem, p.source) for p in pairs] == [
        ("shared", "corrections"), ("cloudonly", "runs"),
    ]
    assert json.loads(pairs[0].completion) == {"title": "owner version"}

    # The other two sources stay single-source.
    assert [p.stem for p in collect_pairs("runs", corrections_dir=corr,
                                          recordings_dir=rec)] == [
        "cloudonly", "shared",
    ]
    assert [p.stem for p in collect_pairs("corrections", corrections_dir=corr,
                                          recordings_dir=rec)] == ["shared"]


def test_gate_ready_measures_runs_corpus_against_the_same_bars():
    thin = [Pair("p", "c", stem=str(i), source="runs", transcript_chars=100)
            for i in range(5)]
    ready, state = gate_ready("runs", thin)
    assert not ready
    assert "5/20 pairs" in state

    fat = [Pair("p", "c", stem=str(i), source="runs", transcript_chars=20_000)
           for i in range(20)]
    ready, state = gate_ready("runs", fat)
    assert ready
    assert "400,000/200,000 chars" in state


def test_split_manifest_records_held_out_and_trained_stems(tmp_path: Path):
    adapter = tmp_path / "adapter"
    splits = {
        "train": [Pair("p", "c", stem="a", source="runs")],
        "valid": [Pair("p", "c", stem="b", source="runs")],
        "test": [Pair("p", "c", stem="c", source="corrections")],
    }
    written = write_split_manifest(splits, adapter, source="both", model="qwen")
    assert (os.stat(written).st_mode & 0o777) == 0o600, "LOCAL27: it names meetings"

    manifest = read_split_manifest(adapter)
    assert manifest is not None
    assert manifest["source"] == "both"
    assert manifest["model"] == "qwen"
    assert manifest["pairs_by_source"] == {"corrections": 1, "runs": 2}
    assert manifest["counts"] == {"train": 1, "valid": 1, "test": 1}
    # valid counts as trained: mlx_lm.lora evaluates against it during training.
    assert trained_stems(manifest) == {"a", "b"}
    assert held_out_stems(manifest) == ["c"]


def test_read_split_manifest_absent_is_none(tmp_path: Path):
    assert read_split_manifest(tmp_path / "nope") is None


def test_build_lora_command_targets_train_and_adapter(tmp_path: Path):
    cmd = build_lora_command(
        "mlx-community/Qwen2.5-7B-Instruct-4bit",
        tmp_path / "data", tmp_path / "adapter", iters=50, num_layers=8,
    )
    assert "--train" in cmd
    assert cmd[cmd.index("--fine-tune-type") + 1] == "lora"
    assert cmd[cmd.index("--model") + 1] == "mlx-community/Qwen2.5-7B-Instruct-4bit"
    assert cmd[cmd.index("--data") + 1] == str(tmp_path / "data")
    assert cmd[cmd.index("--adapter-path") + 1] == str(tmp_path / "adapter")
    assert cmd[cmd.index("--iters") + 1] == "50"
    assert cmd[cmd.index("--num-layers") + 1] == "8"
    assert cmd[cmd.index("--batch-size") + 1] == "1", "LOCAL27: 8192 x 1, what LOCAL9's run used"
    assert cmd[cmd.index("--max-seq-length") + 1] == "8192"


def test_build_lora_command_batch_size_override(tmp_path: Path):
    cmd = build_lora_command(
        "mlx-community/Qwen2.5-7B-Instruct-4bit",
        tmp_path / "data", tmp_path / "adapter", batch_size=1,
    )
    assert cmd[cmd.index("--batch-size") + 1] == "1"


def test_a_moved_library_keeps_every_pair_from_both_sources(tmp_path: Path):
    """LOCAL26: run sidecars and correction records store absolute paths, which a library
    move (SEC12) or a restore onto another root leaves stale. Both sources resolve by stem
    against the current library, so the pair count survives the move."""
    old = tmp_path / "old"
    old.mkdir()
    corr = tmp_path / "corrections"
    corr.mkdir()
    for stem in ("m1", "m2"):
        _write_run(old, stem)
        _write_correction(corr, stem, corrected={"title": stem.upper()},
                          transcript_path=str(old / f"{stem}.md"))
    before = {src: len(collect_pairs(src, corrections_dir=corr, recordings_dir=old))
              for src in ("runs", "corrections")}
    assert before == {"runs": 2, "corrections": 2}

    new = tmp_path / "new"
    old.rename(new)
    after = {src: collect_pairs(src, corrections_dir=corr, recordings_dir=new)
             for src in ("runs", "corrections")}
    assert {src: len(p) for src, p in after.items()} == before
    assert all("transcript" in p.prompt for p in after["runs"] + after["corrections"])


def test_gate_ready_counts_a_moved_librarys_corrections(tmp_path: Path, monkeypatch):
    from mp import corrections as corr_mod

    corr = tmp_path / "corrections"
    corr.mkdir()
    library = tmp_path / "library"
    library.mkdir()
    (library / "m1.md").write_text("x" * 5_000, encoding="utf-8")
    _write_correction(corr, "m1", verdict="good", transcript_path="/gone/m1.md")
    monkeypatch.setattr(corr_mod, "CORRECTIONS_DIR", corr)
    _ready, state = gate_ready("corrections", [], library)
    assert "5,000/" in state


def test_the_trainer_child_gets_the_egress_guards_env(tmp_path: Path, monkeypatch):
    """HYG18: `mlx_lm.lora` is the one child here that can fetch weights, so it is spawned with
    `egress_guard.child_env()` rather than an inherited env."""
    import subprocess

    from mp import train_adapter

    pairs = [_make_pair(stem=s, rendered=render_model_transcript(_scratch_meeting(tmp_path)),
                        summary=_STORED, source="runs", settings=PromptSettings()) for s in ("a", "b")]
    monkeypatch.setattr(train_adapter.entry, "prepare", lambda **_: train_adapter.entry.Config())
    monkeypatch.setattr(train_adapter, "collect_pairs", lambda *a, **k: pairs)
    monkeypatch.setattr(train_adapter, "gate_ready", lambda *a, **k: (True, "ready"))
    sentinel = {"MP_HYG18_SENTINEL": "1"}
    monkeypatch.setattr(train_adapter.egress_guard, "child_env", lambda: sentinel)
    seen: dict = {}

    def fake_run(cmd, **kwargs):
        seen.update(kwargs)
        return subprocess.CompletedProcess(cmd, 0)

    monkeypatch.setattr(train_adapter.subprocess, "run", fake_run)
    rc = train_adapter.main(["--adapter-path", str(tmp_path / "a"), "--source", "runs",
                             "--max-seq-length", str(DEFAULT_MAX_SEQ_LENGTH)])
    assert rc == 0
    assert seen.get("env") is sentinel
