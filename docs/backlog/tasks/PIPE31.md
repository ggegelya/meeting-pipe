---
id: PIPE31
title: Republishing an Obsidian note with a changed body on a later day writes a second note and orphans the first, and file_url mis-encodes #, % and ?
category: Pipeline
status: done
priority: P2
closed: 2026-11-26
comment: Shipped 2026-11-18 (reuse recorded note_path, stem-led Unicode slug, date from the stem, one as_uri helper, target-and-exists skip on all three local sinks); 2026-11-26 second fix review closed: a reused note path must resolve into the configured folder (folder change, .. and symlinks refused) and every note ends with a stem marker, so a note naming another stem is not rewritten; 5 new obsidian tests (7 cases), ci-local green; owner removes the orphan notes the old naming already left in the vault
---

# PIPE31: Republishing an Obsidian note with a changed body on a later day writes a second note and orphans the first, and file_url mis-encodes #, % and ?

Band origin: filed 2026-10-25 from the 2026-10-25 code-quality audit band ([code-quality audit](../../audits/2026-10-25-code-quality-audit.md) PIPE31, finders PY7 and PY8). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

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

## Amendment 2026-11-13 (audit band)

Sources: [independent audit](../../audits/2026-11-12-independent-audit.md) F015 and F090, and [field evidence](../../audits/2026-11-13-field-evidence.md) (Pipeline and publishing, "Obsidian notes for non-Latin titles lose their names"). Re-verified in code at HEAD on 2026-11-13; nothing below has changed since this task was filed.

**Same title, same UTC day, one file (F015).** `ObsidianPublisher._compute_note_path` still builds `f"{date} {title_slug}"` with `date = _today_iso()`, and the recording stem is used only when the slug is empty (`... if title_slug else stem`), so the name carries nothing unique to the recording. Two meetings with the same `meeting_title` published on one UTC day (two same-named calls, or last week's regenerated on the day this week's publishes) resolve to one path, and `note_path.write_text(body)` replaces the first. The first meeting's `<stem>.obsidian.json` still records the shared path and its own `body_sha256`, so republishing it returns `idempotent: True` with a URL to the other meeting's note. Scope item 1 as filed does not close this: reusing the recorded `note_path` keeps both stems pointed at the one file once they collide, and item 2's date-from-stem still collides for two same-titled meetings on one day.

**Non-Latin titles lose their names (field).** `_slugify` lowercases and then applies `_SLUG_RE = re.compile(r"[^a-z0-9]+")`, which turns every Cyrillic letter into a hyphen. In the field pack all 12 Ukrainian-language summaries (stems from 20260916-170730 to 20261111-155951) got degraded note names: 4 fell back to the bare stem, 3 are the date plus one Latin token, 5 the date plus two or more. The slug keeps a median 9.1 percent of the title's length for those 12, against 93.0 percent for the 98 English notes. 110 of 110 notes have distinct names and no two titles are identical, so F015's overwrite has not happened on this Mac yet.

**All three local sinks skip on content alone (F090).** The Obsidian skip compares `body_sha256` only: the sidecar records `vault` and `note_path`, and neither is compared (item 1 above adds the existence check for Obsidian only). `FilesystemPublisher.upsert` and `LanPublisher.upsert` do the same with `signature_sha256`, and both run `mkdir(parents=True, exist_ok=True)` on the configured directory first, so after a changed `filesystem.output_dir` (or LAN mount) the new directory is created empty, nothing is written, the sink reports `idempotent: True`, and the landing URL is the old `summary_path`. A deleted summary file is skipped the same way. [PIPE23](./PIPE23.md) calls these sinks "idempotent by path", which is the property they lack. Field: 0 idempotent skips in 70 Obsidian completions since 2026-09-29, because the owner has never republished; latent, not observed.

### Scope additions

