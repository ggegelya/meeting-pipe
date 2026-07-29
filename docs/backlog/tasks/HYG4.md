# HYG4: Retire the dead CLI surfaces: publish-notion verb, classify-meetings

Band origin: filed 2026-07-29 (owner exploratory sweep, item 16: the invisible-capability inventory turned up two verbs that are neither surfaced nor exempt). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md). P3: hygiene, promote on demand (the HYG band's normal shape).

## Context

The de-CLI standing rule (2026-07-10 delegation notes) says the CLI is a debugging escape hatch, with a named exempt list of owner-dev diagnostics (dogfood, analyze-detection, corrections-stats, train-adapter, spike harnesses). Two registered verbs fail it without being exempt:

- **`publish-notion`**: the legacy single-sink publish, superseded by `publish` + the router fanout; the README (:212) itself calls it "the legacy single-sink escape hatch". Harmless but a dead surface that shows up in `mp --help` beside the real one. Important nuance for the cleanup: the MODULE is live (`publish_notion.py` hosts `NotionRestPublisher`, which `publish_router.fanout` consumes); only the verb registration and its usage-text row are dead.
- **`classify-meetings`**: self-described as the AI5 spike ("AI5 spike", `__main__.py:59-61`). AI5 closed NO-GO on 2026-07 (a derived `meeting_type` field: the labels it measured agreed on 1 of 10 types across 193 real meetings; the backlog's Intelligence band narrative records it as the standing answer). The verb therefore advertises a capability the product explicitly decided against, and it is not on the exempt list. The `classify.py` module, its `_LLM_SYSTEM` prompt, and its tests exist solely for it.

The precedent is HYG1's `ai2_spike` retirement: module + tests + dispatch + docs removed in one commit once the spike's answer was banked elsewhere.

## Scope

- Remove the `publish-notion` verb registration and its usage-text row from `__main__.py`; keep `publish_notion.py` (the publisher implementation) untouched. A stale-verb note in the module docstring pointing at `mp publish` is optional politeness.
- Delete `classify.py`, its tests, its dispatch entry, and its usage row (the HYG1 shape). If anything imports it beyond `__main__` (grep first), that consumer decides: today's evidence says nothing does.
- Update the ARCHITECTURE.md subcommand table in the same commit (the DOC7 rule: that table went 17 modules stale once; do not re-start the drift). README mentions likewise.
- Confirm the de-CLI exempt list needs no edit (neither verb belongs on it; the fix is removal, not exemption). If the owner would rather keep `classify-meetings` for a future experiment, the alternative is adding it to the exempt list with a note; recorded so the pickup asks once instead of guessing.

## Explicitly not in scope

`cleanup-diarization` (a live product capability; DIAR3, filed the same day, gives it UI rather than deleting it). Any change to `publish_router`, the Notion publisher, or the exit-3 contract. Retiring other exempt diagnostics.

## Acceptance

`mp publish-notion` and `mp classify-meetings` report unknown command; `mp publish` still publishes (existing tests); no dangling imports (ruff F401 is CI-fatal, so the suite run is the fence); the ARCHITECTURE subcommand table and README no longer list either verb.

`cd pipeline && uv run --extra dev ruff check src tests`, `pyright`, `pytest -q` green. Truth fences green. Repo dash guard green.
