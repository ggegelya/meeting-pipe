# STOR7: deleting a meeting trashes its `raw/` files but leaves its published copies, its corrections, its search vectors and its voice samples behind, and the confirm says "every file"

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) PP-10). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Verified in code on 2026-10-24. Every delete path (the detail header's Delete…, the list's context menu, `BatchActionsPane`, the batch trash in `MeetingLibraryService`) ends in `MeetingLibraryService.softDeleteMeeting(stem:)`. It trashes every entry in the library directory whose `MeetingStore.stem(of:)` matches, then the kept original at `originalsDir()/<stem>.wav` (ADR 0016), removes the waveform peaks cache, and emits `meeting_deleted` with `files_count` and `original_trashed`. The confirm, `LibraryDialogs.confirmSoftDelete`, tells the user: "Every file for this meeting (audio, transcript, summary, sidecars) goes to the Trash."

What a meeting leaves behind after that, by location:

- **Published copies.** The filesystem sink writes `<output_dir>/<stem>.summary.md` and `<stem>.actions.json` (default `~/Documents/Meetings/published`), the Obsidian sink writes `<vault>/<folder>/<stem>.md`, the LAN sink writes to a mounted share, and Notion holds a page. Their locations are recorded only in the per-meeting sidecars (`<stem>.filesystem.json` carries `summary_path` and `actions_path`; `<stem>.obsidian.json` carries `note_path`; `<stem>.notion.json` carries the page id). `softDeleteMeeting` trashes those sidecars along with everything else, so the only pointers to the published copies go to the Trash and the copies themselves stay, now unfindable from the app. There is no `mp` command that archives a Notion page (`grep -rn -i "unpublish\|archived" pipeline/src` finds none).
- **The corrections corpus.** `CorrectionStore` writes `~/Library/Application Support/MeetingPipe/corrections/<stem>.json`, outside the library, and nothing deletes it. It is training data by design (`SummaryStaleness` doc comment), and `mp backup` archives it.
- **The semantic index.** `mp.embed_index` keeps chunk text and vectors under `~/Library/Caches/meeting-pipe/ai2-index`. `plan_refresh` drops a removed stem only on the next refresh, so a deleted meeting's text stays on disk and answerable by `mp ask` until something refreshes the index. The keyword index (`SearchIndexReconciler`) does drop it on its next reconcile.
- **Voice samples.** `mp.roster` stores up to 12 sample embeddings per person with no record of which meeting each came from, so a deleted meeting's samples cannot be found, let alone removed.
- **Digests and backups.** A weekly digest under `digests/` quotes the meeting; a backup archive contains it. Neither can be edited per meeting, and neither should be silently.

## Scope

1. **One enumerator of a meeting's footprint**, `MeetingFootprint.locate(stem:)` (Swift, beside `softDeleteMeeting`), returning the raw files, the kept original, the waveform cache, the corrections file, and the published copies read from the sink sidecars **before** they are trashed. Pure over an injected file system, so it is testable without a library.
2. **Delete what is local and derived**, in `softDeleteMeeting`: trash the corrections file and the local published copies (filesystem sink files, the Obsidian note) along with the raw files, and kick an index refresh (or a targeted `mp` call that drops the stem's rows) so `mp ask` stops answering from it. Add the counts to `meeting_deleted` (`corrections_trashed`, `published_trashed`, `index_pruned`).
3. **Ask about what is off the machine.** When a `.notion.json` or `.lan.json` exists, the confirm gains a checkbox, off by default, "Also remove the published Notion page / network copy". Notion archiving goes through a new `mp unpublish <stem> --sink notion` (the daemon does not call Notion; ARCH11 and HYG10 own that rule), which sets the page to archived and is idempotent on a page already gone (PIPE23's 404 handling, if it has landed). The LAN copy is a file delete on the mounted share, skipped with a notice if the share is not mounted.
4. **Name what stays.** The confirm's text lists, in one sentence, what is not removed: voice samples learned from the meeting, digests that quote it, and backups. Replace "Every file for this meeting" with the true scope. Read `docs/GUIDE.md` first and update its delete recipe in the same commit.

## Explicitly not

- Removing voice samples per meeting. That needs per-sample provenance in `roster.json`, a schema change; SEC22 owns making `roster forget` cascade and SEC24 owns voiceprint retention. Record here only that, without provenance, the confirm must say samples stay.
- Rewriting digests or backup archives. Both are point-in-time documents; the confirm names them.
- A hard delete. Every removal stays a move to the Trash, as now, except the Notion archive, which is Notion's own soft delete.
- A typed owner for the per-meeting file set. ARCH10 (`MeetingFiles`) is the structural fix; if it lands first, `MeetingFootprint` is its delete view rather than a second list of suffixes.

## Acceptance

- `MeetingFootprintTests` (MeetingPipeTests): a stem with a filesystem sidecar locates both published paths; an Obsidian sidecar locates its note; a corrections file is found; a missing sidecar yields no published paths; a stem with no kept original reports none.
- A `softDeleteMeeting` test over a scratch library and scratch published dir: after delete, the corrections file and local published copies are in the injected trash, `meeting_deleted` carries the new counts, and a sidecar pointing at a path that no longer exists does not fail the delete.
- pytest for `mp unpublish`: archives the page id from `.notion.json` through a fake client, treats a 404 as done, exits non-zero with a message when the token is missing; and a test that the targeted index prune removes the stem's rows and leaves the rest.
- `cd daemon && swift test` and `cd pipeline && uv run --extra dev pytest -q` green, ruff and pyright clean, new test counts in the commit body; `python3 scripts/truth_fences.py events` green for the new attributes.
- Evidence (confirms, does not gate): delete a dogfood meeting that was published to the filesystem sink; its `published/` files are in the Trash and `mp ask` no longer cites it.
