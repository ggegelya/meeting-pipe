---
id: PERF8
title: Naming a speaker re-derives the whole library from disk, so one pick costs 2-5 seconds
category: Performance
status: partial
priority: P2
comment: Filed 2026-08-18 from the owner's report that picking a name in the transcript takes 2-5 s and sometimes freezes the UI. Measured the same day against the owner's library (287 stems, 2263 files, 18 GB): every disk step is cheap (overlay write 2 ms, full transcript re-parse 17 ms, library rescan 30 ms, and no subprocess runs on the reassign path at all), so the cost is everything that surrounds the write. One pick writes the sidecar synchronously on main, re-reads and re-parses the whole transcript before the row repaints, trips the directory watcher with its own write (no self-write suppression exists anywhere in the daemon), and 500 ms later bumps the single global `MeetingStore.revision`, which wakes eight library-wide consumers. Scope: give the speaker overlay the in-memory optimistic model `saveCorrection` already uses for text edits, coalesce the write off-main, and stop the app rescanning for sidecars it authored. **Amended 2026-08-18 on the owner's sudden-shutdown question**, which exposed a live data-loss defect the first draft had waved out of scope: `SpeakerLabelStore.write` removes the real sidecar before renaming the temp over it, so a death in that window loses every name ever assigned to that meeting rather than just the edit being saved, and nothing ever reads the orphaned `.tmp`. Same shape in `TranscriptCorrectionStore` and `CorrectionStore`; `WorkflowStore.persist` already does it correctly with `replaceItemAt`. Atomic replacement plus a flush from `flushAndExit()` is now scope item (0) and a precondition for deferring any write. The unaccounted seconds are hypothesised to be SwiftUI relayout of the 1243-row transcript list; pinning that with an owner-run profiler capture is step 1 and the rest of the work is gated on it. **Scope item (0), the crash-safety precondition, shipped 2026-08-19. Items (1) to (4) are deliberately NOT started:** the spec gates them on a profiler capture ("do not start writing the fix before that capture exists"), and that capture is walkthrough step 2, owner-run. Item (0) is not gated on it, because its justification is independent of where the latency is: it is a data-loss window, not a performance redundancy, and the spec makes it a precondition that lands first. **What shipped:** all four writers replaced `write(temp)` + `removeItem(dest)` + `moveItem` with `data.write(to:options:.atomic)`, which already does temp-and-rename and has no window where the destination is absent. **The spec named three stores; there were four.** A sweep found the identical shape in `PipelineFailureSidecar.write`, which the spec's three-store scoping missed because its rationale was irreplaceable hand-made data and a failure sidecar is regenerable. Fixed anyway: the shape is strictly worse than the one-liner, it is the same four lines, and losing that sidecar is still user-visible (a failed meeting reads as clean in the Needs you rail and loses its retry affordance). Flagged rather than done silently, since it widens the spec's stated scope by one file. Also corrected four doc comments that claimed crash safety this shape did not have. **An honesty note on the tests, which the acceptance's wording does not survive contact with:** it asks for a test that "simulates a failure after the temporary file is written" and fails against `main`. That window opens between two operations inside one function and is not observable from outside the process, and the obvious way to force a failure, an unwritable directory, fails at the *first* step, where the old code also preserves the previous file. So the regression guard is a source fence over the four writers, which genuinely fails against `HEAD` (all four carried `moveItem(at: temp)`), with behavioural tests kept as a check on the property rather than as the guard. 4 tests added. `swift build` clean, `swift test` 2826 tests 0 failures, truth fences and dash guard clean, no pipeline change. `daemon/docs/gotchas.md` carries the lesson, including why the fence is a grep. Walkthrough step 1 done: A12's dir-level watcher constraint re-read before touching anything, and it is consistent with item (2)'s plan to suppress at the writer rather than the watch. **Owner-owed and blocking:** the `sample` capture. With MeetingPipe running and a long meeting's Transcript tab open, run `sample <pid> 5 -f /tmp/perf8.txt` and reassign a line while it samples, then hand the file back. About a minute, and it decides whether the SwiftUI-layout hypothesis stands or the spec gets amended before any of (1) to (3) is written. Amended 2026-11-13 by the audit band: once item 2 suppresses self-written rescans, every app writer must publish directly.
---

