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
  summarize <transcript.md>   Summarize per config backend -> <stem>.summary.json/.md
                              [--backend anthropic|local|auto] re-summarizes on
                              a one-shot backend (regulated/NDA still force local)
  publish <summary.json>      Fan an existing summary out to all configured
                              sinks (used by the Apple Intelligence backend)
  publish-from-paste <transcript.md>
                              Parse <stem>.summary.md you wrote by hand,
                              then publish to Notion (BYO summary mode)
  run-all <wav>               Run summarize + publish on the daemon-produced
                              `<stem>.json`. ASR + diarization live in Swift
                              (FluidAudio) and are NOT invoked here.
                              [--backend ...] as for summarize.
  finalize <wav>              Re-run only stage 1 of run-all over the daemon's
                              `<stem>.json`: speaker labels, voiceprint + roster
                              match, embeddings sidecar, glossary. No summarize,
                              no publish, no egress (ASR3 re-transcribe ratchet)
  merge-meetings <primary.wav> <fragment.wav> [<fragment.wav>...]
                              Concatenate a dropped-and-rejoined call's stems
                              into one meeting under the primary: merge audio +
                              transcripts (with a gap marker), re-summarize, and
                              republish (upsert). The daemon soft-deletes the
                              fragments after a clean run (FEAT9).
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
  train-adapter --adapter-path P [--model M] [--iters N] [--force] [--dry-run]
                              Fine-tune a local LoRA adapter on the corrections
                              corpus, on-device (Phase 3)
  analyze-detection [--since 7d] [--source PATH] [--output FILE] [--json]
                              Audit detector end-signal reliability
  ask <question...> [--context-tokens N] [--model M] [--rebuild] [--dir P] [--out F] [--json]
                              Ask a natural-language question about your meetings;
                              engine-backed, cited answers over the on-device
                              embedding index (honours the backend + egress clamp)
  actions [--owner N] [--due-before D] [--min-confidence C] [--cluster] [--json] [--out F]
                              List open action items across all your meetings;
                              --cluster groups a workflow's restatements of one
                              commitment into a single entry (AI7)
  prep <workflow> [--dir P] [--json]
                              Recap the last meeting recorded under a workflow:
                              its opening summary points and the actions it
                              left open (the prompt panel's "Last time" card)
  roster {enroll,list,forget,rename} ...
                              Manage named-speaker voiceprints: name an
                              unknown THEM-A cluster so a recurring person
                              surfaces by name across meetings (FEAT3-ROSTER)
  backup <dir> [--no-audio]   Archive the library, config, workflows, roster, and
                              corrections into a dated tar.gz, plus a manifest
                              naming the Keychain items (values never exported)
  restore <archive> [--dry-run] [--force] [--json] [--out P]
                              Unpack a backup into this Mac's configured roots;
                              --dry-run --json prints the plan (per-root counts,
                              what would be replaced) instead of restoring
  digest [--since N] [--publish] [--dir P] [--out-dir P] [--json]
                              Weekly review digest of aging open actions +
                              recent decisions, generated on-device; writes to
                              disk and (with --publish) fans out to the sinks
  mcp-serve [--dir P] [--index-dir P] [--status [--json]]
                              Read-only MCP server over the library, on stdio
                              (never a port). Five tools: search_meetings,
                              get_meeting, get_transcript, list_meetings,
                              list_actions. NDA meetings and meetings with no
                              recorded privacy stance are withheld. Off unless
                              `[mcp] enabled`; --status prints what it exposes

Globals:
  --help, -h                  Show this message
  --version                   Print version
"""

# Ctrl-C. The shell's convention for "killed by SIGINT" is 128 + 2 (PIPE13).
# Deliberately outside the exit vocabulary the daemon reads: 3 is the
# all-sinks-failed publish contract (`publish_router.EXIT_PUBLISH_FAILED`,
# mirrored by `PipelineLauncher.publishFailedExitCode`), 2 is usage, 1 is any
# other failure. `SinkDispatcher.stage(for:)` branches on 3 alone, so 130 falls
# into its generic arm and reads as a plain pipeline failure, never as a publish
# that landed nowhere.
EXIT_INTERRUPTED = 130

# A managed secret was missing and no stage could work around it (PIPE16).
# Deliberately 2, the same code `require_env`'s old `sys.exit(2)` returned, so
# the fail-fast contract at the CLI boundary is byte-identical to what it was;
# what changed is only that it can no longer escape a run's handlers on its way
# out. It shares the usage code, which is imprecise but is the behaviour that
# shipped, and both alike fall into `SinkDispatcher.stage(for:)`'s generic arm
# since 3 is the only code Swift branches on.
EXIT_MISSING_SECRET = 2

# The one command whose interrupt is worth a second clause. `mp ask` checkpoints
# the embedding index as it builds (AI11), so a Ctrl-C there is resumable, and
# that is the non-obvious part after a run long enough to want stopping.
_INTERRUPT_NOTES = {
    "ask": "the index keeps what it finished, so the next run resumes from there",
}


def _interrupt_line(cmd: str) -> str:
    """The single stderr line a Ctrl-C prints, naming what was interrupted."""
    note = _INTERRUPT_NOTES.get(cmd)
    return f"mp {cmd}: interrupted" + (f"; {note}" if note else "")


def _dispatch(cmd: str, rest: list[str]) -> int:
    """Route one subcommand to its module's `main(argv)`.

    Split out of `main` so a single `except KeyboardInterrupt` covers every
    branch: every subcommand is a `main(argv) -> int` reached through here, so
    one handler serves all of them and none has to learn about interrupts.
    """
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
    if cmd in {"publish-from-paste", "publish_from_paste"}:
        from .publish_from_paste import main as run
        return run(rest)
    if cmd in {"run-all", "run_all"}:
        from .orchestrate import main as run
        return run(rest)
    if cmd == "finalize":
        from .finalize import main as run
        return run(rest)
    if cmd in {"merge-meetings", "merge_meetings"}:
        from .merge_meetings import main as run
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
    if cmd in {"train-adapter", "train_adapter"}:
        from .train_adapter import main as run
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
    if cmd == "prep":
        from .prep import main as run
        return run(rest)
    if cmd == "digest":
        from .digest import main as run
        return run(rest)
    if cmd in {"mcp-serve", "mcp_serve"}:
        from .mcp_serve import main as run
        return run(rest)
    if cmd == "roster":
        from .roster_cmd import main as run
        return run(rest)
    if cmd == "backup":
        from .backup import main as run
        return run(rest)
    if cmd == "restore":
        from .restore import main as run
        return run(rest)

    print(f"unknown subcommand: {cmd}\n", file=sys.stderr)
    print(USAGE, file=sys.stderr)
    return 2


def main() -> int:
    from .config import MissingSecretError

    argv = sys.argv[1:]

    if not argv or argv[0] in {"-h", "--help", "help"}:
        print(USAGE)
        return 0

    if argv[0] == "--version":
        from . import __version__
        print(f"mp {__version__}")
        return 0

    cmd, rest = argv[0], argv[1:]

    try:
        return _dispatch(cmd, rest)
    except MissingSecretError as e:
        # PIPE16: `require_env` used to `sys.exit(2)` from library code, which is
        # a `BaseException` and so escaped every `except Exception` a run is
        # wrapped in, taking the `run_failed` event, the exit-3 mapping and the
        # `<stem>.publish.json` write with it. The fail-fast it was reaching for
        # belongs here, at the boundary, for the same reason the interrupt handler
        # below does: one handler serves every subcommand and none has to learn
        # about it. A stage that owns a recovery catches it before this (the
        # publish fan-out records the sink as failed and runs the others), so what
        # reaches here is a secret nothing could work around.
        print(f"ERROR: {e}", file=sys.stderr)
        return EXIT_MISSING_SECRET
    except KeyboardInterrupt:
        # No cleanup, no `finally`, no rollback: what the interrupt leaves on
        # disk is the feature. `mp ask`'s partial index is what lets the next
        # run resume (AI11; owner-verified 2026-07-31, interrupted at 112 stems
        # and resumed at 112), and tidying up here would destroy exactly that,
        # invisibly, with the damage showing only on the following run. Ctrl-C
        # is a supported way to stop a long run, so it says one line and leaves.
        print(_interrupt_line(cmd), file=sys.stderr)
        return EXIT_INTERRUPTED


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
