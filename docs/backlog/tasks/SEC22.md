# SEC22: voiceprints are written world-readable because four writers bypass `storage.atomic_write_text`, and `roster forget` leaves the person's embeddings in every meeting

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) S8, file-mode half of [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) PP-4). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Measured on the owner's Mac on 2026-10-24 (umask `022`):

```
.rw-r--r--  5.6k  ~/.config/meeting-pipe/voiceprint.json
drwxr-xr-x       ~/.config/meeting-pipe
.rw-------       ~/Documents/Meetings/raw/*.embeddings.json   (6 of 6)
```

`storage.atomic_write_text(path, text, *, mode=0o600)` is the helper SEC14 introduced for meeting content: temp file, `os.chmod(tmp, mode)`, `os.replace`. Four writers of speaker embeddings hand-roll the same temp-and-replace without the chmod, so their files land at the umask default:

- `Voiceprint._write` (`voiceprint.py`): the owner's own running-average voice embedding, `tmp.write_text(json.dumps(payload)); tmp.replace(self.path)`.
- `Roster._write` (`roster.py`): every named third party's voiceprint, same shape. `roster.json` does not exist on the owner's Mac yet; it would be created 0644.
- `orchestrate`'s `<stem>.embeddings.json` writer (`path.with_name(path.name + ".tmp")` then `tmp.replace(path)`): per-meeting embeddings for every diarized speaker.
- `roster_cmd`'s rename path: `emb_path.write_text(json.dumps(edata))` in place, non-atomic. The same function also rewrites the transcript pair (`json_path.write_text(...)`, `(wav.parent / f"{wav.stem}.md").write_text(...)`) non-atomically; writing over an existing file keeps its mode, so those stay 0600, but a kill mid-write truncates a transcript, the exact failure `atomic_write_text` exists to prevent.

Why the per-meeting files read 0600 anyway: `MeetingStore.tightenArtifactPermissions` (SEC14's launch-time self-heal) chmods every `.json` in the library on each daemon start, and `~/Documents` is `drwx------`. So a fresh `<stem>.embeddings.json` sits at 0644 until the next launch, while `~/.config/meeting-pipe/` is never swept and is world-traversable. The audit's count is also off: on 2026-10-24 `pipeline/src/mp` has 38 `.write_text(` calls and 14 `atomic_write_text(` calls, not 53 and 15; the four above are the ones writing biometric data.

`Roster.forget(name)` (called by `mp roster forget --name`, which the daemon's FEAT3-UNDO un-enroll runs) removes the person from `roster.json` only. Their embedding stays in every `<stem>.embeddings.json` keyed by their name, including `near_misses`.

## Scope

1. Route `Voiceprint._write`, `Roster._write`, the orchestrate embeddings writer and `roster_cmd`'s three rewrites through `storage.atomic_write_text` (default 0600).
2. Create `~/.config/meeting-pipe/` 0700: `install.sh`'s `CONFIG_DIR` creation does `chmod 700`, and the pipeline's own `mkdir(parents=True, exist_ok=True)` for that directory passes `mode=0o700` and tightens an existing 0755 once (the SEC14 self-heal pattern, applied to the config dir).
3. `Roster.forget` cascades: after removing the roster entry, strip that name's key from `embeddings` and `near_misses` in every `<stem>.embeddings.json` under the library root, atomically, and report the count in the `roster forget` output and an event.
4. A ratchet so a fifth writer cannot reappear: a pytest fence that greps `src/mp` for `tmp.replace(` / `.with_name(... ".tmp")` hand-rolled atomic writes outside `storage.py` and fails with the file name (an allowlist, not a count).

## Explicitly not

- Whether voiceprints should be created at all, a consent acknowledgement, retention: SEC24 (P3, compliance posture deferred until a second user).
- Deleting a meeting removing its derived files: STOR7.
- Backup archives' file modes: STOR8.
- Converting the other non-biometric `write_text` calls; each would need its own reason.

## Acceptance

- pytest: after `Voiceprint` update, `Roster` enroll, orchestrate's embeddings write, and a `roster_cmd` rename, each written file's mode is `0o600` (stat under a test umask of `0o022`).
- pytest: `forget("Alice")` on a library with two meetings carrying an `Alice` key and one without removes the key from both, leaves other speakers intact, leaves the third file byte-identical, and returns the count.
- pytest: the config-dir helper creates 0700 and tightens an existing 0755.
- pytest: the hand-rolled-atomic-write fence passes on the fixed tree and fails on a planted example.
- `cd pipeline && uv run --extra dev pytest -q`, ruff, pyright green, new test count in the commit body; the new event action uses the existing `pipeline` category, so `python3 scripts/truth_fences.py` (CI5) stays clean.
- Owner check (confirms): after `./scripts/rebuild.sh` and one recording, `ls -l ~/.config/meeting-pipe/voiceprint.json` shows `-rw-------` and the directory `drwx------`.