# PERF8: naming a speaker re-derives the whole library from disk, so one pick costs 2-5 seconds

Band origin: filed 2026-08-18 from the owner's report ("naming people in transcripts is extremely slow, I pick someone from the dropdown and wait 2-5 seconds, sometimes the UI freezes"), investigated the same day against the owner's live library. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## The measurement that reframes the task

Every candidate cause that sounds expensive was benchmarked on 2026-08-18 against the owner's real library (287 stems, 2263 files, 18 GB under `~/Documents/Meetings/raw`), and all of them are cheap. The numbers below are best-of-N from compiled Swift running the same calls the app makes, against the same directory, on the owner's machine.

| Step in one "Assign to ... person" | Measured |
|---|---|
| `SpeakerLabelStore` read + write of the overlay sidecar | 2 ms |
| `TranscriptLoader.load` of the largest transcript (2.5 MB, 1243 segments, 22191 words) | 17 ms |
| `MeetingStore.performScan` equivalent: enumerate 2263 entries, group into 287 stems, build signatures | 30 ms |
| `mp roster enroll` subprocess, on the naming paths that spawn one | 116-162 ms (from `roster_enroll_requested` to `roster_enroll_done` in `events.jsonl`) |

Total disk work is under 100 ms against an observed 2-5 s. The transcript JSON parse in particular is a red herring: `JSONSerialization.jsonObject` on the 2.5 MB file is 15 ms and the segment loop over it is 1 ms.

The subprocess is not involved at all in the slow interaction. The owner's `events.jsonl` for 2026-08-18 shows 22 `segment_reassigned` events between 18:10:28Z and 18:18:41Z with zero pipeline spawns in the window (the only other events are `halbus` subscribe/unsubscribe pairs and one `detail toolbar_action`). Reassignment is a pure local overlay write.

So the latency is not I/O, not JSON, and not Python. It is what the app does *around* the write.

## What actually happens on one pick

`TranscriptRow`'s context menu nests `Menu("Assign to...")`, whose buttons call `onReassignTo(target.assignKey)`. That reaches `TranscriptTab.reassign(indices:toLabel:)`, whose whole body is two statements:

```swift
_ = libraryModel.reassignSegments(stem: meeting.stem, indices: indices, toLabel: label)
Task { await reload() }
```

Those two statements set off four layers.

**1. The write is synchronous on the main thread and mutates the watched directory four times.** `MeetingLibraryService.reassignSegments(stem:indices:toLabel:)` is documented "Synchronous: it only writes the sidecar", and it is called without an await from the view. `SpeakerLabelStore.write(overlay:stem:in:)` does `data.write(to: temp, options: .atomic)` (itself a create plus rename), then `fileExists`, then `removeItem`, then `moveItem`. Four directory-mutating operations for a 150-byte file.

**2. The pane throws away its parsed state and re-reads the transcript from disk.** `TranscriptTab.reload()` re-runs `TranscriptLoader.load` (full re-read and re-parse of `<stem>.json`), `RosterProfile.people()`, `MeetingCast.members(segments:overlay:)`, `VoiceResolution.derive(...)` and `MarkerFile.read(stem:in:)`, then replaces `segments`, `speakerOverlay`, `voiceprintLabels`, `cast`, `voices` and `markers` wholesale. **The row the owner just clicked does not repaint until that round trip finishes.** There is no optimistic update: the app writes a fact to disk and then reads the same fact back to learn what it already decided.

