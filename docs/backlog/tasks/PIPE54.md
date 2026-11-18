---
id: PIPE54
title: Swift writes summary.json shapes the pipeline's schema rejects, and the exit 1 that follows makes Retry re-summarize over the user's edit
category: Pipeline
status: partial
priority: P2
comment: Shipped 2026-11-18 (all three scope items). Limits pinned by summary-limits-golden.json; MeetingSummary.clampedToSchema behind jsonObject() and the Apple write; the editor caps bullets and the title and refuses an over-limit save; the rename field caps and UserTitleStore refuses; mp publish turns a field ValidationError into exit 3 with a [FAIL] line and a none-state publish.json. Owner: one Republish of an 11-bullet summary.json shows the limit line on the row and Retry republishes.
---

# PIPE54: Swift writes summary.json shapes the pipeline's schema rejects, and the exit 1 that follows makes Retry re-summarize over the user's edit

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: F106 in [2026-11-12-independent-audit.md](../../audits/2026-11-12-independent-audit.md) (lens data, confirmed). Re-verified in code at HEAD `3a2da4fc` on 2026-11-13. No field instance: the field window 2026-09-29 to 2026-11-13 had zero summary edits, republishes or Apple Intelligence runs ([2026-11-13-field-evidence.md](../../audits/2026-11-13-field-evidence.md), section Pipeline and publishing), so this is a latent defect on a path the owner has not used since 2026-09-14.

**The limits live only in Python.** `schemas.MeetingSummary` declares `title: str = Field(..., max_length=120)` and `summary: list[str] = Field(..., max_length=10)`, and `ActionItem.confidence` is `Confidence = Literal["low", "medium", "high"]`. ADR 0014 names the Python schema as the source of truth that the Swift model mirrors. Python's own writers clamp to it (`publish_from_paste` cuts `summary_bullets[:10]` and the title to 120, `digest` uses `title[:120]` and `_clamp_confidence`), so a Python-written file always validates.

**Three Swift writers do not.**
- The Summary editor: `CorrectionEditor`'s section rows call `items.wrappedValue.append("")` with no cap, `titleField` is a plain `TextField("Meeting title", text: $model.title)`, and `CorrectionViewModel.makeCorrectedSummary` trims empty rows but neither caps the bullet count nor the title. `SummaryTab.persistEdit` writes the result through `MeetingSummary.jsonObject()` to `<stem>.summary.json`. Its confidence control is a `Picker` over the three valid tags, so the editor cannot produce an invalid confidence.
- The title rename: `MeetingDetailView.writeTitle` patches `summary.json["title"]` as a raw dict (`existing[key] = newTitle`) whenever a summary exists, with no length check. It does not go through `jsonObject()`.
- The Apple summarizer: `AppleIntelligenceSummarizer.write(summary:transcriptMD:suffix:)` serializes `summary.jsonObject()` of whatever `parse` decoded. Its prompt asks for "at most 5 summary bullets" and a three-value confidence, but nothing enforces either, and `jsonObject()` passes `a.confidence` through unless it is empty. The audit marks this variant inferred, not traced; it remains so.

**Why one bad field costs the edit.** `publish_router.fanout` runs `MeetingSummary.model_validate_json(summary_json.read_text(...))` before any sink. The ValidationError is uncaught in `publish_cmd.main` and reaches `mp.__main__`'s `except Exception` arm, which prints the traceback and returns 1, not `EXIT_PUBLISH_FAILED` (3). `MeetingLibraryService.performRepublish` writes the failure sidecar with `SinkDispatcher.stage(for: err)`, which maps only exit 3 to `.publish` and everything else to `.pipeline`. `PipelineFailureSidecar.Stage.retriesFromSummary` is `self == .publish`, so the row's Retry (`retryMeeting`) skips the publish-only branch and, since a finalized transcript exists, calls `regenerateMeeting`, whose `launcher.summarize` writes a fresh `<stem>.summary.json` over the edited one before republishing. A 130-character title written by `writeTitle` makes every later `mp publish` of that meeting exit 1 the same way.

