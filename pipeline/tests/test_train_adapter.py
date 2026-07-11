import json
from pathlib import Path

from mp.train_adapter import (
    Pair,
    build_lora_command,
    build_pairs,
    split_pairs,
    write_dataset,
)


def _write_correction(
    directory: Path, stem: str, *, verdict: str = "edited",
    corrected: dict | None = None, transcript_path: str = "",
) -> None:
    rec: dict = {"verdict": verdict, "stem": stem, "transcript_path": transcript_path}
    if corrected is not None:
        rec["corrected_summary"] = corrected
    (directory / f"{stem}.json").write_text(json.dumps(rec), encoding="utf-8")


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
        instruction="SUMMARIZE",
    )
    assert len(pairs) == 2  # a and b only
    assert pairs[0].prompt.startswith("SUMMARIZE")
    assert "transcript A" in pairs[0].prompt
    assert json.loads(pairs[0].completion) == {"title": "A"}


def test_split_pairs_reserves_valid_and_only_carves_test_when_large():
    small = [Pair(prompt=str(i), completion=str(i)) for i in range(2)]
    s = split_pairs(small)
    assert (len(s["train"]), len(s["valid"]), len(s["test"])) == (1, 1, 0)

    big = [Pair(prompt=str(i), completion=str(i)) for i in range(20)]
    b = split_pairs(big)
    assert (len(b["train"]), len(b["valid"]), len(b["test"])) == (16, 2, 2)
    # Nothing lost or duplicated.
    assert len(b["train"]) + len(b["valid"]) + len(b["test"]) == 20


def test_write_dataset_emits_prompt_completion_jsonl(tmp_path: Path):
    splits = {"train": [Pair("p1", "c1")], "valid": [Pair("p2", "c2")], "test": []}
    write_dataset(splits, tmp_path)
    train = (tmp_path / "train.jsonl").read_text(encoding="utf-8").strip().splitlines()
    assert json.loads(train[0]) == {"prompt": "p1", "completion": "c1"}
    assert (tmp_path / "valid.jsonl").exists()
    assert (tmp_path / "test.jsonl").read_text(encoding="utf-8") == ""


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
