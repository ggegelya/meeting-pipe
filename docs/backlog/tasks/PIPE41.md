---
id: PIPE41
title: A failed summarize job whose remedy is retry is never re-run, so one transient API timeout left a real meeting without a summary for 22 days
category: Pipeline
status: new
priority: P1
comment: Filed 2026-11-13 (audit band 2026-11-13). P1, broken promise: a recorded meeting ends up summarized; one 120 s Anthropic timeout on 20261022-103101 left it with no summary for 22.0 days across 5 launches and 28 later recordings, because nothing re-runs a failed job and every meeting (113 of 113) runs a workflow pinned to anthropic, so there is no fallback; nothing was lost on disk and the owner may re-band. Give a failed full job whose remedy is retry one bounded automatic re-run, decided at failure time and spent once, plus one launch-time notice for failures older than a day.
---

# PIPE41: A failed summarize job whose remedy is retry is never re-run, so one transient API timeout left a real meeting without a summary for 22 days

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: the 2026-11-13 [field evidence report](../../audits/2026-11-13-field-evidence.md), section "Pipeline and publishing", finding "A cloud timeout left a real meeting without a summary for 22 days" (pipeline-and-publishing#0), with the low "One meeting has had a transcript and no summary for three weeks after a summarize timeout" from its "Transcripts and summaries" section (transcripts-and-summaries:12) folded in. The same incident also appears in that report's "Daemon health" section. The audit itself did not report it; its nearest finding, F023 in the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md), is a different retry path.

**The incident.** Stem `20261022-103101`, a 784 s Teams recording with 68 transcript segments and 7 speaker labels. Pipeline `run_started` at 2026-10-22T07:47:22Z, the speaker cleanup pass completed, summarize `stage_started` at 07:47:46.9Z, then `run_failed` with `error_type` `APITimeoutError` 124.4 s later, after one "Anthropic call attempt 1" line and no attempt 2. The daemon logged `pipeline_failed` at 07:49:57.841Z, 351 s after `recording_stopped`. On 2026-11-13 the stem had `<stem>.error.json` (stage `pipeline`, operation `summary`, remedy `retry`), a transcript, and no summary, run or publish sidecar. In the next 22.0 days there were 0 further `run_started` rows for the stem, 0 `retry_requested` rows, 5 daemon launches, 1 rebuild and 28 later recordings. All-time, the pipeline log has 12 abnormal ends of real runs (4 `BadRequestError` on 2026-09-07 and 2026-09-08, 2 `APITimeoutError`, 1 `ValidationError`, 1 `LocalSummaryError`, 4 with no terminal row), and 7 of those stems never show a completed run. The same never-recovered shape appears before the daemon log window, on 2026-07-20, 2026-09-07 and 2026-09-08.

**Why each layer let it stand, re-verified at HEAD `3a2da4fc` on 2026-11-14.**
- `summarize._should_retry_anthropic` returns `False` for `anthropic.APITimeoutError` by design ("A timeout means a stalled connection; retrying just re-hangs the run. A stall should drop straight to the backend fallback (local) instead"), and the client is built with `max_retries=0` and `_REQUEST_TIMEOUT = httpx.Timeout(120.0, connect=10.0)`. PIPE10's slept-through retry in `_create_message` re-issues only when wall-clock exceeds monotonic time by `_SLEEP_DIVERGENCE_SEC` (60 s), which a stalled request on an awake Mac never does.
- The fallback the comment leans on does not exist for this owner: `workflow_backend` is `anthropic` on 113 of 113 meetings in the pack, so a pinned workflow has no local leg to drop to. The docstring itself names this case ("That matters most for a workflow pinned to `anthropic`, where 'drop to the fallback' is not an option that exists").
- `SinkDispatcher`'s run-all completion, on a non-cancellation `.failure`, logs `pipeline_failed`, calls `PipelineFailureSidecar.write(stem:in:stage:reason:metadata:)` with `FailureMetadata.from(err)`, then `completeActiveJob`. Nothing schedules anything afterwards.
- At launch, `Coordinator.reconcileStrandedJobs` only marks stems with a final recording and no terminal sidecar as `.interrupted`, and its doc comment records the deliberate rule "Mark, do not auto-re-enqueue", because a stranded meeting's summary mode is unknown and auto-reprocessing could egress a meeting recorded BYO (REC2's no-auto-egress posture). A stem that already has `<stem>.error.json` is terminal, so it is not even looked at.
- The only re-run path is `MeetingLibraryService.retryMeeting(stem:)`, reached from the Library's Retry. For a `pipeline`-stage failure with a reusable transcript it logs `retry_requested` with scope `summary` and calls `regenerateMeeting`, which re-summarizes from the transcript without transcribing again.

Correction at filing: the field recommendation's second half, "keep a persistent count of unresolved failures in front of the owner", is mostly shipped. `MeetingStore.unrecoveredFailureStems` counts every stem with `<stem>.error.json` and no summary (plus age-inferred stalls), `StatusBarController.refreshFailedMeetingCount` refreshes it at launch and on job completion, and `StatusBarModel.failedMeetingsTitle` shows "⚠ N meetings failed - open Library to retry" as a status-menu row. So `20261022-103101` was counted for the whole 22 days; the row is only visible when the menu is opened, and nothing ever acted on it. The gap is the missing automatic re-run, plus a surface that reaches the owner without opening the menu.