**Correction at filing.** The edit is not lost outright on the editor path: `persistEdit` first writes a correction record through `CorrectionStore.write` with `correctedSummary: correctedDict`, so a copy survives under the corrections store. The live summary, the Library view and every sink still lose it, and the title rename path writes no correction record at all. The audit's "confidence" variant does not apply to the editor (its Picker is closed); only the Apple parse can produce it.

Related: [ARCH10](./ARCH10.md) (new) plans one Swift writer, `SummaryDocument.update`, that does not exist yet; [ARCH11](./ARCH11.md) (new, amended by this band) moves Apple summarize behind the Python provider, after which the Apple leg below validates in Python for free; [UX90](./UX90.md) owns publish-failure reporting on the menu; [PIPE55](./PIPE55.md) owns which title a sink shows, and leaves the rename's length to this task; [ARCH21](./ARCH21.md) is the JSON Schema spike for the per-meeting files.

## Scope

1. **Pin the limits once.** Add a cross-tree fixture `summary-limits-golden.json` generated by `scripts/gen_contract_fixtures.py` from `MeetingSummary.model_json_schema()` (title maxLength, summary maxItems, the confidence enum), listed in `CONVENTIONS.md`'s cross-tree fixture table. Swift holds the same three as constants on `MeetingSummary` and a test asserts they equal the fixture.
2. **Refuse in the editor, clamp at the machine writers.** In `CorrectionEditor`, disable the Summary section's add button at the bullet limit and cap the title field at the title limit, with a short inline note when the cap is reached, so a user is never silently truncated. In `MeetingDetailView.writeTitle`, refuse a title over the limit the same way. In `MeetingSummary.jsonObject()`, the shared write bridge every Swift summary write passes through except `writeTitle`, clamp as a backstop: title to the limit, summary to the first N bullets, and a confidence outside the enum to "medium" (the value `jsonObject()` already uses for an empty one, and `digest._clamp_confidence`'s fallback). If ARCH10's `SummaryDocument` lands first, the `writeTitle` refusal moves into it; whichever lands second keeps both.
3. **A pre-sink failure is a publish-stage outcome.** In `publish_cmd.main` (not in `fanout`, which run-all, digest, merge and paste share), catch `pydantic.ValidationError` from the fan-out and return `EXIT_PUBLISH_FAILED`. Before returning, print one plain stderr line naming the offending field and limit (for example "The summary has 11 bullets; the limit is 10. Edit the summary, then Republish."), which `PipelineLauncher.diagnostics` carries into `<stem>.error.json` as the row's reason, and write `<stem>.publish.json` through `_write_publish_sidecar` with every resolved sink recorded as failed with that message, so its `state` is the existing "none" and no new key enters the CI4 vocabulary. Retry then takes the publish-only path, which republishes the same file and fails the same way, so that reason is the user's only way out and must say what to edit.

## Explicitly not

- Truncating at read time in Python. ADR 0014 keeps Python as the source of truth, and silently dropping a user's eleventh bullet at publish loses content the user can see in the Library.
- Widening `SinkDispatcher.stage(for:)`: `performRepublish` stamps `.pipeline` on any non-3 exit, which is right for a crash or a missing secret; only the validation case is reclassified, and at its source.
- The Apple summarizer's other drift from the Python summarizer (flagged moments and overlays): ARCH11's amendment.
- The rename's precedence against `meeting_title`: [PIPE55](./PIPE55.md).
- Field-level checks the schema does not make (bullet length, attendee count).

## Acceptance

