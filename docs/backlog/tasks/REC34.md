---
id: REC34
title: The mute timeline is written only after a successful stop-time merge, so a quit or a failed merge quarantines any off-the-record recording instead of redacting it
category: Recording
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). The in-memory mute timeline reaches disk only from persistAfterMerge when a final exists, so a menu Quit, a SIGTERM or a failed or wedged stop-time merge leaves redaction intent with no timeline and orphan recovery quarantines the whole recording, contrary to GUIDE's quit promise; not seen in the field (1 off-the-record recording in six weeks, no launch inside a recording). Write the timeline keyed by stem in the termination flush and on a failed merge, and pin quit-then-recover as redact-and-enqueue.
---

# REC34: The mute timeline is written only after a successful stop-time merge, so a quit or a failed merge quarantines any off-the-record recording instead of redacting it

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Sources: F025 and G030 in the [independent audit](../../audits/2026-11-12-independent-audit.md) (both confirmed, lens data); the [field evidence](../../audits/2026-11-13-field-evidence.md) lists both as not seen. Code re-read at HEAD 3a2da4fc on 2026-11-13.

**The timeline lives in memory until a final exists.** `MeetingRecorder.muteTimeline` (`private var muteTimeline = MuteTimeline()`) is fed on the render thread by the mic tap: under `.captureFirst` and `.captureFirstRedact` every buffer adds a span, `.manual` while off the record (MIC14) and `.mute` otherwise. The only write to disk is `MeetingRecorder.persistAfterMerge`, step 10 of `stop()`, after the merge: `let hasFinal = FileManager.default.fileExists(atPath: final.path)`, then `if captureMode == .captureFirstRedact, hasFinal` writes every span and `else if captureMode == .captureFirst, hasFinal, muteTimeline.hasManualSpan` writes the manual spans. `MuteTimelineFile.url(forFinal:)` is derived from the stem alone (`<stem>.mute-timeline.json`), so nothing about the write needs the final to exist.

**Three exits never write it.**
- Menu Quit and SIGTERM: `MeetingRecorder.flushIntermediatesForTermination` stands down timers, drops the system capture, runs the bounded `EngineTeardown.runSync`, drains the writers and logs `intermediates_flushed_for_termination`. It never touches `muteTimeline`. Its own doc says the `.capturemode` marker and `.recovery.json` manifest stay "so the orphan sweep merges and privacy-routes the recording on the next launch".
- A failed stop-time merge: `mergeIntermediates` returns false, the final is absent, `hasFinal` is false, no write.
- A wedged writer: `mergeIntermediates` takes the `writerWedged` branch (`RecordingPostProcessor.writePostProcessFailure(...)`, `return false`), same result.

**Recovery then fails closed on purpose.** `OrphanRecordingRecovery.shouldQuarantine` returns false only when `MuteTimelineFile.read(forFinal: final) != nil`; otherwise it returns `mode == .captureFirstRedact || OffRecordMarker.exists(forFinal: final)`. Both markers survive these exits (`OffRecordMarker.write` runs in `MeetingSessionController` the moment off the record opens; `.capturemode` is removed only on a clean finish). So `recover` moves the merged WAV with `quarantine(url)` (event `orphan_quarantined`, `reason` `capture_first_no_timeline`) and `Coordinator` raises one notification ("the mute timeline was lost when the app stopped unexpectedly ... They are in the MeetingPipe originals folder"). No failure sidecar is written for the stem, the recording is never transcribed, and `OriginalsReaper.maxAge` (30 days) deletes it; that downstream cost is [SEC26](./SEC26.md)'s. The fail-closed rule itself is right ([SEC16](../q6-final.md) and [MIC14](../q6-final.md), both done): the defect is that the recorder was holding the spans and dropped them.

**The promise it breaks.** `docs/GUIDE.md`, section "Stopping": "quitting the app is always allowed, including mid-recording. Whatever was captured is picked up and finished the next time the app starts." For any recording with an off-the-record press, or under a workflow with redact muted spans on, that is false for a quit.

**Field (work laptop, 2026-09-29 to 2026-11-13).** Not seen: one off-the-record recording in six weeks (20261013-170136, 955.1 s span, `mute_timeline_written` and `mute_redacted` once each, a clean stop), no daemon launch inside a recording, 74 starts matched by 74 stops, no `orphan_quarantined` row. Reachable on every quit during such a recording, and on every failed merge.

Also seen at filing: `restoreMetaSidecar` still runs before the move, so a `<stem>.meta.json` is left in raw/ with no WAV beside it. What the Library shows for that stem was not traced here; it belongs with SEC26's held-row work.

## Scope

