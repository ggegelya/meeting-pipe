---
id: REC19
title: A capture intermediate past 4 GiB is closed as BW64, which the merge's duration reader cannot read, so meetings over 3 h 6 min merge with no length cut; and the write-failure stop notification blames the disk whatever the cause
category: Recording
status: done
priority: P2
closed: 2026-11-12
comment: Shipped 2026-11-12. Item 1 reproduced on macOS 27.2: no write fails at 4 GiB, AVAudioFile closes the WAV as BW64 (14,401 s, 5,529,988,096 bytes), and audioDurationSec read it as nil, so every merge past 3 h 6 min ran with no length cut and ended at the mic. Owner kept WAV and reversed CAF and P1 (Owner decisions section). audioDurationSec now reads RIFF, BW64 and RF64 with ds64's 64-bit size; recording_error gained cause (disk_full under 1 GiB free, read as the smaller of the important-usage and plain available capacities, else unknown, unreadable = unknown) and free_bytes, and the stop notification names the disk only when it is full, else points at Run doctor. 14 new tests (AudioDurationBW64REC19Tests incl. a sparse 5.5 GB fixture, RecordingWriteFailureTests). `bash scripts/ci-local.sh all` green after rebasing onto cc4cc290: fences, ruff, pyright, pytest 1470, swift test 2821 (the one listed skip) and Core 415, the T7 skip check, the CI8 one-thread engine-bounds run and the DIST4 relocation smoke. [Spec](./REC19.md)
---

# REC19: a capture intermediate past 4 GiB is closed as BW64, which the merge's duration reader cannot read, so meetings over 3 h 6 min merge with no length cut; and the write-failure stop notification blames the disk whatever the cause

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) PD-11). Promotes the "REC3 deferred >3h cap-raising" item from the watch list in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md), which said "Promote if >3 h meetings become a real need"; the go-live review makes the wrong stop message the trigger, since that half is a correctness defect at any meeting length. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Corrected 2026-11-12 after item 1's reproduction (below). The filing's premise, that every recording force-stops at about 3 h 6 min, is false on the owner's macOS (27.2): no write fails at the 4 GiB RIFF ceiling. The real defect is quieter, and the second half of the filing (the stop notification blaming the disk) stands.

**What actually happens at 4 GiB.** `MeetingRecorder` writes two intermediates per recording, `<stem>.mic.wav` and `<stem>.system.wav`, and merges them at stop (`RecordingPostProcessor`). The system file is 48 kHz stereo Float32 (`SystemAudioCapture.captureFormat`, 384,000 B/s), which passes 2^32 bytes at 11,184 s (3 h 6 min); the mic is mono Float32 at the device rate, which passes it at 6 h 13 min at 48 kHz, 3 h 6 min at 96 kHz, 1 h 33 min at 192 kHz. `AVAudioFile` keeps writing past it: the 28-byte `JUNK` chunk it writes after `WAVE` is a reservation, and when the handle closes it rewrites the file as **BW64** (magic `BW64`, the `JUNK` turned into a `ds64` chunk carrying 64-bit sizes, `0xFFFFFFFF` in the 32-bit fields). `AVAudioFile` and ffmpeg read that file at its full length.

**Where it broke.** `RecordingPostProcessor.audioDurationSec(of:)` guarded on `RIFF` at offset 0 and returned nil for a BW64 file. `mergeLengths` then saw the long leg as unmeasured and took its mic-only branch: no `-t` cut, the merge ends where the mic file ends, and the expected length the promote gate checks against is the mic's, so the result promotes and the intermediates are deleted. Any far-side audio past the end of the mic file (in practice a late-starting system channel's offset) was lost, and REC9's and REC14's length protection was silently off for exactly the longest meetings. A writer killed past 4 GiB is unaffected: it never reaches the rewrite and leaves `RIFF` with a `0` data size, which REC14's on-disk measurement already reads.

**The notification.** REC3's force-stop (`WriteFailureTracker`, 32 consecutive failed writes on one channel) notified "the disk may be full" on every run of failed writes, and logged "disk full or the 4 GiB WAV cap". The cap never fires, so whenever the disk is not full that text points the owner at the wrong thing.

## Scope

As filed (2026-10-24). Superseded by the owner decisions below: item 2 (CAF) was not taken, item 3 ships without `size_cap`, item 4 is not needed.

