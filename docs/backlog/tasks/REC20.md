# REC20: a recording starts with no free-space check and is never watched for low space, transcription loads the whole meeting into the recorder's process, and the library only ever grows unless a workflow opts in

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) PD-13). Takes over the "Transcription RAM peak (2026-07-12)" item from the watch list in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Three unbounded resources, verified in code on 2026-10-24.

**Disk during a recording.** The intermediates grow at a fixed rate: the system channel at 384,000 bytes a second (`SystemAudioCapture.captureFormat`, 48 kHz stereo Float32) and the mic at 192,000 bytes a second at a 48 kHz device (mono Float32), about 2.07 GB an hour together. The stop-time merge then writes the 16 kHz stereo final (64,000 bytes a second) while both intermediates still exist. `grep -rn "volumeAvailableCapacity\|statfs"` over `daemon/Sources` finds one reader, `StorageStats` (`volumeAvailableCapacityForImportantUsageKey`), which feeds the Preferences ▸ Storage free-space row and nothing else. Nothing checks free space when a recording starts or while it runs. The only defence is REC3's write-failure force-stop (`WriteFailureTracker`), which fires after 32 consecutive failed writes, by which time the whole Mac is out of space, and whose notification REC19 is correcting.

**Memory during transcription.** `FluidAudioRunner.transcribe` calls `readMonoFloat32(from:)`, which allocates one `AVAudioPCMBuffer` for the entire file (`frameCapacity: AVAudioFrameCount(file.length)`), mixes it to a mono `[Float]`, resamples to 16 kHz, and holds that array across ASR and diarization. TECH-PERF2 scoped the full-clip buffer so it is freed once the mono array exists, which halved the peak; the watch-list note measured "about 2 GB peak for a 3 h recording". This runs inside the daemon, the same process that records, and back-to-back meetings mean meeting N transcribes while meeting N+1 records. The diarizer is the reason the read is whole-file: `FluidAudioRunner`'s doc comment says driving `DiarizerManager.performCompleteDiarization` chunk by chunk "would re-implement its speaker tracking". Nothing records the real peak: no `phys_footprint` or RSS reading exists anywhere in `daemon/Sources`. `launchctl print` on the owner's Mac shows `jetsam memory limit (active) = (unlimited)` for the job, so the risk is memory pressure and swap slowing the live recording, not a kill.

**The library over time.** STOR1's retention is per workflow and opt-in: `WorkflowRetention.policy` defaults to `.keep`, `AudioRetentionSweep.sweep` returns at once when every policy is `.keep` ("Every workflow on keep-forever is the default state"), and `AudioRetention.decide` skips any meeting with no `workflowID`. That default is the owner's (STOR1) and this task keeps it; what is missing is any surface that says where the growth is heading.

## Scope

1. **Preflight at record start.** Before `MeetingRecorder` opens its files, read `volumeAvailableCapacityForImportantUsage` for the output directory. Below the space for two hours of intermediates plus their merge (computed from the two capture rates above, documented beside the constant), still record, since a meeting is never refused, but show a HUD notice naming the free space and the hours it covers, and emit `recording_low_space_at_start` with `free_bytes` and `hours_covered`.
2. **Watch while recording.** Re-read free space every 60 s on the recorder's existing timer or a utility queue (never main). When the remaining space covers less than 15 minutes plus the merge, notify once, and when it covers less than the merge alone, stop the recording cleanly through the normal stop path, which merges, rather than waiting for the write-failure force-stop. Emit `recording_low_space` and `recording_stopped_low_space`.
3. **Measure transcription memory, then decide.** Emit the process `phys_footprint` (from `task_info(TASK_VM_INFO)`) at the start and peak of each transcription as `transcription_memory` with `audio_sec`, and record a 2 h and a 3 h meeting's numbers in this file. If the peak exceeds a threshold the pickup states (about 25% of physical memory) or a live recording overlapped a transcription with a measurable stall, the follow-up is to defer a transcription while a recording is live and memory is tight, not to chunk the diarizer; write that decision here with the numbers.
4. **Make growth visible.** The Preferences ▸ Storage pane gains one line from data it already has: the library's growth over the last 30 days and, at that rate, how long the free space lasts. `mp doctor` warns when that is under 30 days. Meetings with no `workflowID` follow the default workflow's retention (`Workflow.isDefault`), so turning retention on for the default actually covers them.

## Explicitly not

- Changing the keep-forever default. STOR1 made it the owner's per-workflow choice, and audio loss by default is worse than disk growth.
- Windowed ASR or a chunked diarizer. That moves DIAR2's tuned output (FluidAudioRunner's doc comment) and is not justified until item 3 measures a problem; LOCAL18 owns the separate free-RAM watchdog for the local summarizer.
- Moving transcription out of the daemon into a child process. A real option if item 3 shows overlap stalls, recorded so it is not lost; it is an architecture change with its own task.
- The 4 GiB intermediate ceiling and the stop notification's wording: REC19.

## Acceptance

- Pure, unit-tested helpers (MeetingPipeTests): the hours-covered computation for given free bytes and capture rates; the three-band decision (fine, warn, stop) for a sequence of free-space readings, including that the warning fires once; the retention fallback, where a candidate with no `workflowID` takes the default workflow's policy and is untouched when the default is `.keep`; the growth projection over a fixture of meeting sizes and dates.
- A recorder test with an injected free-space reader that the stop band triggers the normal stop path (merge runs, `recording_stopped_low_space` emitted), not `onWriteFailure`.
- pytest for the doctor warning (projection under 30 days warns, over does not).
- `cd daemon && swift build` and `swift test`, `cd pipeline && uv run --extra dev pytest -q` green; `python3 scripts/truth_fences.py events` green for the new actions; new test counts in the commit body.
- This file gains a dated "Measured" section with item 3's footprint numbers before the task is closed.