1. **Write in the termination flush.** In `MeetingRecorder.flushIntermediatesForTermination`, right after the `EngineTeardown.runSync` block and before the writer drains (so a slow drain inside the 9 s quit ceiling cannot starve it), call `muteTimeline.finalize()` and write the timeline through the same mode rules as `persistAfterMerge`, keyed by `final` (the stem's URL, which need not exist yet). Write only when the teardown ran and `teardown.isClean`. A teardown that timed out, or one skipped past the abandoned-call cap (`abandonedCalls.isExhausted`), may leave the tap running on the render thread while main reads `muteTimeline`, so on those branches write nothing, keep today's fail-closed quarantine, and log `mute_timeline_write_skipped` with `path` `termination`.
2. **Write on a failed merge.** In `persistAfterMerge`, drop `hasFinal` from both write conditions. A failed or wedged merge then leaves `<stem>.mute-timeline.json` beside the kept intermediates, and the orphan sweep that REC6 runs after every job completion recovers the stem as redact-then-process. Keep `producedUsableFinal, !timelineWriteFailed` as the condition for removing `.capturemode`.
3. **Factor the rule once.** Move the mode-to-spans decision (`.captureFirstRedact` all spans, `.captureFirst` manual spans only when `hasManualSpan`, `.regulatedGate` nothing) into one helper both call sites use, so the quit path cannot drift from the stop path. `mute_timeline_written` gains a `path` attribute (`stop` or `termination`); a failed write at termination emits `mute_timeline_write_failed` with the same attribute and leaves the markers, so recovery still quarantines.
4. **Copy, same commit.** GUIDE's quit sentence stays true for a quit after this lands; add one sentence that a recording with an off-the-record moment that is cut short by a crash or a force quit is kept aside in the originals folder rather than processed, which is what the notification already says.

## Explicitly not

- Persisting spans incrementally as they close, which would also cover a crash, a SIGKILL or a power loss. The render thread cannot do file I/O, and a crash leaving redaction intent with no timeline is exactly the case SEC16's quarantine exists for. Revisit only if a crash with an off-the-record span is ever seen.
- The quarantined copy being reaped after 30 days, and the row that offers a Retry that cannot work: [SEC26](./SEC26.md).
- The start-time `.capturemode` and `.offrecord` writes being `try?`, and an unreadable manifest recovering as auto: [REC21](./REC21.md), whose "explicitly not" treats the timeline write as shipped in SEC16; the quit and failed-merge gap is this task's.
- The same render-thread read of `muteTimeline` in `stop()` after a timed-out `teardownEngine`: pre-existing, observed here, not filed; whoever lands this should note it in the commit body if the helper in item 3 makes it trivially fixable.
- Flag markers at quit: done in [REC26](./REC26.md).
- The 9 s quit ceiling and stuck-teardown handling: [REC13](./REC13.md).
- The wider question of whether the regulated gate and stop-time cut survive: [MIC18](./MIC18.md).

## Acceptance

- `MeetingRecorderTests` (or a new focused suite): a `.captureFirst` recording with one manual off-the-record span, ended by `flushIntermediatesForTermination`, leaves `<stem>.mute-timeline.json` with that one `.manual` span and both start markers; the same under `.captureFirstRedact` writes every span; under `.regulatedGate` and under `.captureFirst` with no manual span, no file. An injected teardown that times out writes nothing and logs `mute_timeline_write_skipped`.
- A failed-merge test: `stop()` with a merge that produces no final writes the timeline for the stem and keeps `.capturemode`.
- `OrphanRecordingRecoveryTests`: an orphan with intermediates, an `.offrecord` marker and the timeline written by the flush lands in `ready`, not `quarantined`, and no `orphan_quarantined` is emitted; then `MuteRedactor.redactIfNeeded` on the merged final returns `.redacted` and the manual span is zero-filled on the mic channel. The existing no-timeline quarantine tests stay green unchanged.
- A paragraph in `CONVENTIONS.md`'s event-log section, beside the REC2x ones, names `mute_timeline_written`'s new `path` attribute and the `mute_timeline_write_skipped` action (category `recorder`, already listed); `python3 scripts/truth_fences.py events` green.
- `docs/GUIDE.md` updated in the same commit per scope item 4.
- `cd daemon && swift test` green with the number of new tests in the commit body; `bash scripts/ci-local.sh` green.

## Owner walkthrough

1. [session] Confirm the installed build is newer than the landing commit.
2. [owner] Start a short test recording, press the off-the-record hotkey for about ten seconds and press it again, then pick Quit MeetingPipe from the menu bar while still recording. Reopen the app if launch at login did not.
3. [session] Check `events.jsonl` for `intermediates_flushed_for_termination`, then on relaunch `mute_timeline_written` with `path` `termination`, `orphan_recording_recovered` for the stem, `mute_redacted`, and no `orphan_quarantined`. Pass: the meeting appears in the Library and its transcript has nothing in the off-the-record span.
