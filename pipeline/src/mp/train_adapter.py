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

Every pair is built the way the server builds its request (LOCAL27): the transcript through
``summarize.render_model_transcript`` (timestamped, both overlays, FEAT8's excerpts), the
turns through ``summarize_local.build_messages`` (schema and language reinforcement), and
the completion through ``schemas.to_model_facing``. Pair length is estimated in tokens
(``resource_guard.estimate_tokens``), the default budget is 8192 at batch 1 (LOCAL9's
measured ceiling on a 32 GB Mac), and a budget the fixed system turn alone fills is
refused with exit 2 before anything is written. The dataset files are written 0600.

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
from typing import TYPE_CHECKING

from . import corrections, egress_guard, entry, storage

if TYPE_CHECKING:
    from .summarize import RenderedTranscript

log = logging.getLogger("mp.train_adapter")

# Conservative training defaults; the owner tunes them per corpus via flags.
DEFAULT_ITERS = 300
DEFAULT_LORA_LAYERS = 16
# LOCAL27: set together from a measurement. The system turn the server sends (the
# master prompt, the schema, the language reinforcement) is about 4,100 estimated
# tokens on its own (`resource_guard.estimate_tokens`, 2026-11-19), so the old 4096
# left nothing for a transcript and every pair was dropped. LOCAL9's own run on the
# 32 GB Mac is the ceiling: a 12288 backward drove it to 4-5% free at any batch size,
# and the run that worked used 8192 at batch 1. What a step costs scales with
# batch * max-seq-length, so 8192 x 1 is fewer step-tokens than the old 4096 x 4.
# Even so, 8192 leaves about 4,000 tokens for transcript plus summary, which is a
# short meeting (roughly 10 to 15 minutes of English, less in Cyrillic); a longer
# corpus needs a bigger Mac, and the refusal and README say so rather than this
# default rising past what LOCAL9 measured.
DEFAULT_MAX_SEQ_LENGTH = 8192
DEFAULT_BATCH_SIZE = 1


CORPUS_SOURCES = ("corrections", "runs", "both")

SPLIT_MANIFEST_NAME = "split.json"


@dataclass(frozen=True)
class Pair:
    """One training example, in the three turns the local server actually exchanges."""
    prompt: str            # the user turn, from `summarize_local.build_messages`
    completion: str        # the assistant turn: the model-facing summary JSON
    system: str = ""       # the system turn, from `summarize_local.build_messages`
    stem: str = ""
    source: str = "corrections"
    transcript_chars: int = 0

    def chars(self) -> int:
        """Total characters the tokenizer will see for this example."""
        return len(self.system) + len(self.prompt) + len(self.completion)

    def tokens(self) -> int:
        """Estimated tokens for this example, each turn at its own script's rate
        (`resource_guard.estimate_tokens`, LOCAL23's measured rates)."""
        from .resource_guard import estimate_tokens

        return sum(estimate_tokens(t) for t in (self.system, self.prompt, self.completion))

    def messages(self) -> list[dict[str, str]]:
        """The example as chat turns, the layout `mlx_lm.lora`'s `ChatDataset` reads
        and the same one `LocalSummaryClient` sends at inference."""
        turns = [{"role": "system", "content": self.system}] if self.system else []
        return turns + [
            {"role": "user", "content": self.prompt},
            {"role": "assistant", "content": self.completion},
        ]


@dataclass(frozen=True)
class PromptSettings:
    """The config-level half of the system turn: team context and summary language.

    Per meeting, the trainer adds only what the meeting's own files say: FEAT8's
    flagged-moments instruction when its excerpts are in the user turn, and LOCAL7's
    language reinforcement for the transcript's language. A workflow overlay's extra
    sections or context and AI6's prior-meeting block are not rebuilt; nothing
    records them as they stood when the meeting ran.
    """
    team_context: str = ""
    summary_language: str = "auto"

    def system_prompt(self, flagged: bool = False) -> str:
        from .summarize import _load_system_prompt

        return _load_system_prompt(self.team_context, self.summary_language, flagged_note=flagged)


def _render(transcript_md: Path) -> RenderedTranscript | None:
    """The model's view of a meeting (`summarize.render_model_transcript`), or None when
    the transcript is gone or empty."""
    from .summarize import render_model_transcript

    try:
        rendered = render_model_transcript(transcript_md)
    except (OSError, ValueError):
        return None
    return rendered if rendered.text.strip() else None


def system_turn(settings: PromptSettings, target: str | None = "en") -> str:
    """The longest fixed system turn a pair can carry (flagged instruction and language
    reinforcement included), which is what `--max-seq-length` must leave room beyond."""
    from .summarize_local import build_messages

    return build_messages(settings.system_prompt(flagged=True), "", target)[0]["content"]


def base_system_prompt(team_context: str = "", summary_language: str = "auto") -> str:
    """The system turn `LocalSummaryClient` sends for a meeting with no flagged moments
    whose language is unknown: the master prompt with the configured team context and
    language directive filled in, then the schema block. A pair's own turn comes from
    `summarize_local.build_messages`, which adds the language reinforcement."""
    from .summarize_local import build_messages

    return build_messages(
        PromptSettings(team_context, summary_language).system_prompt(), "", None
    )[0]["content"]


def build_pairs(
    corrections_dir: Path,
    render: Callable[[Path], RenderedTranscript | None] = _render,
    settings: PromptSettings | None = None,
    recordings_dir: Path | None = None,
) -> list[Pair]:
    """Build training pairs from every ``edited`` correction whose transcript is
    readable; the completion is the corrected summary. Records without a corrected
    summary, or whose transcript is gone, are skipped. Filename-sorted so a re-run
    over the same corpus is stable.
    """
    prompt = settings or PromptSettings()
    pairs: list[Pair] = []
    for path in sorted(corrections_dir.glob("*.json")):
        data = storage.read_json_object(path)
        if data is None or data.get("verdict") != "edited":
            continue
        corrected = data.get("corrected_summary")
        if not isinstance(corrected, dict):
            continue
        transcript_path = data.get("transcript_path") or ""
        # LOCAL26: the record's file name is its stem, and the current library is
        # searched by it first; the stored absolute path is only a fallback.
        stem = data.get("stem") or path.stem or Path(transcript_path).stem
        found = corrections.resolve_meeting_file(stem, ".md", recordings_dir, transcript_path)
        md = found if found is not None else (Path(transcript_path) if transcript_path else None)
        rendered = render(md) if md is not None else None
        if rendered is None:
            continue
        pairs.append(_make_pair(
            stem=stem, rendered=rendered, summary=corrected, source="corrections", settings=prompt,
        ))
    return pairs


def build_run_pairs(
    recordings_dir: Path,
    render: Callable[[Path], RenderedTranscript | None] = _render,
    settings: PromptSettings | None = None,
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
    prompt = settings or PromptSettings()
    skip = exclude_stems or set()
    pairs: list[Pair] = []
    for path in sorted(recordings_dir.glob("*.run.json")):
        data = storage.read_json_object(path)
        if data is None or data.get("backend") == "local":
            continue
        stem = data.get("stem") or path.name[: -len(".run.json")]
        if stem in skip:
            continue
        # LOCAL26: by stem in this library first, so a moved or restored library keeps
        # every earlier meeting; the stored absolute paths are only a fallback.
        summary_path = corrections.resolve_meeting_file(
            stem, ".summary.json", recordings_dir, data.get("summary_json_path"))
        summary = _read_summary(
            str(summary_path) if summary_path is not None else data.get("summary_json_path") or "")
        if not summary:
            continue
        transcript_path = corrections.resolve_meeting_file(
            stem, ".md", recordings_dir, data.get("transcript_path"))
        stored = data.get("transcript_path")
        md = transcript_path if transcript_path is not None else (Path(stored) if stored else None)
        rendered = render(md) if md is not None else None
        if rendered is None:
            continue
        pairs.append(_make_pair(
            stem=stem, rendered=rendered, summary=summary, source="runs", settings=prompt,
        ))
    return pairs


def _read_summary(summary_json_path: str) -> dict | None:
    """The summary JSON a run produced, or None when absent/unreadable/empty."""
    if not summary_json_path:
        return None
    data = storage.read_json_object(Path(summary_json_path))
    return data or None


def _make_pair(
    *, stem: str, rendered: RenderedTranscript, summary: dict, source: str,
    settings: PromptSettings,
) -> Pair:
    """One pair, built the way the server builds its request (LOCAL27): the rendered
    transcript (`[mm:ss]` markers, both overlays, FEAT8's excerpts), the system prompt
    with the flagged instruction exactly when the excerpts are there, the language
    reinforcement for this transcript, all through `build_messages`. The completion is
    the summary in the `{text, evidence}` shape the schema in that system turn demands
    (`schemas.to_model_facing`), not the stored shape."""
    from .schemas import to_model_facing
    from .summarize_local import build_messages
    from .summary_language import expected_summary_language

    target = expected_summary_language(settings.summary_language, rendered.text)
    system, user = build_messages(settings.system_prompt(rendered.flagged), rendered.text, target)
    return Pair(
        prompt=user["content"],
        completion=json.dumps(to_model_facing(summary), ensure_ascii=False, indent=2),
        system=system["content"],
        stem=stem,
        source=source,
        transcript_chars=len(rendered.text),
    )


def collect_pairs(
    source: str,
    *,
    corrections_dir: Path,
    recordings_dir: Path,
    settings: PromptSettings | None = None,
) -> list[Pair]:
    """Pairs for the requested corpus source. Under ``both`` the corrections come
    first and their stems are withheld from the runs fill, so a meeting the owner
    corrected trains on the corrected summary, never on the one it replaced."""
    if source == "runs":
        return build_run_pairs(recordings_dir, settings=settings)
    corrected = build_pairs(corrections_dir, settings=settings, recordings_dir=recordings_dir)
    if source == "corrections":
        return corrected
    return corrected + build_run_pairs(
        recordings_dir,
        settings=settings,
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


def gate_ready(source: str, pairs: list[Pair], library: Path | None = None) -> tuple[bool, str]:
    """Is the corpus big enough to train on? Returns (ready, human-readable state).

    ``corrections`` keeps the ``mp corrections-stats`` bar, which is what the README
    and that command advertise, so the two keep agreeing. A ``runs``/``both`` corpus
    has no corrections-stats reading to check, so it gates on the trainable pairs it
    just built, against the same two numbers.
    """
    if source == "corrections":
        stats = corrections.aggregate(
            corrections.load_records(corrections.CORRECTIONS_DIR, library=library))
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
    # LOCAL27: owner-only, like every other library file (it names meetings).
    storage.atomic_write_text(out, json.dumps(payload, indent=2, sort_keys=True), mode=0o600)
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
        # LOCAL27: full transcripts and summaries, so owner-only (0600), atomically.
        storage.atomic_write_text(
            data_dir / f"{name}.jsonl", "\n".join(lines) + ("\n" if lines else ""), mode=0o600
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

    Length is `Pair.tokens()`, each turn at its own script's measured rate (LOCAL27;
    it was characters at a flat 2.5 per token, which overstated an English system turn
    by about 60 percent).
    """
    kept = [p for p in pairs if p.tokens() <= max_seq_length]
    dropped = [p for p in pairs if p.tokens() > max_seq_length]
    return kept, dropped


def build_lora_command(
    model: str,
    data_dir: Path,
    adapter_path: Path,
    iters: int = DEFAULT_ITERS,
    num_layers: int = DEFAULT_LORA_LAYERS,
    max_seq_length: int = DEFAULT_MAX_SEQ_LENGTH,
    batch_size: int = DEFAULT_BATCH_SIZE,
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
        "--batch-size", str(batch_size),
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
    parser.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE,
                        help="examples per step; memory scales with batch * max-seq-length, "
                             f"so raise one only by lowering the other (default: {DEFAULT_BATCH_SIZE})")
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

    settings = PromptSettings(cfg.summarization.team_context, cfg.summarization.summary_language)
    # LOCAL27: refuse before building anything when the fixed system turn alone leaves no
    # room, rather than dropping every pair and calling the corpus "not ready".
    from .resource_guard import estimate_tokens

    system_tokens = estimate_tokens(system_turn(settings))
    if system_tokens >= args.max_seq_length:
        sys.stderr.write(
            f"--max-seq-length {args.max_seq_length} leaves no room for a meeting: the system "
            f"turn the local server sends (prompt, schema and language reinforcement) is about "
            f"{system_tokens:,} tokens on its own. Raise --max-seq-length (and lower "
            f"--batch-size to keep memory flat); the default {DEFAULT_MAX_SEQ_LENGTH} at batch "
            f"{DEFAULT_BATCH_SIZE} is the most LOCAL9 measured a 32 GB Mac taking, and it fits "
            f"only short meetings.\n"
        )
        return 2

    all_pairs = collect_pairs(
        args.source,
        corrections_dir=corrections.CORRECTIONS_DIR,
        recordings_dir=Path(recordings_dir).expanduser(),
        settings=settings,
    )
    pairs, too_long = fit_to_budget(all_pairs, args.max_seq_length)
    if too_long:
        log.warning(
            "dropped %d of %d meetings that exceed --max-seq-length %d "
            "(longest ~%d tokens, of which ~%d is the system turn); raise it to keep them, "
            "at the cost of memory.",
            len(too_long), len(all_pairs), args.max_seq_length,
            max(p.tokens() for p in too_long), system_tokens,
        )

    ready, state = gate_ready(args.source, pairs, Path(recordings_dir).expanduser())
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
                             args.num_layers, args.max_seq_length, args.batch_size)
    if args.dry_run:
        print(" ".join(cmd))
        return 0

    args.adapter_path.mkdir(parents=True, exist_ok=True)
    log.info("training adapter: %s", " ".join(cmd))
    # The one spawned child here that can reach the network (it may fetch weights), so it gets
    # the scrubbed env; identical to os.environ while the guard is not armed (HYG18).
    result = subprocess.run(cmd, check=False, env=egress_guard.child_env())
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
