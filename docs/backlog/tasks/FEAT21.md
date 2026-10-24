# FEAT21: run-all summarizes and publishes before anyone can name the speakers, so attendees and action owners go out as diarization labels and fixing them costs a manual re-summarize and republish per meeting

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) UX-8). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Verified on 2026-10-24:

- **The order.** `orchestrate._run_all_inner` runs finalize (speaker labels, roster match), the cost-guard skips (`_check_no_speech`, `_check_suspect_transcript`, `_check_byo`, `_check_too_long`), the optional diarization cleanup, the Apple hand-off check, then summarize and `publish_fanout`, in one process started when the recording stops. Every voice the roster did not match is a `THEM-x` at that moment (and the owner's own voice is "1" when `user_label` is empty, [UX83](./UX83.md)). The summarizer writes those labels into `attendees` and `actions[].owner`, and the publish sends them to Notion or Obsidian before the owner has opened the meeting.
- **The repair exists but is manual and per meeting.** Naming in the app writes the reversible overlay. UX41's cue in `MeetingDetailView+Header.swift` ("Speaker names changed after this summary.") offers **Re-summarize**, and `MeetingLibraryService.regenerateMeeting` chains `mp summarize` (which applies the overlay through `transcript_corrections` and `speaker_overlay`) into a publish. So each meeting costs a second engine call and a click, and the first publish has already gone out wrong. GUIDE's "the three re-verbs" section says so honestly; the cost is the point.
- **How often.** [DV5](./DV5.md)'s 2026-08-19 survey of the owner's 249 summaries: of 1126 owned open actions, 570 were diarization artifacts (357 bare numbers, 127 `THEM-*`, 86 `Speaker N`), so only 36.9 percent named a human. The bare numbers are UX83's; the `THEM-*` share is this task's.

## Scope

An opt-in, per-workflow **wait for speaker names** setting. When it is on and the finalized transcript still has unnamed voices, run-all stops before summarize and parks the meeting; one action releases it.

1. **The gate.** A `_check_unnamed_voices` short-circuit in `_run_all_inner`, after the diarization cleanup (which can change labels) and before `_check_apple_handoff`, returning the existing `_skip_result` shape with a new reason. It trips only when the workflow opts in, the workflow publishes somewhere beyond the filesystem, and unnamed voices (`THEM-x`, or the owner's raw id) carry more than a small share of speech time, so one stray "Unknown C" with two seconds of audio does not hold a meeting. The share is a named constant set from the owner's library and documented beside it.
2. **The setting.** A workflow flag, written by Swift into the meta sidecar and read through the per-meeting workflow overlay, exactly like `workflow_nda_mode`. That is a sidecar contract change: Swift writer, Python reader, `CONVENTIONS.md` and `test_workflow_overlay.py` in one commit. Default off, so nothing changes for a workflow that has not opted in.
3. **The parked state.** The meeting shows in Needs you as "waiting for speaker names", with the cast strip's unnamed count and a single **Summarize and publish** button, which runs the existing `regenerateMeeting` chain (summarize, then publish, overlay applied). It needs no new pipeline verb.

## Explicitly not

- Auto-releasing when the last voice is named. Naming happens in several sittings and a half-named meeting would publish on the click that named one of three; the owner releases it.
- Rewriting names inside an existing summary's prose. UX41's comment explains why (Ukrainian names decline by case, and it would falsify what the summary claims to be).
- Making the roster or naming better ([FEAT19](./FEAT19.md)), name candidates from the meeting app ([FEAT20](./FEAT20.md)), or the owner's own label ([UX83](./UX83.md)).
- Republish idempotency. A held meeting publishes once, which sidesteps it; the existing post-publish re-summarize path still depends on [PIPE23](./PIPE23.md) to update rather than duplicate a Notion page.
- The long-meeting gate, which parks meetings for a different reason ([PIPE27](./PIPE27.md)). The two parked states should read differently in Needs you.

## Acceptance

- `pipeline` tests: the gate trips for an opted-in workflow with a publishing sink and an unnamed voice over the share; it does not trip with the flag off, with a filesystem-only sink, with every voice named, or for a tiny unnamed share; the skip result carries the new reason and no summary is written; `test_workflow_overlay.py` covers the new flag's round-trip.
- `daemon` tests: the workflow editor writes the flag into the meta sidecar; a parked meeting classifies as waiting for names in the Needs you derivation; the release button invokes the regenerate chain.
- The tripping test fails against today's `_run_all_inner`, which reaches summarize with unnamed voices whatever the workflow says.
- `cd pipeline && uv run --extra dev ruff check src tests`, `pyright`, `pytest -q` green; `cd daemon && swift build` and `swift test` green; `python3 scripts/truth_fences.py both` green with any new event action documented; new test counts in the commit bodies.
- `docs/GUIDE.md` gains the recipe (turn it on for a workflow, name the voices, release) and `README.md` the setting, in the same commit (DOC11).
