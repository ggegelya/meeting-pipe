"""``mp train-adapter``: fine-tune a local LoRA adapter on the corrections corpus (LOCAL9).

Owner-invoked and fully on-device. Reads the summary-grading corpus (the ``edited``
records: original vs corrected summary), builds prompt/completion pairs (transcript
-> the corrected summary the owner approved), and runs ``mlx_lm.lora --train`` to
produce a loadable adapter. Adoption is decided by ``mp dogfood --adapter <path>``
(base vs adapter A/B); the adapter ships only via an explicit
``summarization.local_adapter_path`` opt-in, never silently.

CLI-only by design: owner-dev tooling, like ``mp dogfood``, so it is exempt from the
de-CLI rule. No egress and no training in the background; it is a command the owner
runs. `mlx-lm` (already a pinned darwin/arm64 dependency) provides `mlx_lm.lora`; it
is invoked as a subprocess, matching `summarize_local.build_server_command`, so this
module stays importable on the light Linux CI without the heavy MLX stack.
"""
from __future__ import annotations

import argparse
import json
import logging
import shutil
import subprocess
import sys
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from . import corrections, entry

log = logging.getLogger("mp.train_adapter")

# Conservative training defaults; the owner tunes them per corpus via flags.
DEFAULT_ITERS = 300
DEFAULT_LORA_LAYERS = 16


@dataclass(frozen=True)
class Pair:
    prompt: str
    completion: str


def _read_transcript(transcript_path: str) -> str | None:
    if not transcript_path:
        return None
    try:
        return Path(transcript_path).read_text(encoding="utf-8")
    except OSError:
        return None


def _base_instruction() -> str:
    """The summarization task framing, read from the same package prompt the
    summarizer uses (`mp.prompts/meeting_summary.md`), so the adapter trains on the
    shape it sees at inference. Placeholders get neutral values (no per-record
    workflow context is stored in the corpus)."""
    from importlib import resources

    text = resources.files("mp.prompts").joinpath("meeting_summary.md").read_text(encoding="utf-8")
    text = text.replace("{team_context}", "(no team context configured)")
    text = text.replace("{summary_language_directive}", "")
    return text.strip()


