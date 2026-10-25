# DIAR8: When diarization throws, nothing is logged or evented, and the channel-aware fallback never runs because Swift labels every segment `speaker_unknown` while Python only treats `Speaker?` as unlabelled

Band origin: filed 2026-10-25 from the 2026-10-25 observability audit band ([audit](../../audits/2026-10-25-observability-audit.md) row O8: FB-4, LG-17). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Re-verified against `main` at `01e904a` on 2026-10-25. FB-4 was confirmed by an independent skeptic at medium; LG-17 was low. No diarization failure was observed on this Mac: all 8 real run-alls in `pipeline.log` logged "FluidAudio sidecar already labelled segments", with 0 channel-aware lines, which is what both a healthy diarizer and this defect produce. Reachable on any diarizer exception, for example a CoreML model load failure.

**The failure is recorded only inside the transcript.** `FluidAudioRunner.transcribe` wraps `runDiarization` in a `do`/`catch`; the generic arm is `diarizationOK = false; diarizationFailureReason = String(describing: error)` and nothing else. The file has no `Log` call at all. `SinkDispatcher` then emits `transcription.engine_succeeded` with `file`, `engine`, `segments`, `audio_seconds` and `kind`, with no diarization attribute and no language. No Swift code reads `diarizationFailed` after `TranscriptSidecar` encodes it, so the reason survives only as a line in the transcript `.md` header. A diarization failure rate cannot be counted from either event log.

**The sentinel drift.** With `speakers` empty, `SegmentBuilder.build` gives every segment its `unknownSpeaker` fallback, `"speaker_unknown"` (the default in both `FluidAudioRunner.init` and `SegmentBuilder.build`). Its doc comment says that fallback "matches Python's _UNKNOWN_SPEAKER for schema uniformity", which is where the drift starts: Python's `_UNKNOWN_SPEAKER` is `"Speaker?"` in both `diarize_cleanup.py` and `markdown.py`. `orchestrate._streamed_segments_have_speakers` counts as labelled any truthy label `!= "Speaker?"`, so a sidecar that is entirely `speaker_unknown` passes, and `finalize` takes the `"FluidAudio sidecar already labelled segments; finalizing as-is"` branch. The stereo `assign_speakers_by_channel` path written for exactly this case (mic channel to the user, system channel to the others) is unreachable for daemon output, and `_me_signals` returns `(None, None)` because there are no embeddings, so no one is named. Because `{**streamed}` carries the Swift flag through, `markdown.render_markdown` then prints "Diarization failed; all turns labeled `Speaker?`" over turns that actually read `speaker_unknown` (displayed as "Unknown speaker"). The summary gets a meeting with no attributable speakers, no owners on action items, and no attendee list.

**Why the flag, not the label.** `speaker_unknown` is not only the failure sentinel. On a healthy run it is also the junk drawer for words no diarizer span covered, and `MeetingCast`, `TranscriptTab`, `MeetingStats` and `scripts/valid1_check.py` all key on that exact string. DIAR6 adds a per-segment veto that will put more segments there. Renaming the Swift sentinel to `Speaker?`, or counting `speaker_unknown` as unlabelled in Python, would therefore either break those readers or send a healthy meeting with a large junk drawer down the channel path. The sidecar already carries an unambiguous signal: `diarization_failed`.

## Scope

1. **Python keys on the flag.** `orchestrate._streamed_segments_have_speakers` returns False when `streamed.get("diarization_failed")` is true, before counting labels. `finalize` then reaches the stereo channel-aware branch for daemon output as it was written to.
2. **Keep the failure on the record through finalize.** The channel-aware branch currently writes `"diarization": not diarization_failed` and `"diarization_failed": False`, which would erase the Swift failure once item 1 routes there. Preserve `diarization_failed: true` and the Swift `diarization_failure_reason` (Python's mono-case reason is used only when Swift gave none), and add `speaker_fallback` in `{channel, none}` so a reader can tell "labelled Me and Them by channel" from "no labels at all".
3. **Honest markdown note.** `markdown.render_markdown` words the header by `speaker_fallback`: speakers labelled by microphone and system channel, or no speakers labelled, plus the reason. It no longer names a sentinel the turns may not carry.
4. **Swift records it.** `SinkDispatcher` adds `diarization_ok` and `language` (the sidecar's `language`) to `engine_succeeded`, and when `sidecar.diarizationFailed` emits `transcription.diarization_failed` with the error's type name and the reason capped at 300 characters, plus one `Log.writeLine` file line, since the os.Logger path would redact it.
5. **Fix the doc comment** on `SegmentBuilder.build`: it names `speaker_unknown` as the daemon's own junk-drawer label and says Python decides labelled-ness from `diarization_failed`, not from the string.
6. **One visible note.** `TranscriptLoader.parse` reads `diarization_failed`, `diarization_failure_reason` and `speaker_fallback`, and `TranscriptTab` shows a one-line notice above the turns ("Speakers could not be told apart; labelled by microphone and system audio instead") with the reason in its help text.

## Explicitly not / out of scope

- Renaming either sentinel. Rejected above: four Swift and script readers depend on `speaker_unknown`, and Python's `Speaker?` is the mono-failure label.
- Retrying the diarizer, or a second diarization backend: ASR6 owns the single-vendor risk.
- A list-row badge in the Library. The notice lives where the speakers are shown; a row badge needs `MeetingStore` to parse every transcript at scan time, which is a cost to weigh separately.
- The Apple Intelligence summary path recording `run_skipped reason=apple_pending` instead of stage rows, and not recording the transcript language on an unsupported-language failure (LG-17's other half). Not part of O8's shape; PIPE25 owns the language-refusal recovery.
- Per-word speaker assignment (DIAR7) and the owner-name stamping check (DIAR6).

## Acceptance

- `pipeline/tests/test_orchestrate.py` (or `test_finalize_cmd.py`): a daemon sidecar (`backend` in `_DAEMON_BACKENDS`) whose segments are all `speaker_unknown` with `diarization_failed: true`, over a stereo fixture WAV, finalizes through `assign_speakers_by_channel` (labels are the channel speakers, the user label applied), and the written transcript keeps `diarization_failed: true`, the Swift reason and `speaker_fallback: channel`. Fails on the current code.
- The same sidecar with `diarization_failed: false` and a majority of `speaker_unknown` segments still takes the labelled branch, pinning that the flag, not the label, decides.
- A mono variant yields `speaker_fallback: none`, labels `Speaker?`, and keeps the Swift reason.
- A markdown test for each `speaker_fallback` header wording.
- `SinkDispatcherTests`: a stub runner returning a sidecar with `diarizationFailed: true` emits `engine_succeeded` with `diarization_ok: false` and `language`, and one `diarization_failed` event with the capped reason; a healthy sidecar emits no `diarization_failed`.
- `TranscriptTabTests`: `TranscriptLoader.parse` surfaces the three keys, and their absence (every transcript written before this task) parses as no notice.
- `cd pipeline && uv run --extra dev ruff check src tests`, `uv run --extra dev --extra mcp pyright` and `uv run --extra dev pytest -q` green; `cd daemon && swift build` and `swift test` green; `bash scripts/ci-local.sh` green; N new tests named in the commit body.
- `CONVENTIONS.md` documents the `diarization_failed` transcription action, the two new `engine_succeeded` attributes and the `speaker_fallback` transcript key; `python3 scripts/truth_fences.py` clean.