- Swift tests: an editor model with 10 bullets cannot add an 11th; a 130-character title is refused by the editor and by `writeTitle` (the file is unchanged); `jsonObject()` of a model carrying 11 bullets, a 130-character title and an action with confidence "Very high" yields 10 bullets, a 120-character title and "medium".
- A fixture test on each side: the Swift constants and `MeetingSummary.model_json_schema()` both equal `summary-limits-golden.json`.
- `pytest`: `mp publish` on a `summary.json` with 11 bullets exits 3, prints the limit line on stderr, writes `<stem>.publish.json` with `state` "none" and every sink's error naming the limit, and calls no sink's `upsert`; a valid file still publishes and exits 0.
- A Swift test that a republish failing with exit 3 and that sidecar lands as stage `.publish`, and `retryMeeting` then republishes rather than calling `regenerateMeeting`.
- `docs/GUIDE.md` section 10, "A meeting that failed", names the over-limit reason and the fix, in the same commit; `CONVENTIONS.md`'s publish-result section notes the pre-sink failure shape.
- `cd daemon && swift test`, `cd pipeline && uv run --extra dev pytest -q`, ruff and pyright green, with the number of new tests in the commit body; `bash scripts/ci-local.sh` green.

**Progress (2026-11-18): all three scope items shipped.**

- Premise check: the title leg is stale. PIPE55 moved both title writers off `summary.json`: the rename (`MeetingDetailView.writeTitle`) and the editor's title field (`UserTitleStore.splitEditorTitle`) write `meta.json["user_title"]`, and `publish_notion.apply_meeting_title` cuts that to 120 through `model_copy`, which validates nothing. So a long title no longer fails a publish; it is silently cut at every sink. The cap still ships, because silent truncation is what this task's item 2 exists to stop: the rename field and the editor's title field stop at 120 with a note, and `UserTitleStore.write` refuses longer as the backstop (`.tooLong`).
- Item 1: `scripts/gen_contract_fixtures.py` generates `summary-limits-golden.json` (a `contract` object, no cases) from `MeetingSummary.model_json_schema()`. `MeetingSummary.titleMaxLength`, `summaryMaxItems` and `confidenceValues` live in `daemon/Sources/MeetingPipe/Library/SummaryLimits.swift`, and `SummaryLimitsTests` reads the same file. The title counts Unicode scalars, as Python's `len` does.
- Item 2: `clampedToSchema()` is the backstop under `jsonObject()`. It cuts to the first 10 bullets with their anchors, clamps the title, and maps confidence onto the enum, case-sensitively like `digest._clamp_confidence`. `AppleIntelligenceSummarizer.write` clamps once before rendering, so the markdown and the JSON agree. The editor never relies on the backstop: Add stops at 10, the section says "Up to 10.", and a summary already over the limit is refused at Save with what to remove (`CorrectionViewModel.schemaRefusal`), in the inline editor and the standalone window alike.
- Item 3: `publish_cmd.main` catches a field `ValidationError` from `fanout`, prints `[FAIL] <sentence>`, records every resolved sink failed through the new public `publish_router.record_pre_sink_failure`, and exits 3. A file that is not JSON (`json_invalid`, `model_type`) still raises, so Retry can regenerate a corrupt file. On the Swift side `FailurePresentation`'s publish explanation takes that `[FAIL]` sentence (STOR14's shape, now `refusalSentence`), so the row says what to edit rather than "check the destination". The exit-3-lands-as-`.publish` and Retry-republishes legs were already pinned by `MeetingLibraryServiceTests` and stay green; `SummaryLimitsTests` adds the stage mapping for this stderr.
- One consequence of the backstop, by design: a file already over the limit (Swift-written before this task) that is then rewritten by a write that is not the editor, such as ticking an action done, loses bullets 11 and on through `jsonObject()`. The editor refuses instead, and `mp publish` names the limit, so the only silent cut is on a file that could not publish anyway. The `[FAIL]` line for a confidence names the action, not its value, because the line lands in `error.json` and `publish.json`.
- ARCH10's `SummaryDocument` has not landed, so the `writeTitle` refusal sits in `UserTitleStore`. Whichever of the two lands second keeps both.

**Owner walkthrough (not yet offered for owner-verify).** Hand-edit a meeting's `summary.json` to 11 summary bullets, then Republish. The row shows a publish failure whose text names the 11 bullets and the limit of 10, and Retry publishing republishes without re-summarizing. In the editor, the Summary section's + stops at 10.