Correction at filing: remedy `retry` is wider than "transient". `failure_details.describe` returns remedy `retry` for every cause outside billing, key and model causes, including `unknown`, which today also covers a deterministic HTTP 400 and (until [PIPE44](./PIPE44.md) lands) a chained timeout. One bounded re-run of a deterministic failure costs one wasted call; that is the accepted cost of the bound, not a reason to widen or narrow it here.

Related: [PIPE24](./PIPE24.md) (its 2026-11-13 amendment owns re-issuing a timed-out request inside the same run; this job-level recovery still holds when that lands, since a second timeout or any other retry-remedy failure ends the run the same way), [PIPE44](./PIPE44.md) (the `cause unknown` classification of this same failure), [PIPE18](./PIPE18.md) (Retry coalescing; the auto re-run must go through the coalesced path), [UX90](./UX90.md) (a publish failure that never reaches the failed row), [PIPE37](./PIPE37.md) (done; the relaunch marking of in-flight jobs), PIPE10 and PIPE3 (archived; the slept-through retry and the stranded-job reconcile).

## Scope

1. **Decide eligibility at failure time, where the job is known.** In `SinkDispatcher`'s run-all failure branch (the non-cancellation `.failure` that writes `PipelineFailureSidecar` with `FailureMetadata.from(err)`), mark the failure eligible for one automatic re-run only when all hold: `job.kind == .full`, `job.summaryMode == .auto` (so a BYO meeting is never re-run, which keeps REC2's posture and the reason `reconcileStrandedJobs` does not re-enqueue), the stage is `.pipeline`, the metadata's `remedy` is `retry`, and this failure was not itself produced by an automatic re-run. `.interrupted`, `.transcribe`, `.launch`, `.memory` and `.publish` failures are never eligible here.
2. **Persist the bound so it survives the sidecar being cleared and rewritten.** `retryMeeting` clears `<stem>.error.json` before it runs and `regenerateMeeting` writes a fresh one if the re-run fails, so the "already auto-retried" fact cannot live only in that file. Record it per stem in a store the re-run path carries forward (an `auto_retry` field that both failure writers, the dispatcher's and `regenerateMeeting`'s, preserve, or a small stem-keyed record beside the library); the pickup picks the store, and the tests below pin that the bound holds across a relaunch.
3. **Run it once, through the existing Retry.** Trigger the re-run at the next daemon launch (after `reconcileStrandedJobs`) or after the next job that completes successfully, whichever comes first, by calling `MeetingLibraryService.retryMeeting(stem:)` so PIPE18's coalescing, the transcript reuse and the moved-into-NDA publish guard in `regenerateMeeting` all apply unchanged. Log `retry_requested` with a new attribute `trigger: auto` (the Library's Retry keeps logging without it, or with `trigger: user`).
4. **One surface beyond the menu row.** At launch, after the auto re-run pass, if any stem in `unrecoveredFailureStems` has a failure `ts` older than 24 h and no automatic re-run left, post one notification naming the count that opens the Library when clicked, and log `failures_unresolved` with the count. Once per launch, never per meeting. The existing menu row is unchanged.

## Explicitly not

- Re-issuing the timed-out request inside the same run, or changing `_should_retry_anthropic`: [PIPE24](./PIPE24.md)'s 2026-11-13 amendment.
- The `cause unknown` on this failure: [PIPE44](./PIPE44.md).
- More than one automatic attempt, or a backoff schedule. One re-run is the bound; a second failure stays for the owner.
- Auto re-running `.interrupted` stems. PIPE3 chose "Mark, do not auto-re-enqueue" for them because their summary mode is unknown; this task does not reopen that.
- A per-row Dismiss for a failure. Retry and delete already clear the row; a dismiss is a separate UX decision.
- The stall watchdog that fired falsely twice on slow `mp` starts and stayed silent through this 124 s request (field report, same section): observed, not filed here.

## Acceptance

- `SinkDispatcherTests`: a full `.auto` job whose run-all fails with metadata remedy `retry` and stage `.pipeline` is recorded as auto-retry eligible; the same failure on a `.byo` job, on a `.retranscribe` job, with remedy `billing`, and with stage `.transcribe` is not.
- A coordinator-level test with an injected clock and file system: an eligible stem is re-run once at the next launch through `retryMeeting` (one `retry_requested` with `trigger: auto`); a second failure of that re-run is not re-run at the following launch nor after a later successful job, including across a simulated relaunch.
- The same eligible stem is instead re-run after the next successful job when no launch comes first, and not re-run a second time at the launch that follows.
- `failures_unresolved` fires once per launch with the right count when a failure older than 24 h has no re-run left, and does not fire when every such failure is resolved or still has its re-run pending.
- `retry_requested`'s new `trigger` attribute and `failures_unresolved` are in `CONVENTIONS.md`'s event table, and `python3 scripts/truth_fences.py events` is green.
- `docs/GUIDE.md`'s "A meeting that failed" recipe says a timed-out or otherwise retryable summary is retried once automatically, in the same commit.
- `cd daemon && swift build` and `swift test` green with the new tests counted in the commit body; `bash scripts/ci-local.sh` green.
