"""`mp publish <summary.json>` - fan an existing summary out to all sinks.

The normal pipeline publishes inside `run-all`'s summarize+publish stage.
This standalone entry runs the same `publish_router.fanout` against a
`<stem>.summary.json` that was produced elsewhere - specifically the
Apple Intelligence backend (TECH-SUM1-APPLE), where the summary is built
in the Swift daemon and then handed back here only for publishing. The
per-workflow sink/notion overrides in `<stem>.meta.json` are honoured the
same way `mp summarize` honours them.
"""
from __future__ import annotations

import logging
import sys
from pathlib import Path

from pydantic import ValidationError

from . import entry
from .publish_router import (
    EXIT_PUBLISH_FAILED,
    build_publishers,
    fanout,
    publish_failed,
    publish_failure_reason,
    published_sinks,
    record_pre_sink_failure,
)

log = logging.getLogger("mp.publish")


def validation_message(error: ValidationError) -> str | None:
    """PIPE54: one plain sentence naming the first schema limit `summary.json` breaks and what to
    do about it, or None when the file is not a shape problem at all (it is not JSON, or not an
    object), which stays an ordinary failure so Retry can regenerate a corrupt file."""
    fix = "Edit the summary, then Republish."
    for err in error.errors():
        kind = err.get("type", "")
        if kind in {"json_invalid", "model_type"}:
            return None
        loc = err.get("loc") or ()
        ctx = err.get("ctx") or {}
        value = err.get("input")
        if loc == ("summary",) and kind == "too_long":
            return (f"The summary has {ctx.get('actual_length')} bullets; "
                    f"the limit is {ctx.get('max_length')}. {fix}")
        if loc == ("title",) and kind == "string_too_long":
            length = len(value) if isinstance(value, str) else "too many"
            return (f"The title is {length} characters; "
                    f"the limit is {ctx.get('max_length')}. {fix}")
        if len(loc) == 3 and loc[0] == "actions" and loc[2] == "confidence":
            # The value itself is not echoed: it is summary content, and this line lands in
            # error.json and publish.json.
            return f"Action {int(loc[1]) + 1}'s confidence must be low, medium or high. {fix}"
    first = error.errors()[0] if error.errors() else {}
    where = ".".join(str(p) for p in first.get("loc") or ()) or "the summary"
    return f"The summary does not match its schema at {where}: {first.get('msg', 'invalid')}. {fix}"


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: mp publish <summary.json>", file=sys.stderr)
        return 2
    summary_json = Path(argv[0]).expanduser().resolve()
    if not summary_json.exists():
        print(f"No such file: {summary_json}", file=sys.stderr)
        return 1
    entry.configure_logging()

    cfg = entry.prepare(anchor=summary_json)  # SEC13: overlay, arm, secrets

    stem = summary_json.name.removesuffix(".summary.json")
    transcript_md = summary_json.parent / f"{stem}.md"
    pubs = build_publishers(cfg)
    try:
        pub = fanout(
            summary_json=summary_json,
            cfg=cfg,
            transcript_md=transcript_md if transcript_md.exists() else None,
            publishers=pubs,
        )
    except ValidationError as error:
        # PIPE54: the summary breaks a schema limit (an editor or the Apple summarizer wrote it),
        # so no sink can run. That is a publish-stage outcome, exit 3, not a crash: an exit 1
        # landed the row at stage `pipeline`, whose Retry re-summarized over the user's edit.
        # Only here, not in `fanout`, which run-all, digest, merge and paste share.
        message = validation_message(error)
        if message is None:
            raise
        print(f"[FAIL] {message}", file=sys.stderr)
        record_pre_sink_failure(summary_json, [p.name for p in pubs], message)
        return EXIT_PUBLISH_FAILED
    failures = pub.get("failures") or []
    if failures:
        for name, err in failures:
            log.error("sink %s failed: %s", name, err)
    # PIPE1/AUD-30: the Apple Intelligence completion path runs this directly and
    # used to read `<stem>.notion.json` unconditionally on a zero exit, so an
    # all-sinks-failed publish looked like a success carrying a stale page URL.
    if publish_failed(pub):
        log.error("publish failed: %s", publish_failure_reason(pub))
        return EXIT_PUBLISH_FAILED
    log.info("publish done: sinks=%s", ",".join(published_sinks(pub)) or "local-only")  # SEC38
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
