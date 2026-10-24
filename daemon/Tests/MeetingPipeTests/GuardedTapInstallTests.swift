import AVFoundation
import XCTest
@testable import MeetingPipe

/// REC12: `installTap` raises an Objective-C `NSException` on an unusable format, and Swift
/// cannot catch that, so the process aborts. All four crash reports on the owner's machine
/// are that abort, each within 50 to 100 ms of a meeting prompt appearing.
///
/// These fail against `main`, where both call sites read `outputFormat(forBus: 0)` and hand
/// it straight to `installTap` with nothing in between.
/// T7 source fence (deliberate): test_every_installTap_call_site_goes_through_the_guard and test_the_objc_barrier_has_exactly_one_caller ban bare calls across daemon/Sources. Missing seam: none; the claim is about the source text itself (CI has no live AVAudioEngine).
final class GuardedTapInstallTests: XCTestCase {

    /// A live `AVAudioFormat` reporting 0 Hz. This is not a contrivance: it is what
    /// `inputNode.outputFormat(forBus: 0)` returns while the HAL has no usable input, and a
    /// non-nil format object is not evidence of a usable one.
    private var zeroSampleRate: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 0, channels: 1)!
    }

    private var zeroChannels: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 0)!
    }

    private var healthy: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    }

    // MARK: - The predicate

    func test_a_zero_sample_rate_format_is_not_installable() {
        XCTAssertEqual(zeroSampleRate.sampleRate, 0, "precondition: AVAudioFormat really does hold this")
        XCTAssertFalse(GuardedTapInstall.isInstallable(zeroSampleRate))
    }

    func test_a_zero_channel_format_is_not_installable() {
        XCTAssertEqual(zeroChannels.channelCount, 0)
        XCTAssertFalse(GuardedTapInstall.isInstallable(zeroChannels))
    }

    func test_a_healthy_format_is_installable() {
        XCTAssertTrue(GuardedTapInstall.isInstallable(healthy))
    }

    // MARK: - The seam

    func test_a_zero_sample_rate_format_does_not_reach_installTap() throws {
        try withScratchLogs { dir in
            let installed = OSAllocatedUnfairLockBox<Bool>(false)
            let outcome = GuardedTapInstall.install(
                format: zeroSampleRate, site: "mic_level_monitor", engine: AVAudioEngine()
            ) { installed.value = true }

            XCTAssertEqual(outcome, .refusedFormat)
            XCTAssertFalse(installed.value, "installTap was reached; on a real node this aborts the process")
            let rows = try skipRows(in: dir)
            XCTAssertEqual(rows.count, 1, "a skip has to be readable afterwards, or the next one is another reconstruction")
            let row = try XCTUnwrap(rows.first)
            XCTAssertEqual(row["site"] as? String, "mic_level_monitor")
            XCTAssertEqual(row["sample_rate"] as? Double, 0)
        }
    }

    func test_a_zero_channel_format_does_not_reach_installTap() throws {
        try withScratchLogs { dir in
            let installed = OSAllocatedUnfairLockBox<Bool>(false)
            let outcome = GuardedTapInstall.install(
                format: zeroChannels, site: "meeting_recorder", engine: AVAudioEngine()
            ) { installed.value = true }

            XCTAssertEqual(outcome, .refusedFormat)
            XCTAssertFalse(installed.value)
            let row = try XCTUnwrap(try skipRows(in: dir).first)
            XCTAssertEqual(row["site"] as? String, "meeting_recorder")
            XCTAssertEqual(row["channels"] as? Int, 0)
        }
    }

    /// The guard is not a blanket disable: a healthy format still gets its tap, and nothing
    /// is logged about it.
    func test_a_healthy_format_installs_the_tap_and_logs_nothing() throws {
        try withScratchLogs { dir in
            let installed = OSAllocatedUnfairLockBox<Bool>(false)
            let outcome = GuardedTapInstall.install(
                format: healthy, site: "mic_level_monitor", engine: AVAudioEngine()
            ) { installed.value = true }

            XCTAssertEqual(outcome, .installed)
            XCTAssertTrue(installed.value)
            XCTAssertEqual(try skipRows(in: dir).count, 0, "a guard that narrates every healthy start is noise")
        }
    }

    // MARK: - The barrier (REC12 item 2)

    /// The acceptance bullet the barrier exists for. The guard above answers the raise
    /// conditions readable from the format; this one is the condition no pre-check can
    /// reach, the format disagreeing with the node's hardware format at the instant
    /// `installTap` re-reads it.
    ///
    /// Red without the barrier, measured 2026-08-17 by neutering
    /// `MPRunCatchingObjCException` to a bare `body()`: the raise escapes `install` and
    /// XCTest reports it as "required condition is false: format.sampleRate ==
    /// hwFormat.sampleRate (NSInvalidArgumentException)". Note it goes *red*, not *silent*:
    /// XCTest catches raises itself, so no test can demonstrate the abort. The daemon has
    /// no such handler, which is the whole bug.
    func test_a_raising_installTap_surfaces_as_a_value_rather_than_escaping_the_seam() throws {
        try withScratchLogs { dir in
            let outcome = GuardedTapInstall.install(
                format: healthy, site: "mic_level_monitor", engine: AVAudioEngine()
            ) {
                NSException(
                    name: .invalidArgumentException,
                    reason: "required condition is false: format.sampleRate == hwFormat.sampleRate",
                    userInfo: nil
                ).raise()
            }

            XCTAssertEqual(outcome, .raised)

            let row = try XCTUnwrap(try rows(in: dir, action: "mic_tap_install_raised").first)
            XCTAssertEqual(row["site"] as? String, "mic_level_monitor")
            XCTAssertEqual(row["sample_rate"] as? Double, 48_000)
            let reason = try XCTUnwrap(row["reason"] as? String)
            XCTAssertTrue(
                reason.contains("format.sampleRate == hwFormat.sampleRate"),
                "the reason string is the one thing a crash report never carried, so a caught raise has to record it: \(reason)"
            )
        }
    }

    /// The caveat that came with the barrier, made mechanical. Catching an `NSException`
    /// out of AVFAudio's C++ frames leaves the engine unspecified, so the retry has to be
    /// impossible rather than merely discouraged: both call sites have a live retry path
    /// into this seam (every prompt, every device change).
    func test_a_caught_raise_condemns_the_engine_so_no_later_tap_reaches_installTap() throws {
        try withScratchLogs { dir in
            let engine = AVAudioEngine()
            XCTAssertFalse(GuardedTapInstall.isCondemned(engine), "precondition")

            _ = GuardedTapInstall.install(format: healthy, site: "meeting_recorder", engine: engine) {
                NSException(name: .genericException, reason: "boom", userInfo: nil).raise()
            }
            XCTAssertTrue(GuardedTapInstall.isCondemned(engine))

            let reached = OSAllocatedUnfairLockBox<Bool>(false)
            let retry = GuardedTapInstall.install(
                format: healthy, site: "meeting_recorder", engine: engine
            ) { reached.value = true }

            XCTAssertEqual(retry, .refusedCondemnedEngine)
            XCTAssertFalse(reached.value, "a second installTap on an engine that already raised is the worse-than-the-abort case")
            XCTAssertEqual(try rows(in: dir, action: "mic_tap_install_refused").count, 1)
        }
    }

    /// Condemnation is per engine, not a process-wide latch. The way back from a raise is a
    /// **new** engine, which `MeetingRecorder.start` takes; a global flag would have made
    /// one raise the end of recording for the process lifetime.
    func test_condemning_one_engine_leaves_another_installable() throws {
        try withScratchLogs { _ in
            let condemned = AVAudioEngine()
            _ = GuardedTapInstall.install(format: healthy, site: "meeting_recorder", engine: condemned) {
                NSException(name: .genericException, reason: "boom", userInfo: nil).raise()
            }

            let replacement = AVAudioEngine()
            let installed = OSAllocatedUnfairLockBox<Bool>(false)
            let outcome = GuardedTapInstall.install(
                format: healthy, site: "meeting_recorder", engine: replacement
            ) { installed.value = true }

            XCTAssertEqual(outcome, .installed)
            XCTAssertTrue(installed.value)
            XCTAssertFalse(GuardedTapInstall.isCondemned(replacement))
        }
    }

    /// The two failures a caller has to tell apart, stated on the type rather than left to
    /// each call site to work out: a refused format is retryable on the same engine (it was
    /// transitional, and the device was usable seconds later), a caught raise never is.
    func test_only_a_raise_and_a_condemned_engine_demand_a_fresh_one() {
        XCTAssertFalse(GuardedTapInstall.Outcome.installed.requiresFreshEngine)
        XCTAssertFalse(GuardedTapInstall.Outcome.refusedFormat.requiresFreshEngine)
        XCTAssertTrue(GuardedTapInstall.Outcome.raised.requiresFreshEngine)
        XCTAssertTrue(GuardedTapInstall.Outcome.refusedCondemnedEngine.requiresFreshEngine)

        XCTAssertTrue(GuardedTapInstall.Outcome.installed.isInstalled)
        XCTAssertFalse(GuardedTapInstall.Outcome.raised.isInstalled)

        // Distinct reasons, so a failed device-change recovery in the log a year from now
        // still says which of the two happened.
        let reasons = Set([
            GuardedTapInstall.Outcome.refusedFormat.recoveryReason,
            GuardedTapInstall.Outcome.refusedCondemnedEngine.recoveryReason,
            GuardedTapInstall.Outcome.raised.recoveryReason,
        ])
        XCTAssertEqual(reasons.count, 3)
    }

    // MARK: - The sibling on the recording path

    /// `MeetingRecorder.installMicTap` is the same unguarded call, reached from `start()`
    /// **and** from device-change recovery, which is the transitional window this crash
    /// lives in. It has never been observed aborting, but an abort there costs a meeting
    /// rather than a prompt animation.
    ///
    /// A source fence rather than a behavioural test because the call needs a live
    /// `AVAudioEngine` bound to a real input device, which CI has not got. It is a real
    /// fence, not a spelling check: it goes red against `main` (where `GuardedTapInstall`
    /// does not exist) and it goes red again the day someone adds a third bare `installTap`.
    func test_every_installTap_call_site_goes_through_the_guard() throws {
        let sources = try daemonSourceFiles()
        XCTAssertFalse(sources.isEmpty, "found no daemon sources to fence")
        for (path, text) in sources {
            let calls = text.components(separatedBy: ".installTap(onBus:").count - 1
            guard calls > 0 else { continue }
            let guarded = text.components(separatedBy: "GuardedTapInstall.install(").count - 1
            XCTAssertGreaterThanOrEqual(
                guarded, calls,
                "\(path) calls installTap \(calls)x but routes only \(guarded) through GuardedTapInstall. "
                    + "A bare installTap raises an ObjC exception Swift cannot catch, and the process aborts."
            )
        }
    }

    /// The other half of "exactly one path from a format to `installTap`": the barrier has
    /// exactly one Swift caller too. `MPRunCatchingObjCException` catches a raise and hands
    /// back a string, and the engine it raised on is unspecified afterwards, so a second
    /// caller would be a second place that has to remember to retire it. Condemnation lives
    /// in `GuardedTapInstall`, and so does the call.
    func test_the_objc_barrier_has_exactly_one_caller() throws {
        for (path, text) in try daemonSourceFiles() where text.contains("MPRunCatchingObjCException") {
            XCTAssertEqual(
                path, "MeetingPipe/GuardedTapInstall.swift",
                "\(path) calls the ObjC exception barrier directly. A caught raise leaves its subject "
                    + "unusable, and GuardedTapInstall is the one place that records that."
            )
        }
    }

    // MARK: - Helpers

    /// Point `Log` at a scratch directory so these read back exactly the rows they wrote.
    private func withScratchLogs(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-tapguard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", dir.path, 1)
        defer {
            unsetenv("MEETINGPIPE_LOGS_DIR")
            try? FileManager.default.removeItem(at: dir)
        }
        try body(dir)
    }

    private func skipRows(in dir: URL) throws -> [[String: Any]] {
        try rows(in: dir, action: "mic_tap_install_skipped")
    }

    private func rows(in dir: URL, action: String) throws -> [[String: Any]] {
        let events = dir.appendingPathComponent("events.jsonl")
        guard let text = try? String(contentsOf: events, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["action"] as? String == action else { return nil }
            return object
        }
    }

    private func daemonSourceFiles() throws -> [(String, String)] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
            .appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(atPath: sources.path) else { return [] }
        var found: [(String, String)] = []
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(relative), encoding: .utf8)
            found.append((relative, text))
        }
        return found
    }
}
