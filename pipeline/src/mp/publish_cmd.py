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

from .config import Config, load_secrets
from .publish_router import fanout
from .workflow import apply_overrides as apply_workflow_overrides

log = logging.getLogger("mp.publish")


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: mp publish <summary.json>", file=sys.stderr)
        return 2
    summary_json = Path(argv[0]).expanduser().resolve()
    if not summary_json.exists():
        print(f"No such file: {summary_json}", file=sys.stderr)
        return 1
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    cfg = Config.load()
    cfg = apply_workflow_overrides(cfg, summary_json)
    load_secrets()

    stem = summary_json.name.removesuffix(".summary.json")
    transcript_md = summary_json.parent / f"{stem}.md"
    pub = fanout(
        summary_json=summary_json,
        cfg=cfg,
        transcript_md=transcript_md if transcript_md.exists() else None,
    )
    failures = pub.get("failures") or []
    if failures:
        for name, err in failures:
            log.error("sink %s failed: %s", name, err)
    log.info("publish done: page_url=%s", pub.get("page_url"))
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