4. **A name unique by construction, in any script.** For a note with no reusable recorded `note_path` (item 1), `_compute_note_path` builds the filename from the recording stem plus the title slug (for example `<stem> <slug>.md`, falling back to `<stem>.md` for an empty slug), so two recordings can never share a path. The slug becomes Unicode-aware: keep letters and digits in any script (a `\w`-class pattern on the lowercased title, underscores folded to hyphens), still strip path separators and characters Obsidian or the filesystem reject, still capped at 80 characters. Existing notes keep their names through item 1; nothing is renamed. The front-matter `date:` still comes from the stem per item 2.
5. **Skip only when the target is the same and still there, for all three local sinks.** In `ObsidianPublisher.upsert`, `FilesystemPublisher.upsert` and `LanPublisher.upsert`, the unchanged-hash branch returns `idempotent: True` only when the recorded target equals the freshly computed one (Obsidian: recorded `vault` equals the current vault; filesystem: recorded `output_dir`; LAN: recorded `mount_path`) and the recorded file still exists. Otherwise the sink writes as if no sidecar existed. The filesystem and LAN sinks move their `mkdir` after that decision so a skip creates nothing.
6. If [FEAT22](./FEAT22.md) step 1 or [PIPE39](./PIPE39.md) removes the LAN sink first, item 5's LAN leg is dropped with it; say so in the commit body.

### Acceptance additions

- `test_publish_obsidian.py`: a summary titled in Cyrillic produces a filename whose slug keeps the Cyrillic words (fails on `main`); two stems with the same title published with `_today_iso` patched to one day write two distinct notes, and republishing the first after the second rewrites neither and returns the first note's own path (fails on `main`); a slug containing `/` or `:` yields a single path component.
- `test_publish_obsidian.py`: an unchanged body whose sidecar records a different `vault` writes a fresh note in the current vault and reports `idempotent: False`.
- `test_publish_fs.py` and `test_publish_lan.py`: an unchanged signature with a changed output directory writes the three files there and reports `idempotent: False`; an unchanged signature whose recorded `summary_path` was deleted rewrites it; a true unchanged skip creates no directory.
- `bash scripts/ci-local.sh pipeline` green, with the number of new tests in the commit body.

## Amendment 2026-11-21 (second fix review)

Found by the [second fix review](../../audits/2026-11-21-second-fix-review.md) (pipeline-minor report, M3 and M4), confirmed by reading the code at `8426758b`.

1. `ObsidianPublisher.upsert` reuses the recorded path (`note_path = recorded or self._compute_note_path(...)`), and `_recorded_note` accepts any recorded path that `is_relative_to(self._vault)`. The sidecar does not record the folder. After the owner changes the Obsidian folder setting, an unchanged republish reports idempotent with the old folder's URL and a changed one rewrites the old note; nothing lands in the new folder. This is the audit's F090 shape left open on the one leg that is not an output directory, mount path or vault comparison. Scope: require the recorded note's parent to be the configured folder, or record and compare the folder.

2. The reused path is not checked against the stem. Under the old naming two same-titled meetings on one day share a path and both sidecars record it, so republishing either now rewrites the other's note. `is_relative_to` is also lexical, so a recorded path with `..` segments passes (hardening only: the sidecar is pipeline-written). Scope: write a stem marker into every note and check it before overwriting a reused path, falling back to the computed path when it names another stem.

Acceptance: one test per case (folder changed, legacy collision, a `..` path). Pipeline suite green, 3 new tests.

**Progress (2026-11-26): amendment 2026-11-21 shipped.** `_recorded_note` resolves the recorded path and requires its parent to be the configured folder, resolved (one check for a changed vault or folder, `..` and a symlinked directory), and returns the lexical `<vault>/<folder>/<name>`. Every note now ends with `%% meeting-pipe stem: <stem> %%`, appended outside the template and outside the idempotency hash; a reused note whose last marker names another stem falls back to the computed path. A note with no marker (every note written before this) is trusted, since refusing it would orphan it; the residual is a legacy collision nobody republished since, where the first stem to republish claims the shared note once. Tests: escape (`..` and symlinked dir), folder changed, legacy collision (unchanged and changed), unmarked note still reused, marker present under a custom template.
