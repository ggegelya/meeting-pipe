---
id: FEAT21
title: Run-all summarizes and publishes before anyone can name the speakers, so attendees and action owners go out as diarization labels and fixing them costs a manual re-summarize and republish per meeting
category: Feature
status: new
priority: P2
comment: Filed 2026-10-24 (audit band, go-live UX-8): run-all publishes THEM-x labels as attendees and owners before naming is possible; UX41's Re-summarize repairs it one meeting and one engine call at a time, and DV5 counted 570 of 1126 owned actions as diarization artifacts. Opt-in per-workflow wait-for-names gate before summarize, parked in Needs you with one Summarize and publish button. [Spec](./FEAT21.md) Amended 2026-11-13 by the audit band: 352 of 712 field attendees are THEM-x labels and 217 spoke under 10 s, so a default-on attendee filter with a speech floor joins the opt-in gate.
---

# FEAT21: run-all summarizes and publishes before anyone can name the speakers, so attendees and action owners go out as diarization labels and fixing them costs a manual re-summarize and republish per meeting

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) UX-8). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

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

## Amendment 2026-11-13 (audit band)

Source: the field finding "Attendee lists are diarization labels: half are THEM-x and a quarter spoke under 10 seconds" (transcripts-and-summaries #8) in the [field evidence](../../audits/2026-11-13-field-evidence.md). Re-verified at HEAD 3a2da4fc on 2026-11-14.

**The field numbers.** Across the work laptop's 110 summaries (2026-09-14 to 2026-11-13, all three build eras) there are 712 attendees; 352 (49.4 percent) are exact `THEM-x` labels and 15 more carry a `THEM-` prefix with a suffix; 217 attendees of any label, 179 of them `THEM-x`, hold under 10 s of speech in the transcript; 17 summaries list `speaker_unknown` as an attendee; in 61 of 110 the attendee count equals the transcript's label count. 34 action items are owned by a `THEM-x` label. Correction at filing: the finding's title says "a quarter spoke under 10 seconds"; 217 of 712 is about 30 percent.

**Why every default workflow does this.** The summary schema in `pipeline/src/mp/schemas.py` describes `attendees` to the model as `"Inferred from speaker labels and content."`, and `MeetingSummary._scrub_attendees` keeps any string `clean_person` accepts, which is a safety scrub (emails, URLs, mentions, control characters), not a name check. The staged path builds its list the same way (`summarize_staged.py` appends each Stage 1 row's `who`). `publish_notion.py` turns each attendee into a Notion multi-select option and `publish_obsidian.py` writes them into the note's YAML front matter, so the labels become database options and properties, not only prose. This task's gate is opt-in per workflow and leaves every default workflow publishing these lists.

**Scope addition (default on, independent of the gate).**

4. Filter attendees after summarize and before publish, for every workflow: drop `THEM-x` labels (with or without a suffix), `speaker_unknown`, and the owner's raw id from `attendees`, and report them instead as a count of unnamed voices (a new optional summary field, rendered as "and N unnamed voices"). A label counts as present only with at least a minimum speech time, a named constant set from this distribution (10 s is the field's cut) and documented beside it. Named speakers below the floor stay out too. Seam: a post-validation step in `summarize.py` and the staged path's attendee builder, not the model prompt alone, since the model is not trusted to follow it. Action owners are not rewritten here; the gate (items 1 to 3) and [UX83](./UX83.md) own those.

Not here: owner-cluster selection that puts the owner's own voice under `THEM-x` ([DIAR11](./DIAR11.md)), naming quality ([FEAT19](./FEAT19.md), [FEAT20](./FEAT20.md)), and [DV5](./DV5.md)'s survey.

**Acceptance additions.**

- `pipeline` tests: a summary whose model output lists `THEM-1`, `THEM-2_a`, `speaker_unknown` and two named speakers keeps only the named ones and reports 3 unnamed voices; a named speaker with 4 s of speech is dropped under the floor; a summary whose attendees are all unnamed yields an empty list and a count; a legacy summary without the count field still loads.
- Publish tests: the Notion attendee multi-select and the Obsidian front matter carry no `THEM-` or `speaker_unknown` value.
- A sidecar or schema change goes through `CONVENTIONS.md` and the golden fixtures (`gen_contract_fixtures.py`) if Swift reads the new field.
- `ruff`, `pyright` and `pytest -q` green, new test count in the commit body.
