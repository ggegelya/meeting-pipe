"""``mp train-adapter``: fine-tune a local LoRA adapter on the corrections corpus (LOCAL9).

Owner-invoked and fully on-device. Builds prompt/completion pairs (transcript -> the
summary it should have produced), and runs ``mlx_lm.lora --train`` to produce a
loadable adapter. Adoption is decided by ``mp dogfood --adapter <path>`` (base vs
adapter A/B on a held-out meeting); the adapter ships only via an explicit
``summarization.local_adapter_path`` opt-in, never silently.

Two corpus sources, picked with ``--source``:

* ``corrections`` (default): the summary-grading corpus, the ``edited`` records where
  the owner rewrote a summary. The highest-value signal (it teaches the owner's
  taste) and the scarcest, since it only exists once the owner grades.
* ``runs``: the run sidecars, i.e. every meeting already summarized by the cloud
  model, distilled into the local one. Local-backend runs are skipped (a model
  learns nothing from its own output). This exists because the corrections corpus
  can sit empty for months while a hundred real cloud-summarized meetings pile up
  next to it, and a small model imitating a bigger one is the standard use of that.
* ``both``: corrections first, runs fill the rest, corrected stems never duplicated.

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
# 4096 fits a 7B-4bit LoRA on 32 GB of unified memory with gradient checkpointing.
# Raising it is the owner's call (it is what keeps long meetings in the corpus) but
# it is also what makes the machine swap, so the default stays where it is safe.
DEFAULT_MAX_SEQ_LENGTH = 4096
# Pessimistic chars-per-token for this corpus: English runs ~3.5, Cyrillic closer to
# 2, and a mixed transcript should not be estimated as if it were pure English.
CHARS_PER_TOKEN = 2.5


CORPUS_SOURCES = ("corrections", "runs", "both")

SPLIT_MANIFEST_NAME = "split.json"


@dataclass(frozen=True)
class Pair:
    """One training example, in the three turns the local server actually exchanges."""
    prompt: str            # the user turn, from `summarize_local.compose_user_message`
    completion: str        # the assistant turn: the summary JSON
    system: str = ""       # the system turn, schema-augmented exactly as served
    stem: str = ""
    source: str = "corrections"
    transcript_chars: int = 0

    def chars(self) -> int:
        """Total characters the tokenizer will see for this example."""
        return len(self.system) + len(self.prompt) + len(self.completion)

    def messages(self) -> list[dict[str, str]]:
        """The example as chat turns, the layout `mlx_lm.lora`'s `ChatDataset` reads
        and the same one `LocalSummaryClient` sends at inference."""
        turns = [{"role": "system", "content": self.system}] if self.system else []
        return turns + [
            {"role": "user", "content": self.prompt},
            {"role": "assistant", "content": self.completion},
        ]


def _read_transcript(transcript_path: str) -> str | None:
    if not transcript_path:
        return None
    try:
        return Path(transcript_path).read_text(encoding="utf-8")
    except OSError:
        return None


def base_system_prompt(team_context: str = "", summary_language: str = "auto") -> str:
    """The exact system turn `LocalSummaryClient` sends: the master prompt with the
    configured team context and language directive filled in, then the schema and
    reinforcement block appended.

    Built from the shipping helpers rather than re-templated here. An earlier version
    of this function hand-substituted two of the four placeholders with neutral text,
    which left a literal `{extra_sections_directive}` in every training prompt, wrote
    "(no team context configured)" where the server sends the real one, and omitted
    the schema block entirely. A LoRA trained on that shape would have been tuned for
    a prompt the server never sends.
    """
    from .summarize import _load_system_prompt
    from .summarize_local import augment_with_schema

    return augment_with_schema(_load_system_prompt(team_context, summary_language))


def build_pairs(
    corrections_dir: Path,
    read_transcript: Callable[[str], str | None] = _read_transcript,
    system_prompt: str | None = None,
) -> list[Pair]:
    """Build training pairs from every ``edited`` correction whose transcript is
    readable; the completion is the corrected summary JSON. Records without a
    corrected summary, or whose transcript is gone, are skipped. Filename-sorted so a
    re-run over the same corpus is stable.
    """
    instr = system_prompt if system_prompt is not None else base_system_prompt()
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
        transcript_path = data.get("transcript_path") or ""
        transcript = read_transcript(transcript_path)
        if not transcript:
            continue
        pairs.append(_make_pair(
            stem=data.get("stem") or Path(transcript_path).stem,
            system_prompt=instr,
            transcript=transcript,
            summary=corrected,
            source="corrections",
        ))
    return pairs


def build_run_pairs(
    recordings_dir: Path,
    read_transcript: Callable[[str], str | None] = _read_transcript,
    system_prompt: str | None = None,
    exclude_stems: set[str] | None = None,
) -> list[Pair]:
    """Build (prompt, completion) pairs from the run sidecars: transcript -> the
    summary that run actually published (LOCAL9 distillation source).

    The corrections corpus teaches the local model the owner's taste, but it only
    exists once the owner grades. The run sidecars already record 100+ real meetings
    summarized by the *cloud* model, and a small local model imitating a larger one
    is the standard, effective use of that material. `backend == "local"` runs are
    skipped: a model cannot learn anything from its own output. Filename-sorted, so
    a re-run over the same recordings dir is stable.
    """
    instr = system_prompt if system_prompt is not None else base_system_prompt()
    skip = exclude_stems or set()
    pairs: list[Pair] = []
    for path in sorted(recordings_dir.glob("*.run.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict) or data.get("backend") == "local":
            continue
        stem = data.get("stem") or path.name[: -len(".run.json")]
        if stem in skip:
            continue
        summary = _read_summary(data.get("summary_json_path") or "")
        if not summary:
            continue
        transcript = read_transcript(data.get("transcript_path") or "")
        if not transcript:
            continue
        pairs.append(_make_pair(
            stem=stem,
            system_prompt=instr,
            transcript=transcript,
            summary=summary,
            source="runs",
        ))
    return pairs


def _read_summary(summary_json_path: str) -> dict | None:
    """The summary JSON a run produced, or None when absent/unreadable/empty."""
    if not summary_json_path:
        return None
    try:
        data = json.loads(Path(summary_json_path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) and data else None


def _make_pair(
    *, stem: str, system_prompt: str, transcript: str, summary: dict, source: str
) -> Pair:
    from .summarize_local import compose_user_message

    return Pair(
        prompt=compose_user_message(transcript),
        completion=json.dumps(summary, ensure_ascii=False, indent=2),
        system=system_prompt,
        stem=stem,
        source=source,
        transcript_chars=len(transcript),
    )


def collect_pairs(
    source: str,
    *,
    corrections_dir: Path,
    recordings_dir: Path,
    system_prompt: str | None = None,
) -> list[Pair]:
    """Pairs for the requested corpus source. Under ``both`` the corrections come
    first and their stems are withheld from the runs fill, so a meeting the owner
    corrected trains on the corrected summary, never on the one it replaced."""
    if source == "runs":
        return build_run_pairs(recordings_dir, system_prompt=system_prompt)
    corrected = build_pairs(corrections_dir, system_prompt=system_prompt)
    if source == "corrections":
        return corrected
    return corrected + build_run_pairs(
        recordings_dir,
        system_prompt=system_prompt,
        exclude_stems={p.stem for p in corrected if p.stem},
    )


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


def gate_ready(source: str, pairs: list[Pair]) -> tuple[bool, str]:
    """Is the corpus big enough to train on? Returns (ready, human-readable state).

    ``corrections`` keeps the ``mp corrections-stats`` bar, which is what the README
    and that command advertise, so the two keep agreeing. A ``runs``/``both`` corpus
    has no corrections-stats reading to check, so it gates on the trainable pairs it
    just built, against the same two numbers.
    """
    if source == "corrections":
        stats = corrections.aggregate(corrections.load_records(corrections.CORRECTIONS_DIR))
        state = (
            f"{stats['total']}/{corrections.READINESS_MIN_COUNT} corrections, "
            f"{stats['transcript_chars']:,}/"
            f"{corrections.READINESS_MIN_TRANSCRIPT_CHARS:,} chars"
        )
        return bool(stats["ready"]), state
    chars = sum(p.transcript_chars for p in pairs)
    state = (
        f"{len(pairs)}/{corrections.READINESS_MIN_COUNT} pairs, "
        f"{chars:,}/{corrections.READINESS_MIN_TRANSCRIPT_CHARS:,} chars"
    )
    ready = (
        len(pairs) >= corrections.READINESS_MIN_COUNT
        and chars >= corrections.READINESS_MIN_TRANSCRIPT_CHARS
    )
    return ready, state


def write_split_manifest(
    splits: dict[str, list[Pair]], adapter_path: Path, *, source: str, model: str
) -> Path:
    """Record which meetings went into which split, next to the adapter.

    This is what makes the A/B honest: ``mp dogfood --adapter`` reads it and refuses
    a transcript the adapter trained on, so the scorecard that decides adoption
    cannot be a memory test. Written at dataset-build time, before training starts.
    """
    adapter_path.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema_version": 1,
        "source": source,
        "model": model,
        "pairs_by_source": {
            s: sum(1 for items in splits.values() for p in items if p.source == s)
            for s in ("corrections", "runs")
        },
        "counts": {name: len(items) for name, items in splits.items()},
        "stems": {
            name: [p.stem for p in items if p.stem] for name, items in splits.items()
        },
    }
    out = adapter_path / SPLIT_MANIFEST_NAME
    out.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    return out


def read_split_manifest(adapter_path: Path) -> dict | None:
    """The split manifest written beside an adapter, or None when absent/unreadable
    (an adapter trained before this existed, or one produced by hand)."""
    try:
        data = json.loads((adapter_path / SPLIT_MANIFEST_NAME).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def trained_stems(manifest: dict) -> set[str]:
    """Stems the adapter actually saw during training (train + valid). `mlx_lm.lora`
    evaluates on valid every few iterations, so it is contaminated too."""
    stems = manifest.get("stems")
    if not isinstance(stems, dict):
        return set()
    out: set[str] = set()
    for split in ("train", "valid"):
        values = stems.get(split)
        if isinstance(values, list):
            out.update(str(v) for v in values if v)
    return out


def held_out_stems(manifest: dict) -> list[str]:
    """Stems reserved for evaluation, i.e. the ones the A/B may legitimately use."""
    stems = manifest.get("stems")
    if not isinstance(stems, dict):
        return []
    values = stems.get("test")
    return [str(v) for v in values if v] if isinstance(values, list) else []


def write_dataset(splits: dict[str, list[Pair]], data_dir: Path) -> None:
    """Write ``{train,valid,test}.jsonl`` in the ``{"messages": [...]}`` shape
    `mlx_lm.lora --data` expects (its `ChatDataset`).

    Chat format, not ``{"prompt","completion"}``, because that flat form has no
    system role: it would fold our system turn into the user turn and train the
    adapter on a message layout the server never produces.
    """
    data_dir.mkdir(parents=True, exist_ok=True)
    for name, items in splits.items():
        lines = [json.dumps({"messages": p.messages()}, ensure_ascii=False) for p in items]
        (data_dir / f"{name}.jsonl").write_text(
            "\n".join(lines) + ("\n" if lines else ""), encoding="utf-8"
        )


def fit_to_budget(
    pairs: list[Pair], max_seq_length: int
) -> tuple[list[Pair], list[Pair]]:
    """Split pairs into (kept, dropped) by whether they fit the training context.

    `mlx_lm.lora` silently truncates anything past ``--max-seq-length``, and it
    truncates the *end*, which is where the summary lives. A truncated example does
    not teach a shorter summary, it teaches no summary at all, so an over-long pair
    is dropped rather than half-learned. The caller logs the drop count; a corpus of
    long meetings should raise the budget knowingly, not lose 80% of itself quietly.

    Length is estimated from characters at `CHARS_PER_TOKEN`, deliberately
    pessimistic: Cyrillic tokenizes far worse than English and this corpus is mixed.
    """
    budget_chars = int(max_seq_length * CHARS_PER_TOKEN)
    kept = [p for p in pairs if p.chars() <= budget_chars]
    dropped = [p for p in pairs if p.chars() > budget_chars]
    return kept, dropped


def build_lora_command(
    model: str,
    data_dir: Path,
    adapter_path: Path,
    iters: int = DEFAULT_ITERS,
    num_layers: int = DEFAULT_LORA_LAYERS,
    max_seq_length: int = DEFAULT_MAX_SEQ_LENGTH,
) -> list[str]:
    """Argv for ``mlx_lm.lora --train``. Prefers the standalone entry point, else
    ``python -m`` (mirrors ``summarize_local.build_server_command``).

    ``--mask-prompt`` keeps the loss on the assistant turn: the goal is a model that
    writes better summaries, not one that reproduces transcripts. ``--grad-checkpoint``
    trades compute for memory so a 7B stays inside a laptop's unified memory at this
    sequence length.
    """
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
        "--max-seq-length", str(max_seq_length),
        "--mask-prompt",
        "--grad-checkpoint",
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
    parser.add_argument("--source", choices=CORPUS_SOURCES, default="corrections",
                        help="training corpus: 'corrections' (summaries you edited), "
                             "'runs' (distil the cloud summaries already on disk), or "
                             "'both' (corrections first, runs fill the rest)")
    parser.add_argument("--recordings-dir", type=Path, default=None,
                        help="where the run sidecars live for --source runs/both "
                             "(default: recording.output_dir)")
    parser.add_argument("--iters", type=int, default=DEFAULT_ITERS)
    parser.add_argument("--num-layers", type=int, default=DEFAULT_LORA_LAYERS)
    parser.add_argument("--max-seq-length", type=int, default=DEFAULT_MAX_SEQ_LENGTH,
                        help="training context budget; meetings that do not fit are "
                             f"dropped rather than truncated (default: {DEFAULT_MAX_SEQ_LENGTH})")
    parser.add_argument("--force", action="store_true",
                        help="train even when the corpus is below the readiness bar")
    parser.add_argument("--dry-run", action="store_true",
                        help="build the dataset and print the training command without running it")
    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    # Local-only: no secrets, guard armed. Training never egresses.
    cfg = entry.prepare(secrets=False)
    model = args.model or cfg.summarization.local_model
    recordings_dir = args.recordings_dir or cfg.recording.output_dir

    all_pairs = collect_pairs(
        args.source,
        corrections_dir=corrections.CORRECTIONS_DIR,
        recordings_dir=Path(recordings_dir).expanduser(),
        system_prompt=base_system_prompt(
            cfg.summarization.team_context, cfg.summarization.summary_language
        ),
    )
    pairs, too_long = fit_to_budget(all_pairs, args.max_seq_length)
    if too_long:
        log.warning(
            "dropped %d of %d meetings that exceed --max-seq-length %d "
            "(longest ~%d tokens); raise it to keep them, at the cost of memory.",
            len(too_long), len(all_pairs), args.max_seq_length,
            int(max(p.chars() for p in too_long) / CHARS_PER_TOKEN),
        )

    ready, state = gate_ready(args.source, pairs)
    if not ready and not args.force:
        hint = (
            "Grade more meetings (see `mp corrections-stats`), try `--source runs` to "
            "distil the summaries already on disk, or pass --force."
            if args.source == "corrections"
            else "Summarize more meetings, or pass --force."
        )
        sys.stderr.write(f"corpus not ready for training ({args.source}): {state}. {hint}\n")
        return 2

    if len(pairs) < 2:
        sys.stderr.write(
            f"need at least 2 usable {args.source} pairs with readable transcripts; "
            f"found {len(pairs)}.\n"
        )
        return 2

    data_dir = args.data_dir or (args.adapter_path / "data")
    splits = split_pairs(pairs)
    write_dataset(splits, data_dir)
    manifest = write_split_manifest(
        splits, args.adapter_path, source=args.source, model=model
    )
    log.info(
        "wrote %d pairs (train=%d valid=%d test=%d) to %s; split manifest %s",
        len(pairs), len(splits["train"]), len(splits["valid"]), len(splits["test"]),
        data_dir, manifest,
    )

    cmd = build_lora_command(model, data_dir, args.adapter_path, args.iters,
                             args.num_layers, args.max_seq_length)
    if args.dry_run:
        print(" ".join(cmd))
        return 0

    args.adapter_path.mkdir(parents=True, exist_ok=True)
    log.info("training adapter: %s", " ".join(cmd))
    result = subprocess.run(cmd, check=False)
    if result.returncode == 0:
        held_out = [p.stem for p in splits["test"] if p.stem]
        log.info(
            "adapter written to %s. A/B it on a held-out meeting (%s), then opt in via "
            "summarization.local_adapter_path if it wins: mp dogfood --adapter %s <transcript>",
            args.adapter_path,
            ", ".join(held_out[:3]) if held_out else "none reserved, corpus too small",
            args.adapter_path,
        )
    return result.returncode
