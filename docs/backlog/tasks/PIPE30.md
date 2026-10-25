# PIPE30: The atomic-write helper is re-implemented ten times, nine of them without its 0600 chmod, and several writers rewrite the only copy of a file in place

Band origin: filed 2026-10-25 from the 2026-10-25 code-quality audit band ([code-quality audit](../../audits/2026-10-25-code-quality-audit.md) PIPE30, finders PY3 and CV4). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

`storage.atomic_write_text(path, text, *, mode=0o600)` (SEC14, PIPE8) is the one helper for rewriting a file: sibling temp file, `os.chmod(tmp, mode)`, `os.replace`, temp removed on any failure. `pipeline/CLAUDE.md` states the rule ("Rewriting the only copy of a transcript/summary is atomic ... Don't hand-roll"). Counted in `pipeline/src/mp` on 2026-10-25, outside `storage.py`:

**Ten hand-rolled temp-and-replace writers.** `corrections.write_run_sidecar`, `corrections.write_empty_marker` and `corrections.set_publish_state` (`tmp = out.with_suffix(out.suffix + ".tmp")`, then `os.replace(tmp, out)`, a fixed temp name so two writers collide, no chmod); `publish_router._write_publish_sidecar` (`<stem>.publish.json`, no chmod); `publish_lan._atomic_write` (files on the share, no chmod); `local_server.write_marker` (has `os.chmod(tmp, 0o600)`, a copy of the helper); `merge_meetings`' audio swap (`os.replace(str(tmp), str(primary_audio))`, binary, its transcript halves already use the helper); and SEC22's three: `Voiceprint._write`, `Roster._write`, and `orchestrate`'s `<stem>.embeddings.json` writer. Nine of the ten skip the chmod, so on a `022` umask their files land `0644`; the JSON ones stay that way until `MeetingStore.tightenArtifactPermissions` sweeps the library at the next daemon launch.

**Non-atomic rewrites of a file that may be the only copy**, each a plain `write_text` over the existing file, so a kill mid-write leaves it truncated:

- `publish_from_paste.publish_from_paste` writes `<stem>.summary.json` and `<stem>.summary.md` in place. `summarize` writes the same two files with `atomic_write_text`, so one file has an atomic writer and a non-atomic one.
- `orchestrate._write_manual_bundle` writes `<stem>.READY_FOR_MANUAL.md` (the whole transcript plus prompt) and `_check_apple_handoff` writes `<stem>.apple_pending.json`, both at umask mode.
- `digest.main` writes `digest-<date>.summary.json` and `.summary.md`, rewritten on a same-day rerun.
- The file sinks: `ObsidianPublisher.upsert` (the vault note and `<stem>.obsidian.json`), `FilesystemPublisher.upsert` (summary, actions, transcript copy and `<stem>.filesystem.json`), and `publish_lan`'s local sidecar. A truncated sink sidecar reads as absent and the next publish treats the meeting as new.
- `backup`'s `.last-backup.json` marker.

**Swift.** `AppleIntelligenceSummarizer.write(summary:transcriptMD:suffix:)` is the daemon's one non-atomic summary writer: `try data.write(to: jsonURL)` and `try md.write(to: mdURL)`, no options, no permission set. 33 of the daemon's 36 `.write(to:` calls pass `.atomic`; the third exception, `TranscriptSidecar.write(to:)` in `SinkDispatcher`, is a custom method that is atomic and sets `0o600`, which is the shape to copy.

Re-checked at filing: the audit listed `roster_cmd`'s transcript relabel (`_relabel_transcript`) under this task, but SEC22's scope item 1 already routes all three `roster_cmd` rewrites (both transcript halves and the embeddings file) through the helper, so they stay SEC22's; and `local_server.write_marker` does set `0600`, so it is a duplicate, not a mode defect.

## Scope

1. **Route through `storage.atomic_write_text`:** the three `corrections` writers, `_write_publish_sidecar`, `local_server.write_marker`, `publish_from_paste`'s two summary writes, `_write_manual_bundle`, the apple-pending sentinel, `digest.main`'s two writes, the Obsidian and filesystem sinks' files and sidecars, `publish_lan`'s local sidecar, and the backup marker. The vault note and the filesystem sink's copies live outside the library; pass `mode=0o644` there only if the owner wants other users of the Mac to read them, otherwise keep the default.
2. **`publish_lan._atomic_write` stays its own helper**, because a network share's chmod semantics are the share's, with a comment saying so and an allowlist entry in item 4.
3. **`merge_meetings`' audio swap** stays an `os.replace` of a binary file written by ffmpeg, allowlisted with that reason. Whether the merged WAV should inherit the original's mode is observed here, not changed.
4. **One fence.** SEC22 scope item 4 already specifies a pytest fence for hand-rolled temp-and-replace outside `storage.py` (an allowlist, not a count). Whichever of SEC22 and PIPE30 lands second extends the first one's fence rather than adding a second file: if PIPE30 lands first it builds the fence over `os.replace(` and `.replace(` on a temp path in `src/mp`, with SEC22's three writers as allowlist entries whose reason is "SEC22", and SEC22 empties them. The fence also fails on a direct `.write_text(` to a path built from a library suffix (`.summary.json`, `.summary.md`, `.meta.json`, `.publish.json`, `.run.json`, `.empty.json`, `.json` / `.md` transcript halves, sink sidecars) outside `storage.py`, by AST walk; a call writing a user-named `--out` file is not matched.
5. **Swift:** `AppleIntelligenceSummarizer.write` passes `.atomic` to both writes and sets `0o600` the way `TranscriptSidecar.write(to:)` does.

## Explicitly not / out of scope

- SEC22's four writers (`Voiceprint._write`, `Roster._write`, the orchestrate embeddings writer, and `roster_cmd`'s rename path including its transcript relabel) and SEC22's config-directory mode and `roster forget` cascade: SEC22.
- The Notion sink sidecar (`NotionRestPublisher.upsert`'s `sidecar_path.write_text`): PIPE23 scope item 4.
- Swift's view-side rewrites of `summary.json` through `try?` (`writeTitle`, `persistEdit`): ARCH10's `SummaryDocument.update`.
- Readers of the same files: PIPE29. Obsidian note naming: PIPE31.
- User-chosen report outputs (`actions --out`, `ask --out`, `dogfood` reports, `analyze_detection`, `train_adapter`'s data files), which the user names and which are not the only copy of anything.
- Removing SEC14's launch-time permission sweep (`MeetingStore.tightenArtifactPermissions`); it stays the self-heal for files written before this lands.

## Acceptance

- pytest, under a test umask of `0o022`: each writer in scope item 1 leaves its file at `0o600`, and for `publish_from_paste` and `set_publish_state` a simulated failure between write and replace (patch `os.replace` to raise) leaves the previous file byte-identical.
- pytest: the fence passes on the fixed tree, fails on a planted hand-rolled temp-and-replace and on a planted `write_text` to a `<stem>.summary.json` path (both tried and reverted, said in the commit body), and every allowlist entry carries a reason.
- `AppleIntelligenceSummarizerTests`: after `write(summary:transcriptMD:suffix:)` both files exist with mode `0o600`.
- `bash scripts/ci-local.sh pipeline` and `bash scripts/ci-local.sh daemon` green, with the number of new tests per tree in the commit body.
