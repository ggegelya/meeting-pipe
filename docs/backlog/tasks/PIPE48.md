---
id: PIPE48
title: A merge that fails after recording merged_from but before the audio swap is resumed as complete, and the daemon then trashes the fragments
category: Pipeline
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). PIPE8 (done) does not hold. `merge_meetings` commits the transcript carrying `merged_from` before it writes `<stem>.md` and swaps in the merged audio. The retry's resume branch looks only at `merged_from`, so it never finishes the swap from `.merging.tmp`, never re-renders the markdown, publishes whatever `.md` is on disk and exits 0, and the daemon then trashes the fragments. The meeting is left with part-one audio and possibly a part-one published transcript. `test_merge_meetings_retry_after_crash_between_commits_does_not_double_concat` pins that path as clean (F116). Code-derived; no merge has run in the field since 2026-07-14. Fix: resume based on the audio's actual state, always re-render the markdown, delete the temp on failure, and check free space first.
---

# PIPE48: A merge that fails after recording merged_from but before the audio swap is resumed as complete, and the daemon then trashes the fragments

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Sources: F099 (medium, partially confirmed) and F116 (confirmed), both in [2026-11-12-independent-audit.md](../../audits/2026-11-12-independent-audit.md). Every code claim below was re-read at HEAD `3a2da4fc` on 2026-11-13.

**What PIPE8 promised.** PIPE8 (done, `dcbf94cd`; its entry is in [q6-final.md](../q6-final.md)) moved the `merged_from` commit ahead of the audio swap, to close FEAT9's double-concat on retry. In `merge_meetings`, that is these three lines, in this order:

- `storage.atomic_write_text(json_path, ...)` with `merged["merged_from"]`
- `storage.atomic_write_text(md_path, render_markdown(merged))`
- `os.replace(str(tmp), str(primary_audio))`

The comment beside them treats the window as safe: "The reverse residual (transcript merged, audio not yet swapped) is a retry that re-publishes over the correct transcript, with the fragment audio recoverable from the kept originals."

**The resume branch.** On a retry, `already.issuperset(frag_stems)` sees `merged_from` and takes the branch that logs "already carries %s; re-publishing only" and emits `meetings_merge_resumed`. It then goes straight to `summarize(md_path, ...)` and `publish_fanout(..., transcript_md=md_path)`. It never looks at `<stem>.wav.merging.tmp`, and it never re-renders `<stem>.md`.

If the run failed between the JSON commit and the swap, the result is:

- **The audio is part one.** The primary `.wav` still holds only the first recording, and the verified `.merging.tmp` is left orphaned.
- **The markdown may be part one.** If the `.md` write itself raised, `<stem>.md` is the primary's old one, and the publishers send that file as it is.

Either way the retry exits 0 or 3, never 1. On a clean result, `MeetingLibraryService.mergeMeetings`'s `.success` arm calls `softDeleteMeeting` on each fragment.

Correction at filing (summary): the summary is not stale. `summarize` reads the structured `<stem>.json` when it can parse it (FEAT10's `overlaid_structured` path), so it summarizes the merged meeting. The broken artifacts are the audio, the published transcript copy and the Library's Audio tab, which no longer match the summary.

Correction at filing (recovery): PIPE8's "recoverable from the kept originals" does not hold. A fragment has a kept original only if it was redacted, and `softDeleteMeeting` trashes `originals/<stem>.wav` together with the stem's `raw/` files. What remains is the macOS Trash until it is emptied, plus the orphaned `.merging.tmp`, which nothing looks for.

**How the window opens.** The audit narrows it: a plain disk-full usually fails the JSON write first, which is harmless. The open window is the two statements after the JSON commit: a markdown write that raises (disk full after a multi-GB temp), an `os.replace` that fails, or a kill between them. Neither the daemon nor `mp` checks free space before the concat, which writes a temp the size of all inputs combined.

**F116: the test pins the bug.** `test_merge_meetings_retry_after_crash_between_commits_does_not_double_concat` fails the `.wav` `os.replace` once, retries, and asserts only that the concat ran once and that `publish_failed` is absent. It never checks the primary `.wav`'s bytes or the leftover temp. So it pins, as clean, exactly the path that leaves part-one audio while the daemon trashes the fragments. The audit records F116 as PIPE8's accepted trade-off. It was accepted on the premise that fragments stay recoverable, which the daemon's soft-delete breaks.

**Field.** Not observed. The only merge rows are two test-like bursts on 2026-07-14, and no transcript in the pack carries a gap marker ([2026-11-13-field-evidence.md](../../audits/2026-11-13-field-evidence.md)). The pack does show four adjacent pairs that look like one meeting split in two (see [PIPE47](./PIPE47.md)), so the merge has candidates.

Related:

- [PIPE47](./PIPE47.md): what a merge carries. Same function, so land the two together or rebase one onto the other.
- [ASR10](./ASR10.md): sets `audio_seconds` in the same writer.
- [CONC5](./CONC5.md): process supervision.
- [FEAT22](./FEAT22.md): may delete the merge surface; if it does, this task closes as superseded.

## Scope

All in `pipeline/src/mp/merge_meetings.py`.

1. **Resume based on the audio's state, not on `merged_from` alone.** On the `already.issuperset` branch, compare the primary `.wav`'s duration (through `soundfile.info`, as `_verify_concat` does) with the merged transcript's expected length (the fragments' durations, from the fragment audio still on disk):
   - **Temp present.** Run `_verify_concat` on it, then `os.replace` it onto the primary and emit `meetings_merged` with a `resumed` flag.
   - **Temp absent, primary already full length.** Republish, as today.
   - **Temp absent, primary short.** Raise `MergeError` (exit 1) naming the state, so the daemon keeps the fragments. A re-concat from the fragments is acceptable instead, if the pickup prefers it and pins it.
   
   Either way, re-render `<stem>.md` from the committed JSON before summarizing.
2. **Delete the temp on any failure after the concat.** Today it is only removed when the concat or its verification fails.
3. **Check free space first.** Before writing the temp, require free space on the primary's volume of at least the sum of the input sizes plus a margin. If there is not enough, raise `MergeError` before anything is written.

## Explicitly not

- Changing the daemon's soft-delete on success. With item 1, success means the audio really was swapped, and a non-zero exit already keeps the fragments.
- Reordering the commits again. `merged_from` first is what stops the double concat; the fix is the resume branch.
- Carrying fragment overlays, markers and voiceprints: [PIPE47](./PIPE47.md).

## Acceptance

- Rework `test_merge_meetings_retry_after_crash_between_commits_does_not_double_concat` (F116). After the retry, assert that:
  - the primary `.wav`'s bytes equal the concatenated audio, or its duration equals the sum of the inputs with real soundfile audio;
  - no `.merging.tmp` remains;
  - the concat still ran once.
- New pytest: the `.md` write raises after the JSON commit, then a retry. `<stem>.md` holds the merged transcript, including the gap divider, and the audio is swapped.
- New pytest: temp absent and primary short. The retry raises `MergeError`, `main` returns 1, and the fragments' files are untouched.
- New pytest: too little free space (injected). `MergeError` is raised before any temp or transcript is written.
- New pytest: a failure after the concat leaves no `.merging.tmp`.
- `test_merge_meetings_real_audio_end_to_end` and the other merge tests stay green.
- `cd pipeline && uv run --extra dev pytest -q`, ruff and pyright green, with N new tests named in the commit body. `bash scripts/ci-local.sh` green.
