import AVFoundation
import XCTest
@testable import MeetingPipe

/// REC12: `installTap` raises an Objective-C `NSException` on an unusable format, and Swift
/// cannot catch that, so the process aborts. All four crash reports on the owner's machine
/// are that abort, each within 50 to 100 ms of a meeting prompt appearing.
///
/// These fail against `main`, where both call sites read `outputFormat(forBus: 0)` and hand
/// it straight to `installTap` with nothing in between.
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
            let ran = GuardedTapInstall.install(
                format: zeroSampleRate, site: "mic_level_monitor"
            ) { installed.value = true }

            XCTAssertFalse(ran)
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
            let ran = GuardedTapInstall.install(
                format: zeroChannels, site: "meeting_recorder"
            ) { installed.value = true }

            XCTAssertFalse(ran)
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
            let ran = GuardedTapInstall.install(
                format: healthy, site: "mic_level_monitor"
            ) { installed.value = true }

            XCTAssertTrue(ran)
            XCTAssertTrue(installed.value)
            XCTAssertEqual(try skipRows(in: dir).count, 0, "a guard that narrates every healthy start is noise")
        }
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
        let events = dir.appendingPathComponent("events.jsonl")
        guard let text = try? String(contentsOf: events, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["action"] as? String == "mic_tap_install_skipped" else { return nil }
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
