# PIPE18: PIPE11's duplicate-click coalescing covers one enqueue path of three, so seven Retry clicks queued seven full pipelines

Band origin: filed 2026-08-14 from the owner's report the same day, with a screenshot showing `Processing 7` in the Library toolbar above a meeting reading `Queued: Reprocess` and `Pipeline failed`: "in screenshot I clicked retry for 7 times and it put in queue 7 times. not good, I should not be able to put in queue something that is already there." Follow-on to PIPE11 (shipped 2026-07-24), which built exactly this guard for a different job kind. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## What happened, from the owner's event log

`20260813-170019`, a 25 m 45 s Teams meeting recorded 2026-08-13 17:00:19 to 17:26:04, whose pipeline started at 17:26:04 and emitted neither `pipeline_succeeded` nor a completion that day. Times local (UTC+3).

| Time | Event |
|---|---|
| 11:57:05 | `retry_requested` scope `run_all`, `pipeline_queued` **depth 1**, `pipeline_started` |
| 11:57:10 | `retry_requested`, `pipeline_queued` **depth 2** |
| 11:57:16 | `retry_requested` x3, `pipeline_queued` **depths 3, 4, 5** |
| 11:57:17 | `retry_requested` x2, `pipeline_queued` **depths 6, 7** |
| 11:57:24.199 to 11:57:25.260 | `pipeline_dequeued` x6, roughly 150 ms apart, depth 6 down to 1 |
| 11:58:11 | `pipeline_succeeded` for the run started at 11:57:05 |

Seven identical `.full` jobs for one stem in **twelve seconds**, then six manual removals seven seconds later. Zero `pipeline_coalesced` events, because nothing on this path can emit one.

Two things that burst tells you beyond the count.

**The first click worked and the run took 66 seconds.** It started at 11:57:05 and succeeded at 11:58:11. So every click from the second onward was made while the retry the owner wanted was already running.

**The clicks accelerate.** 5 s, then 6 s, then three inside one second, then two more. That is the shape of someone concluding nothing is happening and pressing harder, not someone queueing work on purpose. The dequeue burst at the end is the same hand cleaning up, at six clicks to undo seven.

Had the owner not removed them, six more full `mp run-all` passes over a 25-minute recording would have executed in sequence: six FluidAudio transcriptions and six summarizer calls, each overwriting the sidecars the previous one wrote. Their default backend is `anthropic`, so on the cloud path that is six paid calls for a result already on disk.

## Why the guard exists but did not fire

`SinkDispatcher` has four enqueue entry points and **exactly one** is guarded.

