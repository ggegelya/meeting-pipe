---
id: SEC22
title: Voiceprints are written world-readable because four writers bypass `storage.atomic_write_text`, and `roster forget` leaves the person's embeddings in every meeting
category: Security
status: partial
priority: P2
comment: Python half shipped 2026-11-16; Swift and installer half 2026-11-26 (recorder, merge, FLAC and redactor audio 0600 via OwnerOnlyFiles, launch sweep adds wav/flac and the library folder 0700, library folders created 0700, install.sh chmod 700 on the config dir). Remainder: item 5 (drop embeddings with the audio) held on an owner question, item 6 (zero_egress gate), and making the purge the default after FEAT24.
---

# SEC22: voiceprints are written world-readable because four writers bypass `storage.atomic_write_text`, and `roster forget` leaves the person's embeddings in every meeting

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) S8, file-mode half of [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) PP-4). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

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

## Amended 2026-11-12 (security review)

From the [security review](../../audits/2026-11-12-security-review.md) (verified, informational; no other principal can read them on the owner's single-account Mac today). On 2026-11-12 every audio file in `~/Documents/Meetings/raw` was `-rw-r--r--` and `Meetings/` and `raw/` were `drwxr-xr-x`; only `~/Documents` being 0700 keeps them private. `MeetingRecorder` creates the `AVAudioFile` at the umask mode, the ffmpeg merge and FLAC outputs inherit it, and `MeetingStore.tightenArtifactPermissions` touches only `.json` and `.md` (SEC14 pinned `m.wav` at 0644 in `MeetingStoreTests` on purpose). The Recording pane's folder picker can point the library anywhere, including `/Users/Shared`.

Added scope: chmod 0600 at recorder and transcoder creation, add `wav` and `flac` to the launch sweep (flipping SEC14's pinned test), and create the library directories 0700. Exposure on exFAT or external volumes is not fixed by modes and stays out of scope.

## Amendment 2026-11-13 (audit band)

From the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md), findings F098 and F138 (both confirmed, medium, data lens), re-verified in code at HEAD on 2026-11-13. Most of both findings restate this task: `orchestrate._write_embeddings_sidecar` still hand-rolls `tmp.write_text(json.dumps(payload), encoding="utf-8")` then `tmp.replace(path)` with no chmod (item 1), and `RosterStore.forget` still rewrites only `roster.json` (item 3). Two things they add are not in this spec.

- **F098: the embeddings outlive the audio.** `AudioRetention.decide` returns `.drop(URL)` for a settled meeting past its workflow's window, and `AudioRetentionSweep.sweep` executes it as `FileManager.default.removeItem(at: audio)` plus the waveform peaks cache; the `Action.drop` doc comment says "Delete the recording, keeping every sidecar". `<stem>.embeddings.json` is one of those sidecars, so a meeting whose workflow drops audio after N days keeps a 256-dimension voice embedding for every diarized speaker indefinitely. The shipped default workflow is on `keep` (`AudioRetention.decide`'s doc comment records the owner keeping it on 2026-11-12), so this is reachable as soon as any workflow is set to drop.
- **F138: no regulated or NDA gate.** `finalize_streamed_transcript` calls `_write_embeddings_sidecar(wav, speaker_embeddings, resolved.mapping, resolved.near_misses)` unconditionally. Both callers have the overlay-resolved config in hand (`orchestrate`'s run path after `entry.prepare(cfg, wav)`, and `finalize.finalize` via `entry.prepare(anchor=wav, secrets=False)`), but neither passes `zero_egress(cfg)` in, so a regulated or NDA meeting persists every participant's embedding exactly as an ordinary one does. The opt-in switch is SEC24's, and SEC24 is P3, so nothing gates it until a second user arrives.

**Added to scope.**

5. (F098) **Embeddings follow the audio.** In `AudioRetentionSweep.sweep`'s `.drop` branch, after the audio is removed, also remove `<stem>.embeddings.json` and add `embeddings_dropped` (bool) to the existing `coordinator` `audio_dropped` event. `.compress` leaves the sidecar alone. The transcript, summary and other sidecars stay, as now.
6. (F138) **Interim gate under zero_egress.** `finalize_streamed_transcript` gains a keyword (`persist_embeddings: bool = True`), both callers pass `not zero_egress(cfg)` on the resolved config, and when it is false `_write_embeddings_sidecar` is skipped and `pipeline` `embeddings_withheld` is emitted with `stem` and `reason="zero_egress"`. Voiceprint and roster matching still run in memory, so names the roster already knows still resolve. The consequence must be stated in the commit and is an owner call: a regulated or NDA meeting then offers no cluster enrollment and no FEAT14 near-miss suggestion (the Library already degrades to per-line assignment when a label is missing from `voiceprintLabels`, and `mp roster enroll` prints "no embeddings sidecar" and exits 2). If the owner prefers naming under NDA, item 6 is dropped and item 5 alone ships.

**Added to explicitly not.** Purging embeddings sidecars already written for past regulated or NDA meetings (a one-off the owner can run once item 6 lands; not automated here). The opt-in `speaker_recognition` switch and the consent disclosure stay SEC24. The daemon's draft transcript sidecar carries the raw `speakerEmbeddings` (`FluidAudioRunner`, trimmed by `HeldEndTrim`) until finalize pops them, so a regulated or NDA meeting whose finalize never runs keeps them in `<stem>.json`; observed, not in this scope.

**Added to acceptance.**

- (F098) `AudioRetentionSweepTests`: a `.drop` over a scratch library removes `<stem>.embeddings.json` and keeps `<stem>.json`, `<stem>.md` and `<stem>.summary.md`; a `.compress` leaves the embeddings sidecar in place; `audio_dropped` carries `embeddings_dropped`.
- (F138) pytest in `test_orchestrate.py`: a run whose overlay resolves `workflow_nda_mode`, and one under `regulated_mode`, finalize the transcript, write no `<stem>.embeddings.json` and emit `embeddings_withheld`; an ordinary run still writes it. The same for `mp finalize` in its own test file.
- `embeddings_withheld` and the new `audio_dropped` attribute documented in `CONVENTIONS.md`; `python3 scripts/truth_fences.py events` green.

**Progress (2026-11-16):** the Python items 1 to 4 shipped. Decisions that were not in the spec: (a) the forget cascade is **opt-in** (`--purge-embeddings`, with `--library` defaulting to `recording.output_dir`) rather than default, because the daemon's Undo naming and rename also run `mp roster forget` and would otherwise strip the voices a re-name needs (FEAT24); also strips `near_misses` entries that point at the name, not only keys equal to it; (b) the new event `roster_embeddings_forgotten` carries a file count, never the name; (c) the fence's allowlist has five pre-existing hand-rolled writers with reasons (corrections, local_server, publish_router, publish_lan, backup, merge_meetings). Not done here, by design of this batch: `install.sh` (another session's file), everything Swift (recorder and transcoder chmod, `tightenArtifactPermissions` for wav/flac and library directories, `AudioRetentionSweep` dropping `<stem>.embeddings.json`, item 5), and item 6 (withholding embeddings under zero_egress), which the amendment itself marks an owner call.

**Progress (2026-11-26):** the Swift and installer half of the 2026-11-12 amendment shipped. `OwnerOnlyFiles` (new) creates both capture files 0600 (pre-created, since `AVAudioFile(forWriting:)` takes no mode and keeps an existing file's mode, measured), tightens every ffmpeg temp before it is promoted (merge, single-source convert, FLAC transcode, mute redaction), and creates library folders 0700 with any folder above them (`MeetingRecorder.start`, the store's watcher, Open Recordings, `LibraryMover`'s new parent). `MeetingStore.tightenArtifactPermissions` now also takes `wav` and `flac` (flipping SEC14's pinned 0644 assertion, with the reason in the test) and the library folder itself to 0700 on every launch, never its parent. `install.sh` runs `chmod 700` on `~/.config/meeting-pipe` after creating it. A source fence fails on any `AVAudioFile(forWriting:` outside `OwnerOnlyFiles.swift`. Decisions not in the spec: the existing library folder is tightened (the spec said create), audio the pipeline writes in Python is covered only by the launch sweep, and no process-wide `umask` (it would reach every `mp` child).

**Item 5 is held on an owner question.** Removing `<stem>.embeddings.json` when retention drops the audio costs more than the spec acknowledges. Reachable only once a workflow is set to drop (the shipped default keeps). On a dropped meeting: (a) a meeting finalized before UX83 (2026-11-19) with no overlay name shows the owner as "1" instead of "You", and Set your name's carry skips it, because `OwnerName.isOwnerKey` recognizes a numeric owner label only through the sidecar's keys, and a drop policy reaches the oldest meetings first; (b) naming a cluster falls back to a per-line label with no roster enroll (the existing `speaker_labeled_no_voiceprint` path) and FEAT14's near-miss suggestion disappears; (c) `diarize_cleanup`'s voiceprint refusal fails open if the cleanup runs again on that meeting. Options: ship item 5 as written and accept (a) to (c); or strip only the vectors and keep the labels, which keeps (a) but needs the enroll guard to check for a vector so (b) does not become the old "pipeline exited 2"; or drop item 5.
