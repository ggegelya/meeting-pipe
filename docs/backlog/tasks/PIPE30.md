---
id: PIPE30
title: The atomic-write helper is re-implemented ten times, nine of them without its 0600 chmod, and several writers rewrite the only copy of a file in place
category: Pipeline
status: new
priority: P2
comment: Filed 2026-10-25 (code-quality audit PY3, CV4): 10 hand-rolled temp-and-replace writers, 9 without the chmod; non-atomic rewrites include publish_from_paste's summary.json and .md (which summarize writes atomically), the manual bundle, digest and the file sinks, and AppleIntelligenceSummarizer is the daemon's one non-atomic summary writer. All through atomic_write_text, `.atomic` plus 0600 in Swift, one fence shared with SEC22. Amended 2026-10-25 (performance review): the Apple Intelligence writer writes the .md before the .json, and the helper gains F_FULLFSYNC, a temp created at its final mode, and a stale-temp sweep (PYTHON-11). Amended 2026-11-12 ([security review](../../audits/2026-11-12-security-review.md)): publish_lan._atomic_write follows symlinks a share peer plants (pid-named temp, plain write_text); create the temp with O_EXCL|O_NOFOLLOW. [Spec](./PIPE30.md)
---

# PIPE30: The atomic-write helper is re-implemented ten times, nine of them without its 0600 chmod, and several writers rewrite the only copy of a file in place

Band origin: filed 2026-10-25 from the 2026-10-25 code-quality audit band ([code-quality audit](../../audits/2026-10-25-code-quality-audit.md) PIPE30, finders PY3 and CV4). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

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

## Amended 2026-10-25 (performance review)

The 2026-10-25 performance review (eight subsystem finders over HEAD 01e904a, every finding adversarially re-verified) drafted these items before this task landed the same day; they are folded in here rather than filed twice.

**Covered already, one ordering detail added (PERSISTENCE-9, PYTHON-12).** The review found `AppleIntelligenceSummarizer.write` and the file-sink, paste and digest writers independently; scope items 1 and 5 above own them. One detail for item 5: write the `.md` first and the `.json` last, because `MeetingStore` treats a `summary.json` on disk as done (`case done // summary.json on disk`), so a markdown write that fails after the JSON leaves a done row with no `.md`.

**A leg the helper itself owes (PYTHON-11).** **`storage.atomic_write_text` never syncs and leaks its temp on a kill.** It runs `tmp.write_text(...)`, `os.chmod(tmp, mode)`, `os.replace(tmp, path)` with no `fsync` (on macOS only `F_FULLFSYNC` forces data to stable storage), so after a kernel panic or power loss shortly after a rewrite the rename can survive while the data does not. It cleans up only on `BaseException`, so the daemon watchdog's SIGKILL, and today SIGTERM too (no handler until [PIPE22](./PIPE22.md)), leave `.<name>.tmp-<pid>` beside the file for good; nothing sweeps them, and `backup._add_root` archives them (`rglob("*")` includes dotfiles). The temp is also created at the umask mode and only then chmodded. The verifier rated the data-loss half plausible: it needs a panic or power loss inside the window.

**Scope addition.** `atomic_write_text`: create the temp with `os.open(..., O_WRONLY | O_CREAT | O_EXCL, mode)` so it is never wider than `mode`, write, flush, `fcntl.fcntl(fd, fcntl.F_FULLFSYNC)` on darwin (`os.fsync` elsewhere), then `os.replace`. Add `storage.sweep_stale_temps(directory, stem)`, called at the start of `run-all` and `summarize` for the stem, which deletes `.<stem>*.tmp-<pid>` files older than one hour (the age guard keeps an in-flight writer's temp).

**Acceptance additions.**

- pytest in `test_storage.py`: `atomic_write_text` issues the sync (`fcntl.fcntl` with `F_FULLFSYNC` on darwin, recorded by a monkeypatch) before `os.replace`, and the temp's mode never exceeds `mode`; `sweep_stale_temps` removes a two-hour-old `.x.json.tmp-999`, keeps a fresh one, and touches no other file.
- Swift, in the suite that covers `AppleIntelligenceSummarizer.write`: under umask 022 both files are 0600; with `<stem>.summary.md` made a directory so the markdown write throws, an existing `summary.json` is byte-identical afterwards. Fails on `main`, which writes the JSON first.

## Amended 2026-11-12 (security review)

From the [security review](../../audits/2026-11-12-security-review.md) finding 9 (verified as plausible, Low). Scope item 2 keeps `publish_lan._atomic_write` as its own helper, which stays right, but the helper writes `tmp = path.parent / f".{path.name}.tmp-{os.getpid()}"` with `tmp.write_text(...)`, which follows symlinks, and `_check_reachable` checks only that the folder exists and is writable. A scratchpad test on 2026-11-12 showed a planted link redirects the write to a file outside the share and leaves the final name as a symlink after `os.replace`.

Attack: a peer with write access to the share plants links named `.<stem>.summary.md.tmp-<pid>` across the pid range for a stem already visible there, pointing at an absolute path on the owner's Mac; the next re-publish of that stem overwrites the target with summary text. Solid over NFS (client-side symlinks); on SMB it depends on the macOS client resolving symlink files, not verified.

Added to scope item 2: create the temp with `tempfile.mkstemp(dir=...)` (or `O_CREAT|O_EXCL|O_NOFOLLOW`) and `lstat` the target directory, refusing a symlinked one. Added acceptance: a test that a pre-existing symlink at the temp path is not followed and a symlinked target directory is refused.
