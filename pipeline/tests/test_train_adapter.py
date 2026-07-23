import json
from pathlib import Path

from mp.summarize_local import compose_user_message
from mp.train_adapter import (
    Pair,
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


def _write_run(
    directory: Path, stem: str, *, backend: str = "anthropic",
    summary: dict | None = {"title": "S"}, transcript: str | None = "transcript",
) -> None:
    """A run sidecar plus the transcript and summary it points at, as `mp run-all`
    leaves them on disk."""
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
        read_transcript=lambda p: transcripts.get(p),
        system_prompt="SUMMARIZE",
    )
    assert len(pairs) == 2  # a and b only
    assert pairs[0].system == "SUMMARIZE"
    assert "transcript A" in pairs[0].prompt
    assert json.loads(pairs[0].completion) == {"title": "A"}


def test_pairs_carry_the_prompt_the_local_server_actually_sends():
    """The adapter is served through `LocalSummaryClient`, so it has to train on that
    client's exact turns; an earlier version trained on a hand-rolled framing that
    dropped the schema block and left a placeholder unsubstituted."""
    system = base_system_prompt("ACME regulated SaaS", "en")
    assert "ACME regulated SaaS" in system
    assert "json-schema" in system          # the schema block the server appends
    assert "{" + "extra_sections_directive" + "}" not in system  # no stray placeholder

    pair = _make_pair(stem="s", system_prompt=system, transcript="hello",
                      summary={"title": "T"}, source="runs")
    assert pair.prompt == compose_user_message("hello")
    assert pair.messages() == [
        {"role": "system", "content": system},
        {"role": "user", "content": pair.prompt},
        {"role": "assistant", "content": pair.completion},
    ]


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

    pairs = build_run_pairs(rec, system_prompt="SUMMARIZE")
    assert [p.stem for p in pairs] == ["cloud1", "cloud2"]
    assert pairs[0].source == "runs"
    assert "transcript" in pairs[0].prompt
    assert json.loads(pairs[0].completion) == {"title": "One"}
    assert pairs[0].transcript_chars == len("transcript")


def test_build_run_pairs_honours_exclude_stems(tmp_path: Path):
    rec = tmp_path / "raw"
    rec.mkdir()
    _write_run(rec, "a")
    _write_run(rec, "b")
    assert [p.stem for p in build_run_pairs(rec, exclude_stems={"a"},
                                            system_prompt="S")] == ["b"]


def test_collect_pairs_both_prefers_the_corrected_summary(tmp_path: Path):
    corr = tmp_path / "corrections"
    corr.mkdir()
    rec = tmp_path / "raw"
    rec.mkdir()
    _write_run(rec, "shared", summary={"title": "cloud version"})
    _write_run(rec, "cloudonly", summary={"title": "cloud only"})
    _write_correction(corr, "shared", corrected={"title": "owner version"},
                      transcript_path=str(rec / "shared.md"))

    pairs = collect_pairs("both", corrections_dir=corr, recordings_dir=rec,
                          system_prompt="SUMMARIZE")
    # 'shared' appears once, as the correction; the runs fill adds only 'cloudonly'.
    assert [(p.stem, p.source) for p in pairs] == [
        ("shared", "corrections"), ("cloudonly", "runs"),
    ]
    assert json.loads(pairs[0].completion) == {"title": "owner version"}

    # The other two sources stay single-source.
    assert [p.stem for p in collect_pairs("runs", corrections_dir=corr,
                                          recordings_dir=rec, system_prompt="S")] == [
        "cloudonly", "shared",
    ]
    assert [p.stem for p in collect_pairs("corrections", corrections_dir=corr,
                                          recordings_dir=rec, system_prompt="S")] == ["shared"]


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
    write_split_manifest(splits, adapter, source="both", model="qwen")

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