**3. The app cannot tell its own writes from anyone else's.** `MeetingStore.attachWatcher()` opens the recordings directory with `DispatchSource.makeFileSystemObjectSource(fileDescriptor:eventMask:queue:)` on `[.write, .delete, .rename, .extend]`. The four operations from layer 1 land in exactly that directory, so the watcher fires, `scheduleDebouncedRefresh()` waits out `debounceSec` (0.5 s), and `refresh()` runs a full `performScan`. There is no self-write suppression anywhere in the daemon (grep for `suppress` / `selfWrite` / `expectedWrite` returns only unrelated detection-state matches). **That 0.5 s is a hard latency floor sitting after the work the owner asked for, on every single pick.**

**4. The rescan bumps one global counter that eight subsystems listen to.** `refresh()` ends with `self.revision &+= 1`, and `revision` is a single `@Published` broadcast for the entire library. Its consumers each re-derive:

- `LibraryListView.recomputeDerived()` via `.onChange(of: store.revision)`
- `LibraryWindow.recomputeCounts()` via `.onChange(of: meetingStore.revision)`, which calls `ScopeCounts.build` with `ftsMatches: { model.matchingStems($0) }`
- `LibraryWindow.reloadFacts()`, which runs `FactsLoader.load(meetings:now:)`, documented "Blocking disk I/O over the whole library" and re-reading all 249 `<stem>.summary.json` files
- `LibraryWindow.resolveTranscriptJump()`
- `PeopleView.reaggregate()`, which re-reads every meeting's overlay and summary (`SpeakerLabelStore.read` plus `MeetingSummary.load` in a loop over all 287 rows)
- `StatsView.reload()`
- `SummaryTab`'s `.task(id: SummaryReloadKey(stem:revision:))`
- `MeetingDetailView`'s `.task(id: PublishURLsReloadKey(stem:revision:))`
- `TranscriptTab`'s own `.task(id: TranscriptReloadKey(stem:revision:))`, which reloads the pane a second time

