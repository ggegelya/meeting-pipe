---
id: SEC41
title: Action-item due dates, owners and attendees still reach the Markdown sinks unscrubbed, so the beacon SEC28 closed still works through them
category: Security
status: partial
priority: P2
comment: Shipped 2026-11-17: `ActionItem.due` (`clean_due`), `group` (`clean_text`) and `clean_person` (drops any value `clean_text` would change, entity-encoded schemes included) with 15 new red-before tests in test_sec28_sanitize.py. Nothing is owed by the owner; close when satisfied.
---

# SEC41: Action-item due dates, owners and attendees still reach the Markdown sinks unscrubbed, so the beacon SEC28 closed still works through them

Band origin: filed 2026-11-17 (post-audit fix review, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Found by the [post-audit fix review](../../audits/2026-11-17-post-audit-fix-review.md) (privacy report, M2), confirmed by reading the code at `78b72306`. SEC28 was closed as done on 2026-11-16; for these three fields its fix does not hold, because its field list omitted them.

- `pipeline/src/mp/schemas.py`, `ActionItem`: `due: str | None = None` has no validator; the tool schema describes it only as "ISO 8601 date if extractable."
- `pipeline/src/mp/markdown.py`, `render_summary_md`: `due = f" - due {a.due}" if a.due else ""`, written into the action line.
- `pipeline/src/mp/publish_obsidian.py`, `_format_action`: `suffix = f"  (due: {due})" if due else ""`.
- `pipeline/src/mp/prompt_safety.py`, `clean_person`: rejects only an `@`, a control character or `_URLISH = re.compile(r"https?://|www\.", re.IGNORECASE)`. CommonMark decodes entity references inside a link destination, so an image link whose scheme is entity-encoded passes and is rendered in the bold owner slot and on the Attendees line.
- `mp digest` copies `due` and builds headings from `group`.

Scenario: a participant dictates a due date that is a Markdown image pointing at a remote host; a compliant model writes it into `due`; the note fetches it when opened. Under NDA or regulated mode the filesystem sink still publishes, so this is the zero-egress leak SEC28 exists to close. Not executed; the entity rule is CommonMark's and remote-image loading in the viewer is SEC28's own premise.

`test_sec28_sanitize.py` never mentions `due`, `group`, `owner` or `attendees`.

## Scope

1. `ActionItem.due`: accept a date shape only (fallback to `None`), or run `clean_text`.
2. `clean_person`: run `clean_text` inside it, or reject `[`, `]`, `(`, `<` and `&` in a name.
3. `group` in the digest path: `clean_text`.

## Explicitly not

- Re-scrubbing fields SEC28 already covers.
- Changing how the Swift renderers treat links (SEC30 owns that).

## Acceptance

- `test_sec28_sanitize.py`: an image link, an entity-encoded image link and an HTML image tag in each of `due`, `owner`, `attendees` and `group` produce no live image, link or tag in `render_summary_md`, the Obsidian note and the digest. At least 6 new tests, each failing on the code before the change.
- `cd pipeline && uv run --extra dev pytest -q` green; ruff and pyright clean.
- SEC28's file gets a one-line note pointing here.

**Progress (2026-11-17):** all three scope items shipped. `due` takes `clean_text` and is dropped when empty or over 80 characters (a date-only shape would have lost "end of week", which `mp actions` already tolerates by ordering undated and unparseable values last). `clean_person` rejects rather than defuses: a name with a link, image or tag is injected by definition, and plain brackets and parentheses in a real name still pass. `group` is scrubbed in `ActionItem`'s validator, so the digest, the renderer and any reader inherit it. The 15 new cases fail on the previous code and pass now. No owner action is owed; the owner can close this and decide whether SEC28 returns to partial.