def build_pairs(
    corrections_dir: Path,
    read_transcript: Callable[[str], str | None] = _read_transcript,
    instruction: str | None = None,
) -> list[Pair]:
    """Build (prompt, completion) pairs from every ``edited`` correction whose
    transcript is readable. prompt = instruction + transcript; completion = the
    corrected summary JSON. Records without a corrected summary, or whose transcript
    is gone, are skipped. Filename-sorted so a re-run over the same corpus is stable.
    """
    instr = instruction if instruction is not None else _base_instruction()
    pairs: list[Pair] = []
    for path in sorted(corrections_dir.glob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if data.get("verdict") != "edited":
            continue
        corrected = data.get("corrected_summary")
        if not isinstance(corrected, dict):
            continue
        transcript = read_transcript(data.get("transcript_path") or "")
        if not transcript:
            continue
        prompt = f"{instr}\n\n<transcript>\n{transcript}\n</transcript>"
        completion = json.dumps(corrected, ensure_ascii=False, indent=2)
        pairs.append(Pair(prompt=prompt, completion=completion))
    return pairs


def split_pairs(pairs: list[Pair]) -> dict[str, list[Pair]]:
    """Deterministic split into train / valid / test. `mlx_lm.lora` evaluates on the
    valid set during training, so valid always gets at least one pair; test is only
    carved out once the corpus is large enough to spare it. Stable by list order."""
    n = len(pairs)
    n_test = n // 10 if n >= 10 else 0
    n_valid = max(1, n // 10) if n >= 2 else 0
    n_train = n - n_valid - n_test
    return {
        "train": pairs[:n_train],
        "valid": pairs[n_train:n_train + n_valid],
        "test": pairs[n_train + n_valid:],
    }


def write_dataset(splits: dict[str, list[Pair]], data_dir: Path) -> None:
    """Write ``{train,valid,test}.jsonl`` in the ``{"prompt","completion"}`` shape
    `mlx_lm.lora --data` expects."""
    data_dir.mkdir(parents=True, exist_ok=True)
    for name, items in splits.items():
        lines = [
            json.dumps({"prompt": p.prompt, "completion": p.completion}, ensure_ascii=False)
            for p in items
        ]
        (data_dir / f"{name}.jsonl").write_text(
            "\n".join(lines) + ("\n" if lines else ""), encoding="utf-8"
        )


def build_lora_command(
    model: str,
    data_dir: Path,
    adapter_path: Path,
    iters: int = DEFAULT_ITERS,
    num_layers: int = DEFAULT_LORA_LAYERS,
) -> list[str]:
    """Argv for ``mlx_lm.lora --train``. Prefers the standalone entry point, else
    ``python -m`` (mirrors ``summarize_local.build_server_command``)."""
    if shutil.which("mlx_lm.lora") is not None:
        cmd = ["mlx_lm.lora"]
    else:
        cmd = [sys.executable, "-m", "mlx_lm.lora"]
    return cmd + [
        "--model", model,
        "--train",
        "--data", str(data_dir),
        "--fine-tune-type", "lora",
        "--num-layers", str(num_layers),
        "--iters", str(iters),
        "--adapter-path", str(adapter_path),
    ]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="mp train-adapter",
        description="Fine-tune a local LoRA adapter on the corrections corpus (on-device).",
    )
    parser.add_argument("--adapter-path", type=Path, required=True,
                        help="output directory for the trained adapter")
    parser.add_argument("--data-dir", type=Path, default=None,
                        help="where to write the JSONL dataset (default: <adapter-path>/data)")
    parser.add_argument("--model", default=None,
                        help="MLX model to fine-tune (default: summarization.local_model)")
    parser.add_argument("--iters", type=int, default=DEFAULT_ITERS)
    parser.add_argument("--num-layers", type=int, default=DEFAULT_LORA_LAYERS)
    parser.add_argument("--force", action="store_true",
                        help="train even when the corpus is below the readiness bar")
    parser.add_argument("--dry-run", action="store_true",
                        help="build the dataset and print the training command without running it")
    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    # Local-only: no secrets, guard armed. Training never egresses.
    cfg = entry.prepare(secrets=False)
    model = args.model or cfg.summarization.local_model

    # Readiness gate: reuse the `mp corrections-stats` bar so the two agree.
    records = corrections.load_records(corrections.CORRECTIONS_DIR)
    stats = corrections.aggregate(records)
    if not stats["ready"] and not args.force:
        sys.stderr.write(
            f"corpus not ready for training: {stats['total']}/{corrections.READINESS_MIN_COUNT} "
            f"corrections, {stats['transcript_chars']:,}/"
            f"{corrections.READINESS_MIN_TRANSCRIPT_CHARS:,} chars. "
            "Grade more meetings (see `mp corrections-stats`), or pass --force.\n"
        )
        return 2

    pairs = build_pairs(corrections.CORRECTIONS_DIR)
    if len(pairs) < 2:
        sys.stderr.write(
            f"need at least 2 edited corrections with readable transcripts; found {len(pairs)}.\n"
        )
        return 2

    data_dir = args.data_dir or (args.adapter_path / "data")
    splits = split_pairs(pairs)
    write_dataset(splits, data_dir)
    log.info(
        "wrote %d pairs (train=%d valid=%d test=%d) to %s",
        len(pairs), len(splits["train"]), len(splits["valid"]), len(splits["test"]), data_dir,
    )

    cmd = build_lora_command(model, data_dir, args.adapter_path, args.iters, args.num_layers)
    if args.dry_run:
        print(" ".join(cmd))
        return 0

    args.adapter_path.mkdir(parents=True, exist_ok=True)
    log.info("training adapter: %s", " ".join(cmd))
    result = subprocess.run(cmd, check=False)
    if result.returncode == 0:
        log.info(
            "adapter written to %s. A/B it with `mp dogfood --adapter %s`, then opt in via "
            "summarization.local_adapter_path if it wins.",
            args.adapter_path, args.adapter_path,
        )
    return result.returncode