Most of those are guarded (UX52's `TranscriptLoader.fingerprint` makes the second transcript reload four `stat` calls instead of a re-parse, and the counts and derived-list caches have fingerprint keys), and the ones that are not guarded run off-main. That is why the measured totals are small. The point is not that any one consumer is slow. The point is that **a 150-byte local edit to one meeting wakes the entire library**, and does so behind a mandatory half-second debounce.

## The part that is inferred rather than measured

Measured disk work is under 100 ms and the debounce floor is 500 ms. That leaves roughly 1.5 to 4.5 seconds unaccounted for, and the remaining suspect is SwiftUI invalidation and layout.

`TranscriptList.body` is `ScrollView { LazyVStack { ForEach(segments) { ... } } }` over 1243 rows. Each `TranscriptRow` is a `Button` wrapping a wrapped-text `Text(segment.text)` with `.fixedSize(horizontal: false, vertical: true)`, two `.overlay` layers, an `.onHover` that pushes and pops `NSCursor`, and a `.contextMenu`. The ForEach closure recomputes `MeetingCast.rowSpeaker(for:overlay:voiceprintLabels:)`, `MeetingCast.colorIndex(for:in:)` and `MeetingCast.assignTargets(for:cast:overlay:)` per row, and the body opens with `TranscriptMarkerLayout.assign(markers:to:)` plus `segments.map(\.index)`, both O(segments).

Because `reload()` replaces `segments`, `cast` and `overlay` with new instances, every realized row is invalidated and variable-height text has to be re-measured. That is main-thread layout work, which is also the only candidate in the chain that explains the freezes the owner reports (every measured piece is either off-main or single-digit milliseconds).

**This is a hypothesis, not a measurement, and pinning it is step 1 of the work.** A `sample` or Instruments Time Profiler capture taken while one reassignment is performed will either confirm it or redirect the task. Do not start writing the fix before that capture exists, and record what it showed in the ship note. If the capture says the time is somewhere else entirely, amend this spec rather than building against a refuted theory.

## The precedent that says what "fixed" looks like

The same file already does the right thing for the neighbouring edit. `TranscriptTab.saveCorrection(for:newText:offerVocabulary:)` is documented "Persists the edit and patches the in-memory segment so the row updates without a full reload", and its body writes the correction store and then patches `segments[i]` in place. It never calls `reload()`.

So a transcript **text** edit is already optimistic and local, while a transcript **speaker** edit re-reads the world. There is no design reason for the asymmetry; the speaker path grew through FEAT3-UNDO and FEAT3-SEGMENT with a reload as the refresh mechanism and nobody revisited it. Fix (1) below is making the speaker path do what the text path already does.

## Crash safety: a durability defect that is already there, and that this task must not widen

Raised by the owner on 2026-08-18 when reviewing this spec: "did you take into consideration sudden shutdown? if the app got quit mid-save, it should be failsafe". The answer is that the current write is **not** failsafe, that it fails in the worse of the two possible directions, and that the write-behind in scope item (1) would widen the exposure window unless the two land together.

`SpeakerLabelStore.write(overlay:stem:in:)` saves like this:

```swift
try data.write(to: temp, options: .atomic)
if fm.fileExists(atPath: url.path) {
    _ = try? fm.removeItem(at: url)
}
try fm.moveItem(at: temp, to: url)
```

Between the `removeItem` and the `moveItem` the real sidecar **does not exist**, and the only copy of the data is in `<stem>.speaker_labels.json.tmp`. `SpeakerLabelStore.read(stem:in:)` is fail-open, so a missing file reads as `.empty`, and nothing in either tree ever reads or sweeps a `.tmp` (grepped 2026-08-18: `CorrectionStore` is the only file that even names the extension, as its own temp path). A process death inside that window therefore does not lose the edit being saved, it **silently loses every speaker name the owner ever assigned to that meeting**, unrecoverably.

That is the wrong failure direction. A save that fails should leave the previous state intact; this one destroys the previous state first and then tries to install the new one.

The repo already contains the correct pattern, one file over. `WorkflowStore.persist` writes a `.writing` sibling then calls `fm.replaceItemAt(url, withItemAt: tmp)`, and its type doc says why: "Saves write through a `.writing` sibling then `replaceItemAt` for crash safety." `replaceItemAt` is an atomic replacement with no window where the destination is absent. Plain `data.write(to: url, options: .atomic)` is equally safe and simpler, because that option already writes to a temporary file and renames it into place; the manual temp-remove-move dance is both redundant and strictly less safe than the one-liner it wraps.

**The same defect is in three stores, and all three hold hand-made edits that cannot be regenerated.** `SpeakerLabelStore.write` (speaker names), `TranscriptCorrectionStore.write` (transcript text fixes) and `CorrectionStore.record` (summary corrections) each use the remove-then-move shape. The pipeline can re-derive a transcript or a summary; it cannot re-derive which voice the owner said was Sudip.

This is not theoretical for this app. Four `.ips` reports landed on 2026-08-13 and 2026-08-14, and REC12 is a confirmed uncatchable ObjC exception that aborted the daemon within 100 ms of a prompt. A `SIGABRT` runs no termination handler at all.

### What the write-behind has to guarantee

The graceful half already has a seam. `AppDelegate.flushAndExit()` is the single synchronous teardown path for both `applicationWillTerminate` and the SIGTERM dispatch source, it is already used to flush the recorder (REC2 / AUD-6), and REC13 armed a 9 s ceiling over it. A pending-overlay flush belongs there, beside the recorder flush, and it must be synchronous and cheap (a 150-byte write) so it cannot be what makes that path miss its ceiling.

The ungraceful half cannot be flushed at all, so it has to be bounded instead:

- The coalescing window is short and stated as a named constant with its reasoning, not tuned by feel. Sub-second is the target, so the worst case a `SIGKILL` or panic can cost is roughly one pick, which the owner would notice and redo, rather than a batch of twenty which they would not.
- Every write is atomic replacement, so a death mid-write leaves either the old overlay or the new one, never neither.
- Anything that ends the pane's ownership of the in-memory overlay flushes first: switching meetings, switching tabs, closing the Library window, and app deactivation. A batch of edits must never survive only in a view's `@State`.

Under those three, the exposure a `SIGKILL` can reach is one coalescing window of edits, and the exposure it can reach *today*, through the remove-then-move window, is the entire file. The net durability after this task is better than before it, which is the bar this task has to clear rather than merely not regress.

## Prior art to not re-litigate

TECH-A12 (resolved 2026-05-28, in [`q3-final.md`](../q3-final.md)) already fixed the scan's *parse* cost with the per-stem mtime cache in `performScan`, which is why the measured rescan here is 30 ms rather than seconds. Its resolution note also recorded, after a stop-and-ask, that the watcher is dir-level and "gives no per-file change event, so the stop-and-ask resolves to the mtime cache rather than a watch upgrade".

That finding stands and this task does not overturn it. Fix (2) below does not need per-file events from the watcher: the app knows the path it is about to write, so suppression is a property of the writer, not of the watch. Read A12's note before touching `MeetingStore` so the dir-level constraint is not rediscovered a third time.

## Scope

Five changes. (0) is a correctness precondition and lands first or alongside (1); (1) and (3) are the interaction; (2) removes the floor; (4) is optional and may be split out.

**(0) Make the overlay write crash-safe, before anything is allowed to defer it.** Replace the temp-remove-move shape with an atomic replacement, either `data.write(to: url, options: .atomic)` directly or `WorkflowStore.persist`'s `replaceItemAt` idiom. The seam is `SpeakerLabelStore.write(overlay:stem:in:)`, plus the identical shape in `TranscriptCorrectionStore.write` and `CorrectionStore.record`. Fixing all three is the recommendation, because it is the same few lines in each and leaving two known-broken copies of a data-loss bug is the doc-and-code-truth debt DOC7 and HYG6 keep clearing; narrowing it to `SpeakerLabelStore` alone is the owner's call to make, not a session's. Also flush any pending in-memory overlay from `AppDelegate.flushAndExit()`, beside the existing recorder flush, and on every event that ends the pane's ownership of it.

**(1) Make the speaker overlay an in-memory model with coalesced write-behind.** The pane owns `speakerOverlay`; a pick mutates it in memory and the row repaints on the next frame. The disk write is coalesced and moves off the main thread. The seam is `TranscriptTab.reassign(indices:toLabel:)` plus the four sibling actions that share its shape (`resetReassignment(indices:)`, `nameSpeaker`, `renameSpeaker`, `undoNaming`), and `MeetingLibraryService.reassignSegments(stem:indices:toLabel:)` / `resetSegmentReassignment(stem:indices:)`. Follow `saveCorrection`'s pattern. A batch of 20 picks should produce one write, not 20.

**(2) Suppress the app's own overlay writes in the library watcher.** The daemon should not rescan the library because it wrote a sidecar it authored. The seam is `MeetingStore` (`scheduleDebouncedRefresh()` / `refresh()`) plus whatever records the intent at the writer. The target is not a faster scan (A12 already did that) but no `revision` bump at all on a local overlay edit, which removes both the 0.5 s floor and the eight-consumer broadcast from the naming path.

**(3) Stop the full transcript re-parse on a local edit.** A speaker reassignment changes no transcript text, so re-reading `<stem>.json` to learn a fact the app just decided is pure waste. Re-derive only the cast and voices from the segments already in memory. Falls out of (1) but is stated separately because it is a distinct waste and could be verified separately.

**(4) Optional, and separable: replace the global `revision` broadcast with a per-stem change signal.** So one meeting's edit stops waking `FactsLoader`, `PeopleView` and the rail counts for all 287 meetings. This is the deeper architectural cleanup and its blast radius crosses nine call sites. If it grows past the rest of the task, file it as its own row rather than letting it swallow this one.

## Explicitly not / out of scope

**Making the scan or the parse faster.** Both are already measured in the tens of milliseconds and neither is the problem. A fix that shaves the 30 ms scan has not moved the interaction.

**Moving ASR, diarization or `mp roster enroll` off the interaction.** The enroll subprocess is 116-162 ms when it runs, and it does not run at all on the reassignment path the owner is complaining about. Leave it where it is.

**Rewriting the reversible-overlay design.** FEAT3-UNDO's overlay-only choice (never rewriting `<stem>.json`, so the diarization label always survives) is owner-approved and correct, and it is the reason naming is undoable at all. This task changes when and how often the overlay is written and read, never whether it is the record.

**Replacing `LazyVStack` with `List` or an `NSTableView`.** Tempting if the capture blames layout, and it is a much larger change that would restyle the transcript. If the capture shows row layout dominating even after (1) and (3), say so in the ship note and let the owner decide whether a list-virtualisation task is worth its own row. Do not fold it in here.

**The `NSCursor.push()` / `NSCursor.pop()` pair in `TranscriptRow.onHover`.** Observed while investigating: a re-render that removes a hovered row can skip the `pop`, so the cursor stack can grow. It is a real smell, it is not the latency, and it is not filed. Named here so it is not lost.

**Durability beyond the coalescing window.** No journal, no write-ahead log, no undo history on disk. The bar is that a crash costs at most one coalescing window of edits and can never cost the existing file, which scope item (0) delivers. Anything stronger is a different task and nobody has asked for one.

**Note on an earlier draft of this spec.** The first version of this file listed the temp-remove-move write under out-of-scope, on the grounds that it measures 2 ms and was therefore not worth a task. That was the wrong lens: it is a data-loss window, not a performance redundancy, and the owner caught it on 2026-08-18 by asking what happens on a sudden shutdown. It is now scope item (0). Recorded here so the pickup session does not read the git history and reinstate the earlier judgement.

## Acceptance

- A profiler capture (`sample` or Instruments Time Profiler) taken during one reassignment on the owner's library is attached to the ship note, with the dominant cost named. If it refutes the SwiftUI-layout hypothesis above, the spec is amended before any fix lands.
- Reassigning one segment repaints its row without any disk read of `<stem>.json`. A test drives the reassign path against a stem whose transcript file has been made unreadable after load, and asserts the resolved display label for that segment changes anyway. It fails against `main`, where `reload()` re-reads the file.
- A batch of N reassignments produces one overlay write, not N. A test drives several reassignments inside the coalescing window and asserts the write count (via a seam that counts writes, not by timing).
- The overlay write no longer happens synchronously on the main thread from the view action.
- No write path leaves a window in which the destination sidecar is absent. A test drives the writer with an existing overlay on disk, simulates a failure after the temporary file is written, and asserts the previous overlay is still readable. It fails against `main`, where the destination has already been removed by that point.
- Quitting the app with unflushed edits loses nothing. A test drives `AppDelegate.flushAndExit()` with a pending in-memory overlay and asserts the sidecar on disk matches it afterwards.
- The coalescing window is a named constant with its reasoning in a comment, and a test asserts a pending edit is flushed by switching meetings, switching tabs, and closing the Library window, so no batch of edits lives only in view state.
- A local overlay write does not bump `MeetingStore.revision`. A test writes an overlay sidecar through the app's own path and asserts the store's revision is unchanged, while a write that did not come from the app still triggers a rescan. That second half is load-bearing: suppression that also swallows the pipeline's writes would stop finished meetings appearing.
- The pipeline's own writes still refresh the library within the existing debounce window, so A12's and UX52's guarantees survive. Pin this with a test rather than by reasoning.
- Every naming path shares the new shape: cluster naming, rename, undo, per-segment reassign, per-segment reset. A path left on the old reload is a half fix, and the owner reassigns in batches of 20.
- `cd daemon && swift build` clean, `swift test` green, with the number of tests this task adds recorded in the ship note. Do not pin an absolute suite total.
- `python3 scripts/truth_fences.py both` green.
- No em-dashes in changed lines.

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule. Steps are tagged [owner] / [session] by who acts.

The capture in step 2 is owner-run because it needs the owner's real library and a real interaction; a harness cannot reproduce a 1243-row transcript pane with 287 meetings behind it.

1. [session] Read TECH-A12's resolution note in [`q3-final.md`](../q3-final.md) before touching `MeetingStore`, so the dir-level watcher constraint is not rediscovered.
2. [owner] With MeetingPipe running and a long meeting's Transcript tab open, run `sample <pid> 5 -f /tmp/perf8.txt` and, while it is sampling, right-click a line and assign it to someone. Hand the file back. This is the measurement the whole task is gated on and it costs about a minute.
3. [session] Name the dominant cost from that capture and either confirm or amend the hypothesis above, then land (1), (2) and (3) with their tests.
4. [owner] `./scripts/rebuild.sh`, then reassign ten lines in a row in a long meeting. A pass is each pick landing immediately, with no visible pause and no beachball, and the names still correct after closing and reopening the meeting (which is what proves the coalesced write actually reached disk).
5. [owner] Say "PERF8 good to close" (or what is still slow); [session] moves the row and this spec into `q6-final.md` and deletes this file.

## Amendment 2026-11-13 (audit band)

Source: [responsiveness audit](../../audits/2026-11-13-responsiveness-audit.md) P026, P027 and P035 (its ranked fix 8, which is this task's items 1 to 3), P038 (ranked fix 5), and P033 and P036 (ranked fix 7, folded in from a proposed low class because it is the same roster-write acknowledgement seam). All low. Re-verified at HEAD (`3a2da4fc`) on 2026-11-14. The pack holds no roster, speaker or `segment_reassigned` events between 2026-09-29 and 2026-11-13, so every figure below is a code-read estimate built from this spec's 2026-08-18 measurements, not a field measurement.

**The click side of items 1 to 3 (P026, P027, P035).** `TranscriptTab.nameSpeaker(label:name:)` sets `namingTarget = nil`, so the sheet closes at once, then awaits `libraryModel.nameSpeaker`. In `MeetingLibraryService.nameSpeaker(stem:label:name:completion:)` the overlay is written through `SpeakerLabelStore.setLabel` only inside `launcher.rosterEnroll`'s success callback, and `reload()` runs after that. Between Save and the reload the transcript looks unchanged with no spinner: about 130 to 200 ms on a warm start (116 to 162 ms of enroll plus the 17 ms re-parse) and longer cold. `MeetingLibraryService.renameSpeaker` has the same shape: `launcher.rosterEnroll` first, the overlay write in its callback. `TranscriptTab.reassign(indices:toLabel:)` is still `_ = libraryModel.reassignSegments(...)` then `Task { await reload() }`, so a reassigned line repaints only after the disk round trip, tens of ms plus a list re-render.

**Undo waits for a subprocess it does not need (P035).** `MeetingLibraryService.undoSpeakerNaming` removes the overlay label first (`SpeakerLabelStore.removeLabel`), then calls `launcher.rosterForget(name:)` and fires its completion only when that subprocess exits, and `TranscriptTab.undoNaming(label:name:)` awaits it before `reload()`. That wait applies only when the label has a voiceprint; the overlay-only branch (`roster_undo_overlay_only`) completes at once. The revert the owner asked for is on disk before the forget starts, so the row could repaint at once. Whether undo should run a whole-person forget at all is [FEAT24](./FEAT24.md) (P1), not this task.

**Title rename and correction revert wait on the watcher (P038).** `MeetingDetailView+Header`'s `writeTitle(_:)` documents "The directory watcher picks up the change on the next debounce tick", and `CorrectionsTab.performRevert()` writes `summary.json` and sets `record = nil` with no refresh either. The header and the sheet update on the next frame, but the list row title and the Summary tab follow only after `MeetingStore.debounceSec` (0.5 s) and a rescan, about 0.5 to 0.6 s later.

**What this means for item 2.** Item 2 stops the app rescanning for writes it authored. Today the watcher is the only thing that makes these writers (and the overlay writers, once item 1 lands) reach the list, so once self-writes are suppressed every such writer must publish directly: call `MeetingStore.refresh()` or patch the model, and finish by bumping `MeetingStore.revision` rather than adding a second signal. Without that, item 2 turns a 0.5 s lag into a row that never updates.

**Roster rename and remove show nothing until mp returns (P033, P036).** `TranscriptTab.renameEverywhere(currentName:)` closes `RosterRename.prompt` and runs `RosterRename.run`; the chip keeps the old name until the carry finishes and `reload()` lands, about 0.4 s and up. `PreferencesView+Pipeline`'s `beginRename(_:)` and `beginRemove(_:)` set only `rosterError = nil` before the async `RosterRename.run` or `launcher.rosterForget`, so the row keeps the old name and both buttons stay live for about 0.3 to 0.7 s. `PeopleView.beginRename(_:)` already does the minimum right: `renaming = person.name` before the call, and the row shows a small `ProgressView` in place of its rename button until `renaming = nil`. Clarification at filing: PeopleView today shows a spinner, not the new name; showing the new name at the click is the low note's proposed improvement, kept optional in item 7.

**Surfaced, not adopted.** The audit's ranked fix 8 runs `mp roster enroll` behind an optimistic overlay and reconciles. This spec's Explicitly not leaves enroll where it is, and items 1 to 3 stay gated on the owner's `sample` capture. This amendment overrides neither. If the capture shows enroll dominating the naming path and the owner moves it behind the overlay, a failed enroll must visibly revert the name (otherwise the overlay and the voiceprint disagree), and the one-row-one-speaker rule (UX57 to UX59) and the carry tests (UX66) apply.

**Added to scope.** Items 5 to 7 change the order of acknowledgement, not where the latency sits, so they are not gated on the capture.

- 5. Undo repaints from the overlay removal: `undoSpeakerNaming` reports the overlay outcome to its caller before `rosterForget` runs (a split completion or an async split), and `undoNaming` reloads on that; a forget failure keeps its existing `notifyError`.
- 6. Move the title write (`MeetingDetailView+Header`'s `writeTitle(_:)`) and the revert write (`CorrectionsTab.performRevert()`, a private view method on a view with no store) into `MeetingLibraryService` methods that end in its injected `refreshLibrary()`, the UX52 precedent that already asks `MeetingStore` to rescan and bump `revision`; the views call those. Required by item 2 whichever lands first, harmless before it.
- 7. A busy state for roster rename and remove: `TranscriptTab.renameEverywhere` and `PreferencesView+Pipeline`'s `beginRename` and `beginRemove` adopt PeopleView's per-row flag, set at the click, disabling both Rename and Remove for that row behind a small spinner, cleared in the completion, with the old row and the error kept on failure. Showing the new name or striking the removed row at the click is optional; if done, a failure restores the old row. The flag lives on a model the navigator does not rebuild (UX37), not only in a view's `@State`.

**Added to acceptance.**

- Undo: with a launcher whose `rosterForget` never completes, the overlay label is gone and the pane's reload has run.
- The two new `MeetingLibraryService` methods each call the injected `refreshLibrary` exactly once after a successful write and not at all after a failed one (a counting closure, no store or watcher needed).
- People pane and cast chip: with a launcher that never completes, the row's busy flag is set and Rename and Remove are disabled; with a failing launcher the row keeps the old name and shows the error.
- `cd daemon && swift build` and `swift test` green, with the number of tests added in the ship note.

Related: [UX105](./UX105.md) (the same busy pattern for move, evict, clear peaks and launch at login), [DV7](./DV7.md) (rename everywhere and open actions), [FEAT19](./FEAT19.md), [ARCH10](./ARCH10.md), [PIPE55](./PIPE55.md) (title precedence between the Library and the pipeline, adjacent to the title rename), [STOR7](./STOR7.md) (trash acknowledgement), [OBS7](./OBS7.md) (which would make these clicks measurable).