1. **Reproduce once.** A scratch test helper (not part of the suite) that writes silent `captureFormat` buffers to a temp WAV until the first write fails, recording the byte offset, the error, and whether the resulting file opens. Write the result in this file.
2. **Raise the ceiling: write the intermediates as CAF.** `AVAudioFile(forWriting:settings:)` writes Core Audio Format when the URL ends in `.caf`, and CAF sizes are 64-bit, so the cap moves past any meeting. Rename the intermediates to `<stem>.mic.caf` and `<stem>.system.caf` where `MeetingRecorder` builds `micURL` and `systemURL` (and where `RecordingPostProcessor` rebuilds them per stem), and teach every reader of the intermediate names to accept both suffixes, so an orphan left by an older build still recovers: `OrphanScan`, `OrphanRecordingRecovery`, `StrandedJobRecovery`, `StopStallWatchdog`, `SystemCaptureRetryPlanner`, `MeetingStore`, `LibraryMover`, `RecordingPostProcessor` (ffmpeg reads CAF natively; `audioDurationSec(of:)` parses RIFF only and needs a CAF path or an `AVAudioFile`-based duration). `grep -rn "mic.wav\|system.wav" daemon/Sources` is the checklist; CONVENTIONS and ARCHITECTURE name the files and change in the same commit.
3. **Say why it stopped.** In the `onWriteFailure` handler, decide the cause from facts the recorder has: the channel's bytes written against 2^32 (only reachable for a WAV after item 2), and `volumeAvailableCapacityForImportantUsage` of the output directory (the key `StorageStats` already reads). A full disk says the disk is full and names the free space; anything else says the recorder could not keep writing and points at `mp doctor`, never at the disk. Add `cause` (`disk_full`, `size_cap`, `unknown`) to `recording_error`.
4. **If item 2 is not taken** (the owner may prefer to keep WAV intermediates), item 3 still ships, plus a HUD notice ten minutes before the computed ceiling ("This recording will stop at 3 h 6 min") so the stop is announced, not discovered.

## Explicitly not

- Segment-rolling (closing the intermediate and opening `<stem>.system.2.wav`). It multiplies REC1's orphan and merge contract; CAF fixes the same class with one rename.
- Changing the system capture format to Int16 or mono to halve the rate. It only moves the ceiling to 6 h, and DIAR6 owns the mixdown question.
- Disk-space preflight before a recording starts and a live low-space warning: REC20.
- RAM for transcribing a recording this long: REC20 (the "Transcription RAM peak" watch-list item).

## Acceptance

- `MeetingRecorderTests` or a new `IntermediateNamingTests`: the recorder opens `.caf` intermediates; every orphan and recovery reader finds a stem from `.caf` intermediates and from legacy `.wav` ones (one test per reader, scratch directory); `RecordingPostProcessor` merges a `.caf` pair into a `.wav` final whose duration matches within `durationToleranceSec`; the duration helper returns the right length for a CAF.
- A test of item 3's cause decision as a pure function: free space under the threshold gives `disk_full` and a message naming the disk; ample space gives a message that does not mention the disk.
- `cd daemon && swift build` and `swift test` green; `bash scripts/ci-local.sh` green; `python3 scripts/truth_fences.py events` green for the new `cause` attribute; new test count in the commit body.
- Evidence (confirms, does not gate): a dogfood recording run past 3 h 10 min (a looped audio source is enough) keeps recording, merges, and transcribes.

## Amended 2026-10-25 (performance review)

From the 2026-10-25 performance review (eight subsystem finders over HEAD 01e904a, every finding adversarially re-verified): PERSISTENCE-1 (finder critical, verified high) and RECORDING-4 (medium), both confirmed. Re-checked in code at `01e904a`. The ceiling arithmetic above stands (`SystemAudioCapture.captureFormat`, 384,000 B/s, 2^32 bytes at 11,184 s). Four additions the pickup needs.

**The mic is not always second.** The mic intermediate is `MeetingRecorder.monoCaptureFormat(from:)` of the device format, mono Float32 at the device's own rate, so its byte rate is four bytes times the sample rate: 192,000 B/s at 48 kHz (6 h 13 min), 384,000 B/s at 96 kHz (a tie with the system channel at 3 h 6 min), 768,000 B/s at 192 kHz (1 h 33 min, before the system channel). The Context's "the system channel is always first" holds only at or below 48 kHz. The owner's personal Mac resolved a 48 kHz input on every recorded start (`input_device_resolved` with `sample_rate: 48000`, three starts), so this needs a high-rate USB interface; but item 3's `size_cap` decision must use the failing channel's own byte rate from its file format, not the system rate, and item 4's HUD notice must name the earlier of the two ceilings.

