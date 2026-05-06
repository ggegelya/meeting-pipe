"""`mp` CLI entry point.

Subcommands route to the matching module's `main(argv)` so each step is
runnable in isolation (debugging, retries, manual fixes).
"""
from __future__ import annotations

import sys

USAGE = """\
mp — meeting-pipe pipeline

usage: mp <subcommand> [args...]

Subcommands:
  transcribe <wav>            Transcribe + diarize → <stem>.json + <stem>.md
  transcribe-stream ...       Long-running streaming transcribe (daemon-spawned)
  summarize <transcript.md>   Anthropic summarization → <stem>.summary.json/.md
  publish-notion <summary.json>
                              Publish summary to Notion (idempotent)
  publish-from-paste <transcript.md>
                              Parse <stem>.summary.md you wrote by hand,
                              then publish to Notion (BYO summary mode)
  run-all <wav>               Run all three in order, fail-fast
  doctor                      Preflight check (secrets, config, live API access)
  logs [--since 1h] [--category C] [--action A] [--json]
                              Filter and pretty-print JSONL event streams
  dogfood <transcript.md>     Run Anthropic + local backends side-by-side
  dogfood --report            Aggregate scored runs into a ship-decision report
  prefetch-model <repo_id>    Pre-download a local-mode MLX model (JSONL progress)
  corrections-stats [--dir P] [--json]
                              Aggregate the local correction corpus (Phase 2)

Globals:
  --help, -h                  Show this message
  --version                   Print version
"""


def main() -> int:
    argv = sys.argv[1:]

    if not argv or argv[0] in {"-h", "--help", "help"}:
        print(USAGE)
        return 0

    if argv[0] == "--version":
        from . import __version__
        print(f"mp {__version__}")
        return 0

    cmd, rest = argv[0], argv[1:]

    # Lazy imports — `mp --help` and `mp --version` shouldn't pay the
    # transcription dependency cost (torch + whisperx are heavy).
    if cmd == "transcribe":
        from .transcribe import main as run
        return run(rest)
    if cmd in {"transcribe-stream", "transcribe_stream"}:
        from .transcribe_stream import main as run
        return run(rest)
    if cmd == "summarize":
        from .summarize import main as run
        return run(rest)
    if cmd in {"publish-notion", "publish_notion"}:
        from .publish_notion import main as run
        return run(rest)
    if cmd in {"publish-from-paste", "publish_from_paste"}:
        from .publish_from_paste import main as run
        return run(rest)
    if cmd in {"run-all", "run_all"}:
        from .orchestrate import main as run
        return run(rest)
    if cmd == "doctor":
        from .doctor import main as run
        return run(rest)
    if cmd == "logs":
        from .logs_cmd import main as run
        return run(rest)
    if cmd == "dogfood":
        from .dogfood import main as run
        return run(rest)
    if cmd in {"prefetch-model", "prefetch_model"}:
        from .prefetch_model import main as run
        return run(rest)
    if cmd in {"corrections-stats", "corrections_stats"}:
        from .corrections import main as run
        return run(rest)

    print(f"unknown subcommand: {cmd}\n", file=sys.stderr)
    print(USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
