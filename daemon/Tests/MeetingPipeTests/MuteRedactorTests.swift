import AVFoundation
import XCTest
@testable import MeetingPipe

final class MuteRedactorTests: XCTestCase {

    // MARK: - protectOriginalAtRest (AUD-19 / MIC13)

    func test_protectOriginalAtRest_sets_owner_only_and_excludes_from_backup() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-originals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rec.wav")
        try Data("x".utf8).write(to: file)
        // World-readable to start, so the 0600 tightening is observable.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        MuteRedactor.protectOriginalAtRest(file)

        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600, "kept originals must be owner-only")
        let excluded = try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true, "kept originals must be excluded from Time Machine / iCloud (AUD-19)")
    }

    // MARK: - buildFilter (pure)

    func test_buildFilter_nil_when_no_spans() {
        XCTAssertNil(MuteRedactor.buildFilter(spans: [], channels: 2))
    }

    func test_buildFilter_stereo_zeroes_only_the_left_channel() {
        let filter = MuteRedactor.buildFilter(
            spans: [MuteTimeline.Span(startSec: 1.0, endSec: 2.0)], channels: 2
        )
        let f = try? XCTUnwrap(filter)
        XCTAssertTrue(f?.contains("channelsplit") == true, "stereo must split so system audio is untouched")
        XCTAssertTrue(f?.contains("[L]volume=0:enable=") == true, "only the left (mic) channel is zeroed")
        XCTAssertTrue(f?.contains("amerge=inputs=2") == true, "channels are re-merged back to stereo")
    }

    func test_buildFilter_mono_zeroes_the_single_channel() {
        let filter = MuteRedactor.buildFilter(
            spans: [MuteTimeline.Span(startSec: 1.0, endSec: 2.0)], channels: 1
        )
        let f = try? XCTUnwrap(filter)
        XCTAssertEqual(f?.contains("channelsplit"), false, "mono has nothing to split")
        XCTAssertTrue(f?.contains("[0:a]volume=0:enable=") == true)
    }

    func test_buildFilter_encodes_each_span_as_a_between_term() {
        let filter = MuteRedactor.buildFilter(
            spans: [
                MuteTimeline.Span(startSec: 1.25, endSec: 2.5),
                MuteTimeline.Span(startSec: 10.0, endSec: 12.0),
            ],
            channels: 2
        )
        let f = try? XCTUnwrap(filter)
        XCTAssertTrue(f?.contains("between(t,1.250,2.500)") == true)
        XCTAssertTrue(f?.contains("between(t,10.000,12.000)") == true)
        XCTAssertTrue(f?.contains("between(t,1.250,2.500)+between(t,10.000,12.000)") == true,
                      "spans OR together so any one silences the mic")
    }

    // MARK: - SEC26: held folder, unreadable final, checked restore and protection

    func test_quarantine_lands_in_held_at_0600_and_excluded_from_backup() throws {
        let (dir, wav) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: dir) }
        let originals = dir.appendingPathComponent("originals")

        let dest = try MuteRedactor.quarantine(wav, in: originals)

        XCTAssertEqual(dest, MuteRedactor.heldDirectory(in: originals).appendingPathComponent("rec.wav"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
        let perms = try FileManager.default.attributesOfItem(atPath: dest.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
        XCTAssertEqual(try dest.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(MuteRedactor.heldRecording(stem: "rec", in: originals), dest)
    }

    func test_a_second_hold_of_the_same_name_never_replaces_the_first() throws {
        let (dir, wav) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: dir) }
        let originals = dir.appendingPathComponent("originals")
        let first = try MuteRedactor.quarantine(wav, in: originals)
        let firstBytes = try Data(contentsOf: first)
        try writeStereoWav(at: wav, seconds: 0.5, left: 0.1, right: 0.1)  // a different recording, same name

        let second = try MuteRedactor.quarantine(wav, in: originals)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), firstBytes, "the first held recording is untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func test_an_unopenable_final_fails_as_audio_unreadable_and_keeps_the_timeline() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("redact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("rec.wav")
        try Data("not a wav".utf8).write(to: wav)
        MuteTimelineFile.write(spans: [MuteTimeline.Span(startSec: 0, endSec: 1, source: .mute)], forFinal: wav)

        let outcome = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: dir.appendingPathComponent("originals"), findFFmpeg: { "/nonexistent" })

        XCTAssertEqual(outcome, .failed(.audioUnreadable))
        XCTAssertNotNil(MuteTimelineFile.read(forFinal: wav), "the timeline stays for a later pass")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path), "the file is not moved or touched")
    }

    func test_a_span_past_the_end_is_unmeasured_not_speech() throws {
        let (dir, wav) = try makeRecording()  // 1.0 s
        defer { try? FileManager.default.removeItem(at: dir) }
        let pastEnd = MuteTimeline.Span(startSec: 5.0, endSec: 6.0)
        let result = MuteRedactor.partitionSpans(wav: wav, spans: [pastEnd])
        XCTAssertEqual(result.unmeasured.map(\.startSec), [5.0])
        XCTAssertTrue(result.withheld.isEmpty)
        XCTAssertTrue(result.redact.isEmpty)
    }

    func test_a_promote_failure_whose_restore_also_fails_reports_restored_false() async throws {
        try requireFFmpeg()
        let (dir, wav) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: dir) }
        let originals = dir.appendingPathComponent("originals")
        let logs = dir.appendingPathComponent("logs")
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }
        MuteTimelineFile.write(spans: [MuteTimeline.Span(startSec: 0, endSec: 0.5, source: .manual)], forFinal: wav)

        struct Boom: Error {}
        let outcome = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: originals, move: { _, _ in throw Boom() })

        XCTAssertEqual(outcome, .failed(.promoteFailed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path), "the restore failed, so raw/ has nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: originals.appendingPathComponent("rec.wav").path),
                       "the only copy must not stay in the reaped top level")
        XCTAssertTrue(FileManager.default.fileExists(atPath: MuteRedactor.heldDirectory(in: originals).appendingPathComponent("rec.wav").path),
                      "the redactor holds it itself, so a job past its deadline cannot strand it")
        let events = try String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)
        let line = try XCTUnwrap(events.split(separator: "\n").last { $0.contains("mute_redaction_failed") })
        XCTAssertTrue(line.contains("\"restored\":false"), String(line))
    }

    func test_a_hold_of_a_byte_identical_file_keeps_the_held_one_and_drops_the_source() throws {
        let (dir, wav) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: dir) }
        let originals = dir.appendingPathComponent("originals")
        let copy = dir.appendingPathComponent("copy.wav")
        try FileManager.default.copyItem(at: wav, to: copy)
        let first = try MuteRedactor.quarantine(wav, in: originals)
        // The same bytes under the same name again (a retry of the hold).
        let again = dir.appendingPathComponent("rec.wav")
        try FileManager.default.copyItem(at: copy, to: again)

        let second = try MuteRedactor.quarantine(again, in: originals)

        XCTAssertEqual(first, second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: again.path))
        XCTAssertEqual(MuteRedactor.heldRecordings(stem: "rec", in: originals), [first])
    }

    func test_every_held_file_of_a_stem_is_found_in_numeric_order() throws {
        let originals = FileManager.default.temporaryDirectory.appendingPathComponent("held-\(UUID().uuidString)")
        let held = MuteRedactor.heldDirectory(in: originals)
        try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: originals) }
        for name in ["s.wav", "s.held-2.wav", "s.held-10.wav", "s.held-1.wav", "other.wav", "s.held-x.wav", "s.heldish.wav"] {
            try Data([1]).write(to: held.appendingPathComponent(name))
        }
        XCTAssertEqual(MuteRedactor.heldRecordings(stem: "s", in: originals).map(\.lastPathComponent),
                       ["s.wav", "s.held-1.wav", "s.held-2.wav", "s.held-10.wav"])
    }

    /// A pass that finished after its job's deadline already cut the audio and put the full recording
    /// aside. The retry must read the WAV as the redacted artifact, not hold it back.
    func test_a_lost_timeline_with_the_full_recording_already_aside_reads_as_redacted() async throws {
        let (dir, wav) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: dir) }
        let originals = dir.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try writeStereoWav(at: originals.appendingPathComponent("rec.wav"), seconds: 2.0, left: 0.9, right: 0.9)  // the full one
        try OffRecordMarker.write(forFinal: wav)

        let outcome = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: originals)

        XCTAssertEqual(outcome, .redacted)
    }

    // MARK: - PIPE45: a redaction that landed late must survive its own retry

    /// The whole disk state a late redaction leaves (the full recording aside, redacted bytes at the
    /// canonical path, the timeline reaped, `.offrecord` still there). The retry must change nothing
    /// and must not report a failure.
    func test_a_late_redactions_disk_state_is_redacted_and_leaves_both_files_untouched_PIPE45() async throws {
        let (dir, wav) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logs = dir.appendingPathComponent("logs")
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }
        let originals = dir.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let kept = originals.appendingPathComponent("rec.wav")
        try writeStereoWav(at: kept, seconds: 2.0, left: 0.9, right: 0.9)  // the full recording
        let keptBytes = try Data(contentsOf: kept)
        let redactedBytes = try Data(contentsOf: wav)
        XCTAssertNotEqual(keptBytes, redactedBytes)
        try OffRecordMarker.write(forFinal: wav)
        XCTAssertNil(MuteTimelineFile.read(forFinal: wav), "the pass reaped its timeline")

        let outcome = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: originals)

        XCTAssertEqual(outcome, .redacted)
        XCTAssertEqual(try Data(contentsOf: kept), keptBytes, "the full recording is not replaced")
        XCTAssertEqual(try Data(contentsOf: wav), redactedBytes, "the redacted WAV is not touched")
        let events = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        XCTAssertFalse(events.contains("mute_redaction_failed"), events)
    }

    /// The other two ways the cut was owed (SEC16 / REC21) read the same after a late redaction.
    func test_a_late_redaction_is_redacted_for_every_owed_marker_PIPE45() async throws {
        for owed in ["capturemode", "redactionOwed"] {
            let (dir, wav) = try makeRecording()
            defer { try? FileManager.default.removeItem(at: dir) }
            let originals = dir.appendingPathComponent("originals")
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
            try writeStereoWav(at: originals.appendingPathComponent("rec.wav"), seconds: 2.0, left: 0.9, right: 0.9)
            if owed == "capturemode" {
                try CaptureMode.captureFirstRedact.marker
                    .write(to: wav.deletingPathExtension().appendingPathExtension("capturemode"), atomically: true, encoding: .utf8)
            }

            let outcome = await MuteRedactor.redactIfNeeded(
                wav: wav, redactionOwed: owed == "redactionOwed", originalsDir: originals)

            XCTAssertEqual(outcome, .redacted, owed)
        }
    }

    /// SEC16's carve-out, pinned beside PIPE45's: an aside copy that is byte-identical to the WAV
    /// means the full recording was copied back by hand, so it is NOT the redacted artifact.
    func test_a_byte_identical_aside_copy_still_fails_timeline_missing_PIPE45() async throws {
        let (dir, wav) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: dir) }
        let originals = dir.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: wav, to: originals.appendingPathComponent("rec.wav"))
        try OffRecordMarker.write(forFinal: wav)

        let outcome = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: originals)

        XCTAssertEqual(outcome, .failed(.timelineMissing))
    }

    /// A quit between `.redacted` and the marker removal, through the real redactor and ffmpeg: the
    /// second pass sees the reaped timeline and a surviving `.offrecord`, and must not hold back.
    func test_a_quit_between_redacted_and_marker_removal_does_not_hold_the_retry_back_PIPE45() async throws {
        try requireFFmpeg()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("redact-\(UUID().uuidString)")
        let originals = dir.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("rec.wav")
        try writeStereoWavTwoRegions(at: wav, seconds: 1.0, splitSec: 0.5, micFirst: 0.002, micSecond: 0.5, system: 0.5)
        let fullBytes = try Data(contentsOf: wav)
        try OffRecordMarker.write(forFinal: wav)
        MuteTimelineFile.write(spans: [MuteTimeline.Span(startSec: 0.0, endSec: 0.5, source: .manual)], forFinal: wav)

        let first = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: originals)
        XCTAssertEqual(first, .redacted)
        XCTAssertTrue(OffRecordMarker.exists(forFinal: wav), "the quit: the job never reached the marker removal")
        let redactedBytes = try Data(contentsOf: wav)

        let retry = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: originals)

        XCTAssertEqual(retry, .redacted)
        XCTAssertEqual(try Data(contentsOf: originals.appendingPathComponent("rec.wav")), fullBytes)
        XCTAssertEqual(try Data(contentsOf: wav), redactedBytes)
    }

    /// The overwrite itself: whatever reaches `quarantine`, the kept original beside it is never the
    /// file that gets replaced (it used to delete `dest`, which was that path).
    func test_quarantine_never_replaces_the_kept_original_PIPE45() throws {
        let (dir, wav) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: dir) }
        let originals = dir.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let kept = originals.appendingPathComponent("rec.wav")
        try writeStereoWav(at: kept, seconds: 2.0, left: 0.9, right: 0.9)
        let keptBytes = try Data(contentsOf: kept)
        let redactedBytes = try Data(contentsOf: wav)

        let dest = try MuteRedactor.quarantine(wav, in: originals)

        XCTAssertEqual(try Data(contentsOf: kept), keptBytes, "the full recording is untouched")
        XCTAssertEqual(try Data(contentsOf: dest), redactedBytes)
        XCTAssertNotEqual(dest, kept)
    }

    func test_every_held_back_reason_reads_as_an_explanation_not_a_retry() {
        for reason in MuteRedactor.FailureReason.allCases {
            let text = SinkDispatcher.heldBackReason(reason)
            XCTAssertLessThanOrEqual(text.count, 260, "isValidation reads at most 260 characters: \(reason)")
            XCTAssertEqual(FailurePresentation(diagnostics: text).explanation, text, "\(reason) must read as a validation explanation")
            XCTAssertTrue(SinkDispatcher.isHeldBackReason(text))
            XCTAssertFalse(SinkDispatcher.isHeldBackReason(SinkDispatcher.heldBackReason(reason, kept: false)),
                           "a hold that moved nothing must not offer Show recording")
        }
    }

    func test_protectOriginalAtRest_reports_a_protection_that_did_not_apply() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("no-such-\(UUID().uuidString).wav")
        let failures = MuteRedactor.protectOriginalAtRest(missing)
        XCTAssertEqual(Set(failures.map(\.protection)), ["permissions", "backup_exclusion"])
        XCTAssertTrue(failures.allSatisfy { !$0.errorDomain.isEmpty })
    }

    // MARK: - originals path

    func test_originalsURL_is_app_private_and_outside_the_recordings_tree() {
        let wav = URL(fileURLWithPath: "/Users/x/Documents/Meetings/raw/20260607-120000.wav")
        let original = MuteRedactor.originalsURL(for: wav)
        XCTAssertEqual(original.lastPathComponent, "20260607-120000.wav")
        XCTAssertTrue(original.path.contains("Application Support/MeetingPipe/originals"))
        XCTAssertFalse(original.path.contains("/Meetings/raw/"), "must not sit in the Library-scanned tree")
    }

    // MARK: - redactIfNeeded

    func test_redactIfNeeded_is_a_noop_without_a_timeline() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("rec.wav")
        try writeStereoWav(at: wav, seconds: 0.2, left: 0.5, right: 0.5)
        let before = try Data(contentsOf: wav)

        // No <stem>.mute-timeline.json present -> regulated/orphan/pre-MIC4 path.
        let redacted = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: dir)

        XCTAssertEqual(redacted, .notNeeded)
        XCTAssertEqual(try Data(contentsOf: wav), before, "the WAV must be untouched without a timeline")
    }

    func test_redactIfNeeded_zeroes_the_muted_span_and_keeps_the_original() async throws {
        try requireFFmpeg()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redact-\(UUID().uuidString)")
        let originals = dir.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("rec.wav")
        // Mute the first half of the mic channel. It must be genuinely quiet for
        // MIC12's per-span guard to redact it; the audible second half stands in
        // for un-muted speech that must survive.
        try writeStereoWavTwoRegions(at: wav, seconds: 1.0, splitSec: 0.5,
                                     micFirst: 0.002, micSecond: 0.5, system: 0.5)
        MuteTimelineFile.write(spans: [MuteTimeline.Span(startSec: 0.0, endSec: 0.5)], forFinal: wav)

        let redacted = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: originals)
        XCTAssertEqual(redacted, .redacted)

        // The full recording was moved aside for recovery.
        XCTAssertTrue(FileManager.default.fileExists(atPath: originals.appendingPathComponent("rec.wav").path))

        // The redacted artifact: left silenced in [0,0.5), audible after; right untouched.
        let file = try AVAudioFile(forReading: wav)
        let frames = AVAudioFrameCount(file.length)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        try file.read(into: buf)
        let data = try XCTUnwrap(buf.floatChannelData)
        let rate = file.processingFormat.sampleRate

        XCTAssertEqual(peak(data[0], from: 0, to: Int(0.4 * rate)), 0, accuracy: 0.02,
                       "mic must be silent inside the muted span")
        XCTAssertGreaterThan(peak(data[0], from: Int(0.6 * rate), to: Int(0.95 * rate)), 0.1,
                             "mic must be audible after the muted span")
        XCTAssertGreaterThan(peak(data[1], from: 0, to: Int(0.4 * rate)), 0.1,
                             "system (right) channel must be untouched by mic redaction")
    }

    func test_redactIfNeeded_is_idempotent_and_keeps_the_original_across_reruns() async throws {
        try requireFFmpeg()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redact-\(UUID().uuidString)")
        let originals = dir.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("rec.wav")
        // Muted span genuinely quiet so MIC12's per-span guard redacts it.
        try writeStereoWavTwoRegions(at: wav, seconds: 1.0, splitSec: 0.5,
                                     micFirst: 0.002, micSecond: 0.5, system: 0.5)
        let fullBytes = try Data(contentsOf: wav)
        MuteTimelineFile.write(spans: [MuteTimeline.Span(startSec: 0.0, endSec: 0.5)], forFinal: wav)

        // First pass redacts and moves the full recording aside.
        let firstPass = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: originals)
        XCTAssertEqual(firstPass, .redacted)
        let keptOriginal = originals.appendingPathComponent("rec.wav")
        XCTAssertEqual(try Data(contentsOf: keptOriginal), fullBytes, "the kept original is the un-redacted full recording")
        let redactedBytes = try Data(contentsOf: wav)

        // Second pass (reprocess / retry) must be a no-op that does NOT clobber
        // the kept original with the already-redacted file.
        let secondPass = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: originals)
        XCTAssertEqual(secondPass, .notNeeded, "a second pass must no-op")
        XCTAssertEqual(try Data(contentsOf: keptOriginal), fullBytes,
                       "the kept original must survive a re-run unchanged")
        XCTAssertEqual(try Data(contentsOf: wav), redactedBytes, "the canonical WAV stays the redacted one")
    }

    // MARK: - per-span runaway guard (TECH-MIC12)

    func test_partitionSpans_redacts_quiet_spans_and_withholds_speechy_ones() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mic12-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Mic genuinely quiet (~-54 dBFS) in [0,0.5), at speech level (~-10 dBFS)
        // in [0.5,1.0); system audio present throughout.
        let wav = dir.appendingPathComponent("rec.wav")
        try writeStereoWavTwoRegions(at: wav, seconds: 1.0, splitSec: 0.5,
                                     micFirst: 0.002, micSecond: 0.3, system: 0.5)
        let quiet = MuteTimeline.Span(startSec: 0.0, endSec: 0.5)
        let speechy = MuteTimeline.Span(startSec: 0.5, endSec: 1.0)

        let (redact, withheld, unmeasured) = MuteRedactor.partitionSpans(wav: wav, spans: [quiet, speechy])
        XCTAssertTrue(unmeasured.isEmpty)

        XCTAssertEqual(redact.map { $0.startSec }, [0.0],
                       "a genuinely quiet muted span is safe to redact")
        XCTAssertEqual(withheld.map { $0.startSec }, [0.5],
                       "a muted span carrying speech is withheld, never zeroed")
    }

    func test_redactIfNeeded_redacts_quiet_span_and_keeps_speechy_span() async throws {
        try requireFFmpeg()
        // The MIC12 win in one assertion: a mixed timeline redacts the quiet muted
        // span but PRESERVES the muted span that carries speech (the old whole-file
        // 85% guard would have withheld both, leaving the quiet listening
        // un-redacted).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mic12-\(UUID().uuidString)")
        let originals = dir.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("rec.wav")
        try writeStereoWavTwoRegions(at: wav, seconds: 1.0, splitSec: 0.5,
                                     micFirst: 0.002, micSecond: 0.3, system: 0.5)
        MuteTimelineFile.write(
            spans: [MuteTimeline.Span(startSec: 0.0, endSec: 0.5),
                    MuteTimeline.Span(startSec: 0.5, endSec: 1.0)],
            forFinal: wav
        )

        let redacted = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: originals)
        XCTAssertEqual(redacted, .redacted, "a mixed timeline still redacts its quiet span")

        let file = try AVAudioFile(forReading: wav)
        let frames = AVAudioFrameCount(file.length)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        try file.read(into: buf)
        let data = try XCTUnwrap(buf.floatChannelData)
        let rate = file.processingFormat.sampleRate

        XCTAssertLessThan(peak(data[0], from: 0, to: Int(0.4 * rate)), 0.0005,
                          "the quiet muted span was redacted to silence (was ~0.002)")
        XCTAssertGreaterThan(peak(data[0], from: Int(0.6 * rate), to: Int(0.9 * rate)), 0.1,
                             "the speech-carrying muted span was preserved, not zeroed")
        XCTAssertGreaterThan(peak(data[1], from: 0, to: Int(0.9 * rate)), 0.1,
                             "the system (right) channel is untouched")
    }

    func test_redactIfNeeded_withholds_runaway_redaction_over_a_live_mic() async throws {
        // The Teams mini-window incident in one assertion: a whole-recording
        // muted span over a mic that carries speech must be withheld, the full
        // mic kept, and the bogus timeline reaped. The guard returns before
        // ffmpeg, so this runs without it.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redact-\(UUID().uuidString)")
        let originals = dir.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("rec.wav")
        try writeStereoWav(at: wav, seconds: 1.0, left: 0.5, right: 0.5)
        let fullBytes = try Data(contentsOf: wav)
        MuteTimelineFile.write(spans: [MuteTimeline.Span(startSec: 0.0, endSec: 1.0)], forFinal: wav)

        let redacted = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: originals)
        XCTAssertEqual(redacted, .notNeeded, "a whole-file muted span over a live mic must be withheld, not redacted")
        XCTAssertEqual(try Data(contentsOf: wav), fullBytes, "the full mic recording is kept untouched")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: originals.appendingPathComponent("rec.wav").path),
            "nothing is moved aside when redaction is withheld"
        )
        XCTAssertNil(MuteTimelineFile.read(forFinal: wav), "the bogus timeline is reaped so a reprocess won't retry it")
    }

    func test_redactIfNeeded_always_redacts_a_manual_span_over_a_live_mic() async throws {
        try requireFFmpeg()
        // MIC14 invariant 1: a manual off-record span is explicit user intent, so it is redacted
        // even over a mic carrying speech - the exact case the auto withhold above protects. This
        // is the mirror assertion: same live mic, same whole-file span, but tagged `.manual`, so
        // the outcome flips from withheld to redacted.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redact-\(UUID().uuidString)")
        let originals = dir.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("rec.wav")
        try writeStereoWav(at: wav, seconds: 1.0, left: 0.5, right: 0.5)  // a live mic
        MuteTimelineFile.write(
            spans: [MuteTimeline.Span(startSec: 0.0, endSec: 1.0, source: .manual)], forFinal: wav
        )

        let redacted = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: originals)
        XCTAssertEqual(redacted, .redacted, "a manual span is always redacted, exempt from the speech-bearing withhold")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: originals.appendingPathComponent("rec.wav").path),
            "the full original is moved aside for recovery"
        )
        // The mic (left) channel is zeroed over the manual span in the redacted artifact.
        let f = try AVAudioFile(forReading: wav)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let leftPeak = peak(buf.floatChannelData![0], from: 0, to: Int(buf.frameLength))
        XCTAssertLessThan(leftPeak, 0.02, "the manual span's mic audio is zeroed in the consumed artifact")
    }

    // MARK: - fail closed (SEC16)

    func test_redactIfNeeded_fails_when_ffmpeg_is_missing() async throws {
        let (dir, wav) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: dir) }
        MuteTimelineFile.write(
            spans: [MuteTimeline.Span(startSec: 0.0, endSec: 0.5, source: .manual)], forFinal: wav
        )
        let before = try Data(contentsOf: wav)

        let outcome = await MuteRedactor.redactIfNeeded(
            wav: wav, originalsDir: dir.appendingPathComponent("originals"), findFFmpeg: { nil }
        )

        XCTAssertEqual(outcome, .failed(.ffmpegMissing), "a missing ffmpeg is a failure, not a no-op")
        XCTAssertEqual(try Data(contentsOf: wav), before, "the full recording is left intact")
        XCTAssertTrue(FileManager.default.fileExists(atPath: MuteTimelineFile.url(forFinal: wav).path),
                      "the timeline is kept as evidence until a redaction succeeds")
    }

    func test_redactIfNeeded_fails_on_a_corrupt_timeline() async throws {
        let (dir, wav) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{\"version\": 2, \"spans\": [".utf8).write(to: MuteTimelineFile.url(forFinal: wav))

        let outcome = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: dir.appendingPathComponent("originals"))

        XCTAssertEqual(outcome, .failed(.timelineUnreadable), "a corrupt timeline must not read as no timeline")
    }

    func test_redactIfNeeded_fails_when_the_offrecord_marker_outlived_a_lost_timeline() async throws {
        let (dir, wav) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A clean finish whose timeline write failed: the MIC14 marker is still on disk.
        try OffRecordMarker.write(forFinal: wav)

        let outcome = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: dir.appendingPathComponent("originals"))

        XCTAssertEqual(outcome, .failed(.timelineMissing))
        XCTAssertTrue(OffRecordMarker.exists(forFinal: wav), "the redactor never removes the marker itself")
    }

    func test_redactIfNeeded_fails_for_a_redaction_opt_in_recording_with_no_timeline() async throws {
        let (dir, wav) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: dir) }
        // MeetingRecorder.stop keeps this marker when the timeline write fails.
        try CaptureMode.captureFirstRedact.marker
            .write(to: wav.deletingPathExtension().appendingPathExtension("capturemode"), atomically: true, encoding: .utf8)

        let outcome = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: dir.appendingPathComponent("originals"))

        XCTAssertEqual(outcome, .failed(.timelineMissing))
    }

    func test_redactIfNeeded_without_a_timeline_or_marker_is_not_needed() async throws {
        let (dir, wav) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A default capture-first recording keeps no marker past a clean stop.
        try CaptureMode.captureFirst.marker
            .write(to: wav.deletingPathExtension().appendingPathExtension("capturemode"), atomically: true, encoding: .utf8)

        let outcome = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: dir.appendingPathComponent("originals"), findFFmpeg: { nil })

        XCTAssertEqual(outcome, .notNeeded)
    }

    /// The owner's 2026-10-24 decision (SEC16 option B): off the record cuts the mic
    /// only, like an auto mute. The other side is still transcribed.
    func test_a_manual_span_zeroes_only_the_mic_channel_and_keeps_the_frame_count() async throws {
        try requireFFmpeg()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("rec.wav")
        try writeStereoWav(at: wav, seconds: 1.0, left: 0.5, right: 0.5)
        let framesBefore = try AVAudioFile(forReading: wav).length
        MuteTimelineFile.write(
            spans: [MuteTimeline.Span(startSec: 0.0, endSec: 0.5, source: .manual)], forFinal: wav
        )

        let outcome = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: dir.appendingPathComponent("originals"))
        XCTAssertEqual(outcome, .redacted)

        let file = try AVAudioFile(forReading: wav)
        XCTAssertEqual(file.length, framesBefore, "frames are zeroed, never dropped (ADR 0009)")
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        let data = try XCTUnwrap(buf.floatChannelData)
        let rate = file.processingFormat.sampleRate
        XCTAssertEqual(peak(data[0], from: 0, to: Int(0.45 * rate)), 0, accuracy: 0.02, "mic is cut inside the span")
        XCTAssertGreaterThan(peak(data[0], from: Int(0.55 * rate), to: Int(0.95 * rate)), 0.1, "mic is intact after it")
        XCTAssertGreaterThan(peak(data[1], from: 0, to: Int(0.45 * rate)), 0.1, "the other side is not cut")
    }

    func test_a_full_recording_copied_back_over_a_kept_original_is_redacted_again() async throws {
        try requireFFmpeg()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redact-\(UUID().uuidString)")
        let originals = dir.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("rec.wav")
        try writeStereoWav(at: wav, seconds: 1.0, left: 0.5, right: 0.5)
        // A held-back meeting restored by hand: the quarantined copy is still in originals/
        // and byte-identical to the WAV, so it must not read as "already redacted".
        try FileManager.default.copyItem(at: wav, to: originals.appendingPathComponent("rec.wav"))
        MuteTimelineFile.write(
            spans: [MuteTimeline.Span(startSec: 0.0, endSec: 0.5, source: .manual)], forFinal: wav
        )

        let outcome = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: originals)

        XCTAssertEqual(outcome, .redacted)
        XCTAssertFalse(FileManager.default.contentsEqual(
            atPath: wav.path, andPath: originals.appendingPathComponent("rec.wav").path
        ), "the canonical WAV is the redacted artifact, not the restored full recording")
    }

    func test_redactIfNeeded_redacts_a_runaway_span_when_the_mic_is_silent() async throws {
        try requireFFmpeg()
        // A whole-recording mute over a silent mic loses nothing, so the guard
        // must not over-withhold: redaction proceeds as normal.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redact-\(UUID().uuidString)")
        let originals = dir.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("rec.wav")
        try writeStereoWav(at: wav, seconds: 1.0, left: 0.0, right: 0.5)
        MuteTimelineFile.write(spans: [MuteTimeline.Span(startSec: 0.0, endSec: 1.0)], forFinal: wav)

        let redacted = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: originals)
        XCTAssertEqual(redacted, .redacted, "a runaway mute over a silent mic is harmless and redacts normally")
        XCTAssertTrue(FileManager.default.fileExists(atPath: originals.appendingPathComponent("rec.wav").path))
    }

    // MARK: - helpers

    /// Gate for the ffmpeg-backed safety tests, loud by design (CI1 / AUD-8).
    /// CI installs ffmpeg (`.github/workflows/ci.yml`), so a missing binary
    /// there means the most destructive code path (mute redaction over a real
    /// WAV) went unverified: a failure to surface, not a skip to swallow. Only a
    /// genuinely local machine without ffmpeg still skips.
    private func requireFFmpeg() throws {
        if RecordingPostProcessor.findFFmpeg() != nil { return }
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            throw FFmpegUnavailableOnCI()
        }
        throw XCTSkip("ffmpeg not available (local run)")
    }

    private struct FFmpegUnavailableOnCI: Error, CustomStringConvertible {
        var description: String {
            "ffmpeg missing on CI: the MuteRedactor data-safety tests could not run. "
                + "ci.yml is supposed to install it; the mute-redaction path is now unverified."
        }
    }

    /// A fresh temp directory holding a short stereo `rec.wav` with a live mic.
    private func makeRecording() throws -> (dir: URL, wav: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("rec.wav")
        try writeStereoWav(at: wav, seconds: 1.0, left: 0.5, right: 0.5)
        return (dir, wav)
    }

    private func writeStereoWav(at url: URL, seconds: Double, left: Float, right: Float) throws {
        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 2, interleaved: false
        )!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(seconds * 16000)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) {
            buf.floatChannelData![0][i] = left
            buf.floatChannelData![1][i] = right
        }
        try file.write(from: buf)
    }

    /// Stereo WAV whose mic (left) channel switches level at `splitSec`: used to
    /// build a recording where one muted span is genuinely quiet and another
    /// carries speech (TECH-MIC12). System (right) is constant.
    private func writeStereoWavTwoRegions(
        at url: URL, seconds: Double, splitSec: Double,
        micFirst: Float, micSecond: Float, system: Float
    ) throws {
        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 2, interleaved: false
        )!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(seconds * 16000)
        let split = Int(splitSec * 16000)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) {
            buf.floatChannelData![0][i] = i < split ? micFirst : micSecond
            buf.floatChannelData![1][i] = system
        }
        try file.write(from: buf)
    }

    private func peak(_ p: UnsafeMutablePointer<Float>, from: Int, to: Int) -> Float {
        var m: Float = 0
        for i in from..<to { m = max(m, abs(p[i])) }
        return m
    }
}