**Which branch Core Audio takes decides what item 1 must record.** The verifier expects the force-stop branch: Core Audio's WAVE writer refuses data past 32 bits (`kAudioFileDoesNotAllow64BitDataSizeError`, `'off8'`), so every write throws and REC3 escalates. The second finder raised the other possibility, that `AVAudioFile` promotes the file to RF64 (it noted the writer reserves a JUNK chunk, the usual sign of an RF64-capable writer). If so, `RecordingPostProcessor.audioDurationSec(of:)` returns nil (`guard head.range(of: Data("RIFF".utf8))?.lowerBound == 0`), `mergeLengths` falls to its single-measurement branch with no `-t` cut, and REC9's and REC14's length protection is silently off for exactly the longest meetings. Item 1 records the error code and the file's first four bytes (`RIFF` or `RF64`) along with the failing offset.

**A CAF duration reader must not repeat REC14's zero.** Item 2 says `audioDurationSec` needs a CAF path or an `AVAudioFile`-based duration. REC14's 2026-08-14 loss was an unfinalized WAV header read as 0 s and believed; the same question applies to a CAF whose writer died. CAF permits a data chunk size of -1, meaning to end of file, which is the property that makes it tolerant of an unclean exit, but what `AVAudioFile` actually leaves in a killed writer's CAF has to be confirmed, not assumed.

**The rejected Int16-or-mono route was costed at half; together they are a quarter.** "Explicitly not" rejects changing the system format because it "only moves the ceiling to 6 h". Int16 file settings (`AVAudioFile` converts from the Float32 processing format on write) and a mono system channel together give 96,000 B/s and a ceiling of 12 h 25 min with no suffix change, and the merge already folds the system channel to mono (`mergeToTempViaFFmpeg`'s `aresample=16000,pan=mono|c0=0.5*c0+0.5*c1`), so the stereo the intermediate carries is discarded at stop either way; DIAR6's mixdown is the final's (L+R)/2 and is unaffected. Its costs: Int16 clips any sample above 0 dBFS, and a mono fold at capture removes any chance to re-merge the far side in stereo from a kept intermediate. CAF stays the recommended fix; this is the item 4 alternative if the owner keeps WAV intermediates, and either halving also cuts REC20's 2.07 GB per hour of intermediate churn.

**Re-band proposal for the owner.** The first finder argued P1 and the verifier rated it high: at the review's stated load (occasional meetings over 3 h), the tail of every such meeting is lost, every time, with a notice that blames the disk. That matches the backlog's P1 definition (a lost recording) more than REC14's P2 precedent (loss only after another failure). This amendment does not change the band.

Added acceptance:

- An item 3 test that the cause decision computes `size_cap` from the failing channel's own byte rate: a 96 kHz mic intermediate at 2^32 bytes gives `size_cap` for the mic.
- A CAF intermediate written and then abandoned without closing (the writer killed in a child process the test spawns) reports its payload length through the new duration reader, not 0 and not nil.
- Item 1's dated note in this file records the error, the first four bytes, and whether `audioDurationSec` returned nil for the file it left.

## Item 1 reproduction (2026-11-12)

Run on the owner's Mac, macOS 27.2 (build 26B123), with scratch helpers outside the suite (a writer loop and a child process killed with SIGKILL).

- **Writing past 2^32 bytes.** Silent 48000-frame buffers of `SystemAudioCapture.captureFormat` (48 kHz stereo Float32) written to a `.wav` through `AVAudioFile(forWriting:settings:commonFormat:interleaved:)` until a write failed or 4 h passed. **No write failed**: 691,248,000 frames (14,401 s) and 5,529,988,096 bytes, no error code at all (no `'off8'`). After close the first four bytes are `BW64` (bytes 8 to 12 `WAVE`), followed by a `ds64` chunk of 28 bytes (RIFF size 0x1499CEBF8, data size 5,529,984,000, frames 691,248,000), `fmt `, an `FLLR` pad and `data` with size `0xFFFFFFFF`; the payload starts at byte 4096. The file reopens with `AVAudioFile(forReading:)` at 691,248,000 frames, 14,401.0 s. `ffprobe` reports `wav`, 14,401 s, and `ffmpeg -ss 14000 -t 1` converts from past the 4 GiB mark with exit 0.
- **`audioDurationSec` on that file returned nil** (its guard required `RIFF` at offset 0), which is the defect in the corrected Context.
- **A writer killed past 4 GiB.** A child writing 12,000 s to a `.wav`, killed with SIGKILL: 4,608,004,096 bytes, header `RIFF` `f80f0000` `WAVE` `JUNK` (size 0x1C), i.e. never promoted, with the size placeholders unpatched. The REC14 reader measures it from the file's real size.
- **A writer killed mid-CAF** (the then-planned item 2): a child writing 10 s to a `.caf`, killed: 3,837,952 bytes, `caff` with a `desc` chunk and a `data` chunk whose size is `-1` (`0xFFFFFFFFFFFFFFFF`). `AVAudioFile` reads 479,232 frames (9.984 s) and `ffprobe` reads 9.984 s, not 0 and not nil. Recorded for completeness; CAF was not taken.

## Owner decisions (2026-11-12)

Taken twice on the same day. Before item 1 ran, on the filing's force-stop premise: **"Switch to CAF"** (item 2: write `<stem>.mic.caf` / `<stem>.system.caf`, every reader accepting both suffixes; item 3's `cause` ships too; item 4 not needed) and **"Make it P1"**.

