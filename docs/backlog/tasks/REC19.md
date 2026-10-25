# REC19: every recording force-stops at about 3 h 6 min because the system-audio intermediate is a 32-bit WAV, and the stop notification tells the user the disk may be full

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) PD-11). Promotes the "REC3 deferred >3h cap-raising" item from the watch list in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md), which said "Promote if >3 h meetings become a real need"; the go-live review makes the wrong stop message the trigger, since that half is a correctness defect at any meeting length. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Verified in code on 2026-10-24.

**Where the ceiling comes from.** `MeetingRecorder` writes two intermediates per recording, `<stem>.mic.wav` and `<stem>.system.wav`, and merges them at stop (`RecordingPostProcessor`). The system file is opened with `SystemAudioCapture.captureFormat`, which is `AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)`: 384,000 bytes a second. A RIFF WAV stores its sizes in unsigned 32-bit fields, so the file is full at 2^32 bytes, which that rate reaches after 11,184 s, 3 h 6 min. The mic file is mono Float32 at the device rate (`MeetingRecorder.monoCaptureFormat`), so at 48 kHz it would reach the same limit at about 6 h 13 min; the system channel is always first. The merged final is 16 kHz `pcm_s16le` stereo (the `mergeToTempViaFFmpeg` arguments), 64,000 bytes a second, which is good for about 18 h and is not the constraint.

**What happens at the ceiling.** REC3 made it a force-stop instead of silent truncation: `WriteFailureTracker` counts consecutive failed writes per channel and escalates at `defaultThreshold = 32` (about 2.7 s), `MeetingRecorder.noteWriteOutcome` emits `recording_error` and logs "disk full or the 4 GiB WAV cap", and the `recorder.onWriteFailure` handler in `Coordinator` force-stops and notifies: "Recording stopped: couldn't keep writing \(channel) audio to disk (the disk may be full). The recording up to that point was kept." On a 3 h 7 min meeting with the disk nowhere near full, the user is told the disk may be full, and nothing earlier warned that the recording would end.

**Unreproduced so far.** The REC3 watch-list note calls the cap-raising "an unreproduced enhancement", and nothing in the tests or logs shows what `AVAudioFile.write(from:)` actually does at 2^32 bytes (throws on every write after, or writes a file whose header wraps). The force-stop path assumes the former. The pickup reproduces it before designing around it.

## Scope

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
