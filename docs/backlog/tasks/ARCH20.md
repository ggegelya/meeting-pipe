# ARCH20: MeetingStore.buildMeeting is a 189-line status ladder that mixes the failure rule, the duration source and cacheability

Band origin: filed 2026-10-25 from the 2026-10-25 code-quality audit band ([code-quality audit](../../audits/2026-10-25-code-quality-audit.md) SW12). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Re-checked at filing on 2026-10-25: the duration source is no longer inline, since [UX74](./UX74.md) (shipped 2026-08-18, row `partial` awaiting the owner's walkthrough) moved it into `MeetingStore.duration(audio:transcriptJSON:startedAt:)` and `buildMeeting` only calls it; what remains mixed is the failure rule, the status ladder and cacheability, and the same ladder exists twice more outside the function and has already diverged from it.

`MeetingStore.buildMeeting(stem:files:directory:)` is 189 lines, 127 of them code. Between the file lookups and the `Meeting(...)` memberwise call it decides, in this order:

1. **Which failure counts.** A recorded `PipelineFailureSidecar.Failure` is kept when `summaryURL == nil || recorded.stage == .publish || (recorded.metadata != nil && <error newer than summary>)`, otherwise dropped.
2. **The status and whether the row may be cached**, as five paired assignments: failure, then `.done`, `.manualPasteReady`, `.empty` (each `cacheable = true`), then an age branch that reads `Date()` inline and answers `.failed` past `Meeting.staleProcessingThresholdSec` or `.processing`, with `cacheable = false`.
3. **Whether there is a row at all**: `guard audio != nil || hasTerminalSidecar`, where `hasTerminalSidecar` is a second list of the same four sidecars the ladder just tested.
4. Inside the memberwise call, a second failure rule: `failureReason`, `failureStage` and `failureMetadata` fall back to a partial `publishResult`'s failed sinks when there is no recorded failure, and `canReuseTranscript` re-derives "failed, not at transcribe" with a disk probe.

None of it is testable except by writing files and calling `performScan`, and the age branch cannot be driven at all except with a stem far in the past (`test_failed_when_processing_older_than_staleness_threshold`), because `now` is not injectable.

**The ladder has two more copies, and one disagrees.**

- `MeetingStore.unrecoveredFailureStems(fileNames:now:)`, which feeds the menu-bar failed badge through `MeetingLibraryService.failedMeetingCount()`. Its doc comment says it matches "`buildMeeting`'s `.failed` precedence so the badge and the Library list agree", but it is filename-only and its first rule is `if f.summary { continue }`. A meeting with a summary and a publish-stage `.error.json` is `.failed` in the Library list and absent from the badge; so is one whose structured failure is newer than its summary. Read from code, not reproduced. That publish-stage disagreement is filed as UX90 (2026-10-25 observability band), which owns the badge's behaviour; this task owns only the duplicated ladder.
- `LibraryMover.inFlightReason(in:now:)` rebuilds the terminal-sidecar set from four `hasSuffix` checks and the same age constant to decide "a meeting is still being processed".

## Scope

1. **A pure `MeetingStatus.decide(_:now:) -> MeetingStatus.Verdict?`** in a new `daemon/Sources/MeetingPipe/Library/MeetingStatus.swift`, following the pure-`decide` rule in `daemon/CLAUDE.md`. Input is a value type of facts with no URLs: `hasAudio`, `hasSummary`, `hasPasteReady`, `hasEmptyMarker`, `startedAt`, and the recorded failure reduced to what the rule reads (`stage`, `hasMetadata`, `isNewerThanSummary`). Output is `nil` for "no row" (step 3 above) or a `Verdict` carrying `status`, `cacheable`, and the kept failure. The precedence moves unchanged; no status changes for any input the Library renders today.
2. **`buildMeeting` collects the facts and calls `decide`**, passing `Date()` at the one call site. The duration call, the `source_kind` switch, search text and the memberwise call stay where they are. The partial-publish failure fallback (step 4) moves into the verdict only if it fits without a second input type; otherwise leave it and say so in the commit.
3. **`unrecoveredFailureStems` calls the same `decide`, after UX90.** UX90 decides what the badge counts for a publish-stage failure; this step only removes the second copy of the rule. If UX90 has not landed when this task is picked up, skip this step and say so in the commit, so the badge's behaviour changes in exactly one task. To stay cheap it stays filename-first and reads a `<stem>.error.json` only for stems that also carry a summary, which is the only case where the stage decides the answer. The badge then counts exactly the Library's `.failed` rows. Rewrite its doc comment to what it now does.
4. **`LibraryMover.inFlightReason` asks `decide` whether a stem is `.processing`** instead of its own suffix chain.

## Explicitly not / out of scope

- The session-spine long methods (`beginRecording`, `stopRecording`, `Coordinator.init`): [ARCH7](./ARCH7.md).
- The badge's publish-stage behaviour and its notification copy: UX90.
- Duration: [UX74](./UX74.md) owns the source order and its tests; this task calls `MeetingStore.duration` unchanged and must not reorder it. UX74's owner walkthrough is unaffected.
- Sidecar names and suffix lists: [ARCH10](./ARCH10.md)'s `MeetingFiles` owns them. Whichever lands second makes the facts builder in `buildMeeting`, `unrecoveredFailureStems` and `LibraryMover` read `MeetingFiles`' suffixes.
- The other long functions the audit named (`MeetingSourceScanner.enumerateCandidates` 161 lines, `SinkDispatcher.runDaemonTranscription` 146, `MuteRedactor.redactIfNeeded` 126, `TranscriptOverlayCarry.carry` 104): on next touch only, not filed.
- Moving `Meeting.Status` into `MeetingPipeCore`: it is a Library type with no detection or mute consumer.

## Acceptance

- New `MeetingStatusTests` (MeetingPipeTests), a table over `decide` with an injected `now`: summary only is `.done` and cacheable; publish-stage failure plus summary is `.failed` and cacheable; transcribe-stage failure plus an older summary and no metadata is `.done`; a structured failure newer than the summary is `.failed`, older is `.done`; paste-ready and empty marker are terminal and cacheable; audio only is `.processing` one second before the threshold and `.failed` one second after, neither cacheable; no audio and no terminal sidecar is `nil`; no audio plus a summary (a `drop` retention policy) is `.done`.
- If step 3 ran, a badge-agreement test: for each table row that has a final recording, `unrecoveredFailureStems` contains the stem if and only if `decide` answers `.failed` (UX90's own test pins the publish-stage row).
- Every existing `MeetingStoreTests` and `FailurePresentationTests` case passes unchanged.
- `cd daemon && swift build` and `swift test` green; `bash scripts/ci-local.sh daemon` green; new test count in the commit body; the `MeetingStore.swift` bullet in `ARCHITECTURE.md` names `MeetingStatus.decide` in the same commit.