Item 1 then showed the force-stop does not happen on this macOS, so both were put back to the owner with the reproduction, and reversed:

- **"Keep WAV, fix reader (Recommended)"**, superseding "Switch to CAF". The defect is the reader, not the container: teach `audioDurationSec` BW64's 64-bit `ds64` data size and check every other header parser for the same `RIFF`-only assumption. No rename crosses the Swift/Python boundary.
- **"Drop it (Recommended)"** for `size_cap`: it cannot fire under BW64. `recording_error.cause` is `disk_full` or `unknown` only; a free space that cannot be read is `unknown`, and the unknown message points at the in-app **Run doctor…**, not the disk.
- **"Back to P2"**, superseding "Make it P1": the loss is a late-starting far side's tail on meetings over 3 h 6 min, not the tail of every such meeting.
- **"Use the smaller (Recommended)"** for the free-space reading: the spec's key, `volumeAvailableCapacityForImportantUsage`, counts purgeable space, so a genuinely full disk on a Mac holding a lot of purgeable data could read above the threshold and be reported as `unknown`. The decision reads min(that, `volumeAvailableCapacity`); either alone when the other cannot be read; neither readable is `unknown`.

## Shipped (2026-11-12)

- `RecordingPostProcessor.audioDurationSec` accepts `RIFF`, `BW64` and `RF64`, reads `ds64`'s 64-bit data size, and uses it when the `data` chunk's 32-bit size is `0xFFFFFFFF`; REC14's on-disk cap and killed-writer measurement are unchanged. The only other parser of a capture header in either tree is `AVAudioFile` (`AudioTranscoder.duration`, playback, waveform), which already reads BW64; the pipeline never opens an intermediate, and the finals it reads are 16 kHz `pcm_s16le` (64,000 B/s, about 18 h to 4 GiB).
- `RecordingWriteFailure` (new, pure): `decide(channel:freeBytes:volumeName:)` gives `disk_full` under `diskFullThresholdBytes` (1 GiB) of free space, read as the smaller of `volumeAvailableCapacityForImportantUsage` and `volumeAvailableCapacity` (`effectiveFreeBytes`), with a message naming the volume and its free space, else `unknown` with a message that never mentions the disk and points at Preferences > Integrations > Run doctor. `MeetingRecorder.noteWriteOutcome` reads the free space off main on the failing writer's queue, adds `cause` and `free_bytes` to `recorder` / `recording_error`, and hands the decision to `Coordinator`'s `onWriteFailure`, which notifies with its message.
- Tests: `AudioDurationBW64REC19Tests` (a header built the way Apple's writer lays it out, including a sparse 5.5 GB fixture with the measured numbers, and the length policy now cutting at the BW64 leg) and `RecordingWriteFailureTests`.
- Not done, and not gating: the dogfood recording past 3 h 10 min from the Acceptance's Evidence line.