`enqueueLibraryRun` ([SinkDispatcher.swift:135](../../../daemon/Sources/MeetingPipe/Coordination/SinkDispatcher.swift#L135)) coalesces, and its own comment names the incident that motivated it:

```swift
if processingJobs.contains(where: { $0.kind == .libraryRun(run) }) {
    Log.event(category: "coordinator", action: "pipeline_coalesced", ...)
    return false
}
```

PIPE11's ship note is explicit that this was designed behaviour: "identity is `(verb, stem, backend)`, so a duplicate click coalesces while Local-then-Anthropic stays two asks." Its doc comment records why: "on 2026-07-23 a Reprocess and three regenerates overlapped on one stem and the surviving summary was decided by which subprocess exited last."

The other three have no guard:

- `enqueue(file:summaryMode:)` ([:101](../../../daemon/Sources/MeetingPipe/Coordination/SinkDispatcher.swift#L101)), kind `.full`. **This is the one Retry uses.**
- `enqueueRetranscribe(file:)` ([:112](../../../daemon/Sources/MeetingPipe/Coordination/SinkDispatcher.swift#L112)), kind `.retranscribe`.
- the private `enqueue(job:completion:)` ([:160](../../../daemon/Sources/MeetingPipe/Coordination/SinkDispatcher.swift#L160)), which appends unconditionally and is what all three call.

So the defect class was diagnosed, fixed, and shipped a month ago, for one of the three kinds that can hit the same stem. `retryMeeting` ([MeetingLibraryService.swift:200](../../../daemon/Sources/MeetingPipe/Library/MeetingLibraryService.swift#L200)) reaches the unguarded one with a plain `enqueue(audioURL, .auto)`.

Note the harm is **not** PIPE11's race. PIPE11 serialized the lane, so seven jobs run in order rather than fighting. What is left is redundant work, redundant cost, and a final row state that depends on which of seven identical runs finished last.

## The UI half, which is why seven clicks happened at all

Coalescing alone would have made the burst harmless and would not have stopped it, because the owner was clicking to find out whether anything had happened.

`runRetry` ([SummaryTab.swift:494](../../../daemon/Sources/MeetingPipe/SummaryTab.swift#L494)) answers success with nothing:

```swift
switch libraryModel.retryMeeting(stem: meeting.stem) {
case .success:
    break
case .failure(let err):
    ... NSAlert ...
}
```

A failure gets a modal; a success gets `break`. None of the three `Button("Retry pipeline")` sites ([:448](../../../daemon/Sources/MeetingPipe/SummaryTab.swift#L448), [:456](../../../daemon/Sources/MeetingPipe/SummaryTab.swift#L456), [:478](../../../daemon/Sources/MeetingPipe/SummaryTab.swift#L478)) consults queue state, so the button stays enabled and identically labelled while its own job runs.

The screenshot makes the contradiction visible in one frame: the header already renders `Queued: Reprocess` with a working `Remove` button, so the app knows a job is pending for this meeting and says so about 200 points above a pane that still says `Pipeline failed` and offers `Retry pipeline`. The two halves of one window disagree about whether anything is happening.

## Scope

**1. Coalesce on the unguarded kinds.** Extend the `enqueueLibraryRun` guard to `.full` and `.retranscribe`, or better, move the check into the private `enqueue(job:completion:)` all four paths funnel through, so a fifth entry point cannot forget it the way these three did. Identity is the stem for both kinds: two run-alls on one stem are redundant by construction, and so are two re-transcribes. Emit `pipeline_coalesced` on the drop, matching PIPE11, so the next occurrence is readable from `events.jsonl` alone.

A judgement call to make explicitly rather than by default: whether "already queued" should coalesce or should *replace*. Coalescing is right here (the queued job has not started, so it will pick up the same inputs), and it matches PIPE11.

**2. Make the retry affordance reflect the queue.** The button should say a run is already queued or running for this meeting, and not offer to add another. `LibraryProcessing.presentation(stem:active:pending:)` already resolves exactly this per-meeting state and is what the header's `Queued: Reprocess` line is built from, so the fix is pointing the Summary pane's retry section at the state its own header already has, not inventing new state.

Getting item 2 right is what stops the burst; item 1 is what makes it harmless when a burst happens anyway. Ship both.

## Explicitly not / out of scope

**Not PIPE11's serialization.** One global lane in request order is working and is why the seven jobs did not race. Unchanged.

**Not the `.libraryRun` guard.** It is the model for this fix, not a target.

**Not why `20260813-170019` failed in the first place.** It ran on 2026-08-13 at 17:26:04 and reached neither success nor a logged failure, and the 2026-08-14 retry then succeeded in 66 seconds. Worth its own investigation if it recurs; this task is about what seven clicks did, not about the original fault.

**Not the queue's Remove affordance.** UX28 built it and the owner used it six times successfully.

**Not UX69.** A running job being uncancellable for its first minute is adjacent and separate; this task never cancels anything.

**Adjacency, named so it is not silently absorbed:** the same screenshot shows `Processing 7` in the toolbar for a queue holding one active job and six waiting. That is UX77, filed 2026-08-10, and this is a sharper instance of it than the one UX77 was filed on. Do not fix the wording here; do link this burst into UX77 if that task is picked up later.

## Acceptance

- A `SinkDispatcher` test enqueues two `.full` jobs for the same stem and asserts the queue depth is 1 and a `pipeline_coalesced` event was emitted. It must fail against `main`, which reaches depth 2.
- The same test for `.retranscribe`.
- A test asserts two `.full` jobs for **different** stems both queue, so the guard is per-stem and does not serialize the library into a single job.
- A test asserts a `.full` job may be enqueued again once the earlier one has left the queue, so a genuine second retry after a second failure still works. This is the clause that makes the guard a coalescer rather than a lockout.
- A test over the retry affordance's derived state asserts it is not offered while a job for that stem is queued or active, driven from the same `LibraryProcessing.presentation` the header uses, so the two halves of the window cannot disagree again.
- `pipeline_coalesced` is already in the `CONVENTIONS.md` event table from PIPE11; confirm it and keep `python3 scripts/truth_fences.py both` green.
- `cd daemon && swift build` clean, `swift test` green, with the number of tests this task adds recorded in the ship note. Do not pin an absolute suite total.
- No em-dashes in changed lines; repo dash guard green.

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule. Steps are tagged [owner] / [session] by who acts.

1. [session] `./scripts/rebuild.sh` after landing, then tell the owner it is ready.
2. [owner] Find any failed meeting (or make one fail) and press **Retry pipeline** once. Pass: something visibly changes immediately, so you can tell the click landed. That is the half that caused this report.
3. [owner] Now do what you did on 2026-08-14 and press it repeatedly, as fast as you like. Pass: the toolbar count does not climb past one for that meeting, and you have nothing to Remove afterwards.
4. [owner] Then the guard in the other direction, which matters as much: let the retry finish and fail again, and confirm you **can** retry a second time. A fix that blocks the legitimate second attempt is worse than the bug.
5. [owner] Queue work on two different meetings at once and confirm both still queue, so the guard did not collapse the library into one job.
6. [owner] Say "PIPE18 good to close" (or what is wrong); [session] moves the row and this spec into `q6-final.md` and deletes this file.
