# PIPE13: Ctrl-C on any `mp` command dumps a traceback instead of exiting

Band origin: filed 2026-07-31, observed during AI11's owner walkthrough. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

AI11's owner walkthrough, step 5, instructs the owner to interrupt an index rebuild: "let the indexing lines climb past a few hundred, then Ctrl-C". Doing so on 2026-07-31 produced this:

```
^CTraceback (most recent call last):
  File ".../bin/mp", line 10, in <module>
    sys.exit(main())
  File ".../src/mp/__main__.py", line 164, in main
    return run(rest)
  File ".../src/mp/ask.py", line 297, in main
    index = embed_index.load_or_build(
  File ".../src/mp/embed_index.py", line 777, in load_or_build
    return refresh_index(
  File ".../src/mp/embed_index.py", line 733, in refresh_index
    blocks.append(embedder.embed([c.text for c in batch_chunks], kind="passage"))
  File ".../src/mp/embed_index.py", line 260, in embed
    mx.eval(emb)  # mlx is lazy; force the compute before leaving mlx-land
KeyboardInterrupt
```

The interrupt worked correctly in every way that matters: the checkpoint survived and the next run resumed from stem 112 rather than 0, which is precisely what AI11 built. Only the exit reads as a failure.

This is not specific to `mp ask`. `grep -rn "KeyboardInterrupt" pipeline/src/` returns nothing, so no subcommand handles it, and every command long enough to be worth interrupting (`ask`, `run-all`, `prefetch-model`, `digest`, `train-adapter`) ends the same way. A documented, supported, deliberately-resumable action should not be indistinguishable from a crash, and the walkthrough that tells the owner to press Ctrl-C is the reason this is worth the small change.

## Scope

Catch `KeyboardInterrupt` once in `__main__.main`, print a single line to stderr naming what was interrupted, and return 130 (the shell convention for SIGINT, `128 + 2`). Every subcommand is dispatched through that one function as `main(argv) -> int`, so one handler covers all of them and no subcommand needs to learn about it.

For `ask` specifically the message is worth one clause about what survived, since the resume is the non-obvious part and the owner has just been told the run was long: something of the shape "interrupted; the index keeps what it finished, so the next run resumes from there".

## Explicitly not / out of scope

**The handler must not clean up.** AI11's resume works because the interrupt leaves the last checkpoint on disk; a `finally` that deleted a partial index, or a "tidy up before exiting" impulse, would break the exact behaviour the owner verified on 2026-07-31 (interrupted at 112 stems, resumed at 112). Exit and leave the disk alone.

**130 must not collide with an exit code the daemon reads.** `publish_router.EXIT_PUBLISH_FAILED` is 3 and six Swift sites branch on the publish contract; 130 is outside that vocabulary, and this task must not renumber anything that exists. Check `PipelineLauncher`'s exit-code handling treats an unknown non-zero as a generic failure rather than misreporting it.

**Not a graceful-shutdown mechanism.** No signal handlers, no cooperative cancellation, no flushing work in progress. The point is the exit line, not new behaviour on the way out.

**Not the daemon's cancel path.** UX28's in-app Cancel is a different mechanism (`pipeline_cancelled`, the job queue) and is unaffected.

## Acceptance

`test_main_cli.py` (or the existing entry-point test module) pins that a subcommand raising `KeyboardInterrupt` returns 130 from `main`, writes its one line to stderr, and prints no traceback. A second test pins that the handler is at the dispatch level by raising from a different subcommand, so the coverage cannot be read as ask-specific.

An interrupted `mp ask --rebuild` still resumes: the existing embed-index resume test stays green, and nothing in the new path touches the index directory.

`cd pipeline && uv run --extra dev ruff check src tests`, `pyright`, and `pytest -q` green. No em-dashes in changed lines.

Owner-visible check, folded into whatever walkthrough next runs an interrupt: Ctrl-C during an index rebuild prints one line, no traceback, and the next run resumes where it stopped.
