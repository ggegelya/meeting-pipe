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
  summarize <transcript.md>   Summarize per config backend (anthropic/local/auto) -> <stem>.summary.json/.md
  publish <summary.json>      Fan an existing summary out to all configured
                              sinks (used by the Apple Intelligence backend)
  publish-notion <summary.json>
                              Publish summary to Notion (idempotent)
  publish-from-paste <transcript.md>
                              Parse <stem>.summary.md you wrote by hand,
                              then publish to Notion (BYO summary mode)
  run-all <wav>               Run summarize + publish on the daemon-produced
                              `<stem>.json`. ASR + diarization live in Swift
                              (FluidAudio) and are NOT invoked here.
  cleanup-diarization <transcript.json>
                              LLM pass that merges same-speaker labels and
                              reattributes obvious mistakes, then rewrites
                              `<stem>.json`/.md (TECH-DIAR1)
  doctor                      Preflight check (secrets, config, live API access)
  logs [--since 1h] [--category C] [--action A] [--json]
                              Filter and pretty-print JSONL event streams
  dogfood <transcript.md>     Run Anthropic + local backends side-by-side
  dogfood --report            Aggregate scored runs into a ship-decision report
  prefetch-model <repo_id>    Pre-download a local-mode MLX model (JSONL progress)
  serve-local                 Start a persistent mlx_lm.server for the configured
                              local model and block (launch-time warm path)
  corrections-stats [--dir P] [--json]
                              Aggregate the local correction corpus (Phase 2)
  analyze-detection [--since 7d] [--source PATH] [--output FILE] [--json]
                              Audit detector end-signal reliability
  ask <question...> [--context-tokens N] [--model M] [--rebuild] [--dir P] [--out F] [--json]
                              Ask a natural-language question about your meetings;
                              engine-backed, cited answers over the on-device
                              embedding index (honours the backend + egress clamp)
  actions [--owner N] [--due-before D] [--min-confidence C] [--json]
                              List open action items across all your meetings
  digest [--since N] [--publish] [--dir P] [--out-dir P] [--json]
                              Weekly review digest of aging open actions +
                              recent decisions, generated on-device; writes to
                              disk and (with --publish) fans out to the sinks
  ai2-spike [--sizes 4000,8000,16000] [--repeats N] [--index-only]
                              Spike: build an on-device embedding index and
                              measure long-context RAG latency + faithfulness

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

    # Lazy imports: keep `mp --help` and `mp --version` cheap; the
    # summarize / publish stages pull in anthropic + httpx + pydantic
    # only when actually invoked.
    if cmd == "summarize":
        from .summarize import main as run
        return run(rest)
    if cmd in {"serve-local", "serve_local"}:
        from .summarize_local import main as run
        return run(rest)
    if cmd == "publish":
        from .publish_cmd import main as run
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
    if cmd in {"cleanup-diarization", "cleanup_diarization"}:
        from .diarize_cleanup import main as run
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
    if cmd in {"analyze-detection", "analyze_detection"}:
        from .analyze_detection import main as run
        return run(rest)
    if cmd == "ask":
        from .ask import main as run
        return run(rest)
    if cmd == "actions":
        from .actions import main as run
        return run(rest)
    if cmd == "digest":
        from .digest import main as run
        return run(rest)
    if cmd in {"ai2-spike", "ai2_spike"}:
        from .ai2_spike import main as run
        return run(rest)

    print(f"unknown subcommand: {cmd}\n", file=sys.stderr)
    print(USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
