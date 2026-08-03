# PIPE17: the channel-aware finalize branch still hand-rolls `write_text`, which PIPE8 recorded as converted

Filed 2026-08-03 by the audit band. Medium, spot-checked.

## What is wrong

`storage.atomic_write_text` backs only the already-labelled branch of the finalize stage. The channel-aware / mono fallback branch writes the transcript non-atomically, so a kill mid-write leaves a truncated `<stem>.json` or `<stem>.md` rather than the prior file intact.

- `pipeline/src/mp/orchestrate.py:738-739` are `json_path.write_text(...)` and `md_path.write_text(...)`, followed by `os.chmod(..., 0o600)` at `:741-742`. That is exactly the `write_text` + `chmod` pair the helper exists to replace.
- `pipeline/src/mp/orchestrate.py:704` is the other branch of the same function, 34 lines above, using `storage.atomic_write_text`.
- `pipeline/CLAUDE.md:40` states the rule: "**Rewriting the only copy of a transcript/summary is atomic.** ... Used by `orchestrate` finalize + glossary, `summarize`, and `merge_meetings` (PIPE8). Don't hand-roll `write_text` + `chmod` for content files."
- `docs/backlog/q6-final.md:404` is the shipped-work record claiming the conversion covered `orchestrate._finalize_streamed_transcript`. Only half of it happened.

The branch is live rather than theoretical: the owner's `pipeline.log` carries 23 occurrences of "Finalized transcript:" (the log line at `orchestrate.py:743`, unique to this branch) and 20 of "Stereo recording; channel-aware speaker labelling at finalization" against 172 "FluidAudio sidecar already labelled segments", so it runs on roughly one recording in eight.

Failure shape: FluidAudio labels fewer than half the segments (mono input, or a diarization miss), so finalize takes this branch. `PipelineLauncher`'s watchdog SIGKILLs a wedged run-all, or the Mac loses power, while `md_path.write_text` is partway through. A retry's `mp run-all` then reads the truncated file and summarizes half a meeting, and neither the no-speech guard nor the suspect-transcript guard fires on a partial file.

## Scope

Replace the `write_text` + `os.chmod` pair at `orchestrate.py:738-742` with two `storage.atomic_write_text` calls, matching the sibling branch.

Re-check `q6-final.md:404`'s PIPE8 entry, since its acceptance text asserts a conversion that only half happened. Correct it to record what actually shipped, per the archive's role as the trail.

## Acceptance

Suite green with new tests. A test pins **both** finalize branches through the helper, since the existing PIPE8 storage tests only cover the labelled path, which is how this survived. The archive entry is corrected in the same commit.
