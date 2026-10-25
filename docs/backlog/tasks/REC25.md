# REC25: the capture writers queue without bound and count only thrown errors, so a stalled disk grows memory about 2 GB an hour unseen, and an abandoned writer's failures can force-stop the next recording

Band origin: filed 2026-10-25 from the performance review (eight subsystem finders over HEAD 01e904a, every finding adversarially re-verified). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Review findings PERSISTENCE-10 (medium, plausible) and RECORDING-3 (the verifier downgraded it to low, plausible). Re-checked in code at `01e904a` on 2026-10-25.

**The queue has no depth.** `SerialBufferWriter.enqueue` is `queue.async { [handle] in handle(item) }` on a `.utility` serial queue, and its header says so on purpose: "The unbounded backing queue never drops or blocks the producer - the contract ADR 0009 mic/system frame parity depends on." The mic writer (built in `MeetingRecorder.buildMicChain`) and the system writer (`SystemAudioChannel.openSystemFile`) each call `write(from:)` and report only a thrown error, through `noteWriteOutcome(channel:success:)` and `noteWriteOutcome?(ok)`, to a `WriteFailureTracker` that escalates on 32 consecutive failures (REC3).

**A write that blocks instead of throwing is seen by nothing.** No pending count exists, and nothing watches writer progress during a recording: `InputDeviceRecovery.checkTapLiveness` watches tap callbacks, `SystemAudioChannel.checkSystemLiveness` watches SCStream delivery, and `StopStallWatchdog` acts only at stop. Owned buffer copies pile up at the capture rate, 192,000 B/s for the mic (mono Float32 at a 48 kHz device) plus 384,000 B/s for the system channel (48 kHz stereo Float32), about 2.07 GB per hour, while the HUD shows live levels. With `jetsam memory limit (active) = (unlimited)` for the job (REC20's 2026-10-24 reading) that is memory pressure and swap under a live recording rather than a kill, on the owner's 48 GB Mac after many hours and on a 16 GB Mac sooner; if the process does die, the in-memory backlog, the mute timeline and the flagged moments go with it. Reachability is the uncertain half: the default library on local APFS does not hang (iCloud uploads asynchronously; a yanked USB disk returns EIO fast, which escalates), so a write that hangs needs a network or file-provider output directory, which the library move flow (`LibraryMover`) and the free-text output path ([UX89](./UX89.md)) both accept.

**Stop already copes.** `MeetingRecorder.drainWriters` bounds each drain at `writerDrainTimeoutSeconds` (10 s), abandons a wedged queue, skips the merge and keeps the intermediates (REC7), so a stalled disk cannot wedge `.stopping`.

**An abandoned writer counts against the next recording.** The trackers are recorder fields, `micWriteFailures` and `systemWriteFailures`, documented as "touched only on its own writer's serial queue ... so no lock is needed" (`WriteFailureTracker`'s doc says the same). But `start()` replaces both on main (`micWriteFailures = WriteFailureTracker()`), and a writer abandoned by the previous stop keeps calling `self?.noteWriteOutcome(channel: .mic, success: ok)` into whichever tracker is current. A run of 32 thrown failures from that backlog escalates against the new recording: `noteWriteOutcome` emits `recording_error` and hops `onWriteFailure` to main, and `Coordinator`'s handler posts "Recording stopped: couldn't keep writing mic audio to disk (the disk may be full)..." and calls `session.forceStop(reason: "write_failure_mic")`, stopping a healthy recording, or posting that notice with nothing recording. The reset itself is a data race with the old queue's mutation of the same struct. It needs a drain abandoned past 10 s followed by a run of thrown failures, which is rare: a full disk fails fast and does not time out the drain, and a stalled disk that recovers produces successes.

## Scope

1. **`SerialBufferWriter` counts what is pending.** A lock-guarded (`OSAllocatedUnfairLock`) or atomic byte counter, incremented in `enqueue` by a size the caller supplies (`init(label:size:handle:)`; for `AVAudioPCMBuffer`, `frameLength` times the format's bytes per frame) and decremented after `handle`, plus a high-water mark, both readable from any thread.
2. **A pure backlog policy on the existing 1 Hz ticks.** Evaluated in `checkTapLiveness` and `checkSystemLiveness` (main, already firing once a second; no new timer, nothing on the writer queue): above a soft threshold (proposed 30 s of that channel's audio, from its own file format) emit `recorder`/`writer_backlog` once per recording with `channel`, `pending_bytes` and `pending_sec`; above a hard cap that is memory-based and high (proposed 512 MB across both channels, about 15 minutes of capture) escalate through the existing `onWriteFailure` path so REC3's force-stop keeps the prefix. The `stopping: mic_fires=...` line gains both channels' backlog high-water marks.
3. **Each writer owns its failure tracker, and an escalation names its recording.** Build the tracker with the writer and capture it in the write closure, so only that writer's queue mutates it; give the recorder a recording generation bumped in `start()` and captured by each writer, and have the main-queue hop drop an escalation whose generation is not current, logging `recorder`/`write_failure_stale`. Correct the two comments that claim single-queue ownership.

## Explicitly not

- Dropping or coalescing buffers under backpressure. It breaks ADR 0009's frame parity, and a force-stop that keeps the prefix is the house answer (REC3).
- Raising the writer QoS from `.utility`. About 0.5 MB/s of writes does not need it (verifier).
- Counting write failures shorter than the 32-buffer streak: [REC22](./REC22.md) (the observability audit's O19). It changes the same tracker, so whichever lands second rebases onto the other's tracker shape.
- The force-stop notice's cause: [REC19](./REC19.md) item 3 owns `recording_error`'s `cause`; if it lands first, `writer_stalled` joins its vocabulary.
- Free-space preflight and a low-space stop: [REC20](./REC20.md).
- An SCStream whose `stopCapture()` timed out still delivering into the next recording's system writer (the review's RECORDING-2 ([REC28](./REC28.md)), owned by another area of the same review): a different way one recording leaks into the next.

## Acceptance

- `SerialBufferWriterTests`: with the handler blocked on a semaphore, `pendingBytes` equals the sum of enqueued sizes and the high-water mark holds it; after release and drain the count is 0 and the mark keeps the peak; enqueues from two threads keep the count exact.
- `WriterBacklogPolicyTests` (pure): below soft is fine; crossing soft warns once and not again on the next tick; crossing the hard cap returns stop; the soft threshold follows the channel's byte rate (a 96 kHz mic warns after the same seconds as a 48 kHz one, not the same bytes).
- A test over the tracker-and-generation seam (pure, no engine): failures from a generation-1 writer arriving after generation 2 started never reach `onWriteFailure`, emit `write_failure_stale`, and leave generation 2's tracker untouched; 32 failures inside generation 1 still escalate once.
- `writer_backlog` and `write_failure_stale` documented in `CONVENTIONS.md`; `python3 scripts/truth_fences.py events` green.
- `cd daemon && swift build` and `swift test` green, new test count in the commit body; `bash scripts/ci-local.sh` green.
