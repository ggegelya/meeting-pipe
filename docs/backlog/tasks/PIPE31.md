# PIPE31: Republishing an Obsidian note with a changed body on a later day writes a second note and orphans the first, and file_url mis-encodes #, % and ?

Band origin: filed 2026-10-25 from the 2026-10-25 code-quality audit band ([code-quality audit](../../audits/2026-10-25-code-quality-audit.md) PIPE31, finders PY7 and PY8). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

All in `pipeline/src/mp/publish_obsidian.py` and `publish_fs.py`, re-read on 2026-10-25.

**The note's filename is the publish day, not the meeting.** `ObsidianPublisher._compute_note_path` builds `f"{date} {title_slug}"` with `date = _today_iso()`, and `_today_iso` is `datetime.now(timezone.utc).date().isoformat()`: the UTC date of the moment the sink runs. `upsert` then:

1. renders the body, and a canonical copy with `date` and `generated` pinned to `_HASH_PINNED_DATE` / `_HASH_PINNED_GENERATED`, and hashes the canonical copy;
2. if `<stem>.obsidian.json` records the same `body_sha256`, returns `idempotent: True` with the recorded `note_path`;
3. otherwise calls `_compute_note_path` afresh and writes there.

The pinned hash fixes the unchanged republish (`test_upsert_idempotent_across_day_boundary` pins it). It does nothing for a changed one: a regenerated summary, an edited title, a corrected speaker name or a re-run after a prompt change on any later day computes a new filename and writes a second note, while the sidecar's recorded `note_path` (read only in step 2) is overwritten to point at the new one. The first note is orphaned in the vault with no record that the pipeline wrote it. A title edit orphans the note on the same day too, because the slug is part of the filename. Reproduced on 2026-10-25 with `_today_iso` patched from `2026-10-01` to `2026-10-02` and one summary bullet added: the vault folder held `2026-10-01 sync.md` and `2026-10-02 sync.md`.

Because the date is UTC, a meeting recorded at 00:30 in a UTC+2 timezone is filed under the previous day even on its first publish, and the note's `date:` front-matter carries the same publish-day value. The module docstring still describes the old layout ("each call writes to a deterministic path (`<vault>/<folder>/<stem>.md`)").

PIPE23 scope item 3 makes the Notion sink write `Date` from the meeting's own date (the stem's `YYYYMMDD`, local). This is the same defect on the Obsidian sink, and the two should agree.

**`file://` URLs are hand-rolled twice.** `publish_fs.file_url` and `publish_obsidian._file_url` are both `"file://" + os.path.abspath(p).replace(" ", "%20")`. Only spaces are encoded. For a vault at `~/Vault #1/100% notes?/` the result is `file:///.../Vault%20#1/100%%20notes?/...`: `#` starts a fragment, `?` a query, and a bare `%` is an invalid escape. `PipelineLauncher` decodes `page_url` with `URL.init(string:)`, so the Library's Open affordance either gets no URL or a URL to a different path. `Path.as_uri()` returns `file:///.../Vault%20%231/100%25%20notes%3F/...` for the same path. `publish_lan` imports `publish_fs.file_url`, so three sinks share the defect.

## Scope

1. **Reuse the recorded note.** In `ObsidianPublisher.upsert`, when `<stem>.obsidian.json` records a `note_path` inside the current vault, the changed-body write goes to that path, whether or not the title or the day has changed. A recorded path outside the current vault (the vault setting moved) is treated as absent. The unchanged-hash branch also rewrites when the recorded note no longer exists on disk, instead of returning `idempotent: True` with a URL to a missing file.
2. **Date from the meeting.** `_compute_note_path` and the `date:` front-matter take the meeting date from the stem (`YYYYMMDD`, local, read through the same helper PIPE23 adds for Notion if it has landed, otherwise one small helper that PIPE23 then reuses), falling back to today only for a stem with no date. Correct the module docstring.
3. **One URL helper.** `publish_fs.file_url` becomes `Path(os.path.abspath(p)).as_uri()`, `publish_obsidian` imports it, and `_file_url` is deleted.

## Explicitly not / out of scope

- Renaming an existing note when the title changes. Obsidian links to a note by filename, so a rename would break the owner's wikilinks; the first filename is kept for the note's life.
- Detecting a note the owner moved inside the vault. A moved note is a new path the sidecar cannot see; this task recreates at the recorded path, which is what an explicit republish asks for.
- Deleting or merging the orphans already in the owner's vault. Name the cleanup in the commit body; the owner removes them.
- The daily-note backlink (`_append_daily_note_backlink`), which links from the publish day's daily note. Whether it should follow the meeting day is a separate owner call, observed here and not filed.
- Notion's Date and Status: PIPE23. Atomic writes of the note and sidecar: PIPE30. Reading the sidecar safely: PIPE29.

## Acceptance

- `test_publish_obsidian.py`: a first publish on one day and a changed-body publish on the next leave exactly one note in the folder, at the first path, containing the new body (fails on `main`); a title change does the same; a sidecar recording a path in a different vault writes a fresh note in the current one; an unchanged body whose recorded note was deleted rewrites it.
- `test_publish_obsidian.py`: a stem `20261001-003000` published with `_today_iso` patched to another day files the note and the front-matter `date` under `2026-10-01`; a stem with no date falls back to today.
- `test_publish_fs.py`: `file_url` on a path containing a space, `#`, `%` and `?` round-trips through `urllib.parse.urlparse` and `unquote` to the original path, with empty query and fragment.
- `bash scripts/ci-local.sh pipeline` green, with the number of new tests in the commit body.
