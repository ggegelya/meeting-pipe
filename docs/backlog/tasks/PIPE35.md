# PIPE35: the digest, `mp actions`, the MCP tools and the prep card skip every summary or sidecar they cannot read without a log line or a count, so with an iCloud-evicted library their answers are silently partial

Band origin: filed 2026-10-25 from the 2026-10-25 observability audit band ([observability audit](../../audits/2026-10-25-observability-audit.md) O21: PY-6). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Verified in code on 2026-10-25 against `main` at `01e904a`. The pipeline's library-wide readers each carry their own copy of the same tolerant read, and none of them logs or counts what it dropped:

- `actions.discover` (open actions for `mp actions`, the digest, and the MCP `list_actions` tool): `try: obj = json.loads(summary_json.read_text(...)) except (OSError, ValueError): continue`.
- `digest.collect_recent_decisions`: the same `except (OSError, ValueError): continue`.
- `mcp_tools._summary` (behind `get_meeting` and every `list_meetings` row): `except (OSError, ValueError): return {}`. `get_meeting` then answers with empty points, decisions and actions for a meeting whose transcript exists, which a client cannot tell from a meeting that genuinely has none.
- `prep._read_json` (the "last time" prep card, over both the meta sidecar and the summary of each candidate): returns `None`, and `candidates` / the card builder `continue` to the next, older meeting.
- `embed_index._read_title`: `except (OSError, ValueError): pass`, so a citation shows the stem instead of the title.

`digest_generated` (`events.emit("pipeline", "digest_generated", actions=..., actions_in_window=..., actions_open=..., decisions=..., ...)`) carries no skipped count, and `mp digest --json` none either. AI10 added the window and library totals exactly so a digest "that hid 900 items is visible in the event log"; a digest that could not read 40 meetings is not.

**The read failure is real in this library.** `pipeline.log` on 2026-10-16 12:46:34 (local time) shows two `[Errno 11] Resource deadlock avoided` reads of `~/Documents/Meetings/raw/*.meta.json`, which is what an iCloud-evicted (dataless) file returns. With the library in iCloud (STOR6, verified for this Mac), the scheduled digest then omits those meetings' open actions and decisions, the MCP tools answer from a subset, and the prep card recaps an older meeting, and nothing says how many were skipped. No digest, MCP or prep run with a skip is visible on this Mac, and none could be, since skips are not logged.

**Narrowed from the audit row.** Two readers it named behave differently in code:

- `mp ask` does not answer from a partial corpus. `embed_index.chunk_stem` reads `<stem>.summary.md` and `<stem>.md` with no `try`, so an unreadable file raises out of the index refresh, `ask.main` catches it as a failure and reports it. That is loud, not silent (one evicted file failing every `mp ask` is STOR6's dataless handling, not this task). Only its title lookup is silent, and that is in scope here.
- The AI6 prior-meeting scan in `summarize` reads the meta sidecar through `workflow.read_meta`, which logs `Workflow meta sidecar at ... is malformed` (the 2026-10-16 lines above), and logs `AI6: skipping unreadable prior summary` for the summary. It is logged; what it lacks is a fail-closed rule for the meta sidecar, which is SEC25's.

## Scope

1. **One tolerant reader.** `storage.read_library_json(path, tally) -> dict | None` in `mp/storage.py`: `None` for a missing file (not counted), `None` plus a tally entry for an `OSError` (keyed by `errno.errorcode` name, so `EDEADLK`, `EACCES`) or a parse error (`unparseable`), and the dict otherwise. `tally` is a small `UnreadableTally` (a `Counter` plus a `total` property and `as_dict()`); when it is non-empty at the end of a command, that command logs one WARNING: "skipped 2 unreadable files (EDEADLK: 2) under <root>".
2. **Migrate the five readers above** to it, passing one tally per command run. No behaviour change for a readable library.
3. **Report it where the answer goes.** `digest_generated` gains `skipped_unreadable` (the total) and `mp digest --json` gains `skipped_unreadable` as the by-reason dict; `digest.scope_section` (the section that already keeps a bounded digest honest) adds "N meetings could not be read" when non-zero, and returns a section for that case even when nothing else was trimmed, so the reader of the digest sees it too. `mp actions --json` gains the same key. The MCP `list_actions` and `list_meetings` responses gain `skipped_unreadable`, and `get_meeting` returns `{"stem", "unreadable": "<reason>"}` for an unreadable summary instead of an empty one.
4. **Docs.** CONVENTIONS' MCP sections (beside "Tool arguments are closed (AUTO5)") name the new response keys; GUIDE.md's Digests recipe says what the new line means, in the same commit.

## Explicitly not / out of scope

- Materializing evicted files before reading (`brctl download`, `NSFileCoordinator`): STOR6. This task makes the gap countable; STOR6 closes it.
- `workflow.read_meta` and NDA routing on an unreadable meta sidecar: SEC25, a sibling in this band. `prep` and `visibility` read the meta sidecar through their own paths; switching `prep`'s meta read to SEC25's reader once it lands is a one-line follow-up, named there.
- Per-meeting user-data overlays read as empty during summarize: STOR9. Run and publish sidecars: PIPE34.
- The Swift Library's own scans: STOR11 (unreadable folder) and SEC25.

## Acceptance

- pytest for `storage.read_library_json`: missing returns `None` and counts nothing; an `OSError` with `errno.EDEADLK` (monkeypatched `read_text`) counts under `EDEADLK`; invalid JSON counts under `unparseable`; the end-of-run WARNING appears once with the totals.
- `test_digest.py`: a library of three summaries with one raising `EDEADLK` yields a digest from two, `digest_generated` carrying `skipped_unreadable=1`, the JSON carrying `{"EDEADLK": 1}`, and `scope_section` naming it. Fails on `main`.
- `test_actions.py`, `test_prep.py`, `test_embed_index.py`: the same injected failure is counted, and `prep` still falls through to the older meeting.
- `test_mcp_serve.py` (or a `mcp_tools` unit test): `get_meeting` on an unreadable summary returns `unreadable` rather than empty lists; `list_actions` reports the skip count.
- `cd pipeline && uv run --extra dev pytest -q` green, `uv run --extra dev ruff check src tests` and `uv run --extra dev --extra mcp pyright` clean, `python3 scripts/truth_fences.py` green, N new tests in the commit body.
