import CoreMedia
import XCTest
@testable import MeetingPipe

/// REC33: the system channel's first buffer is stamped with when it was captured as well as when
/// it was delivered, and the gap is logged. The merge still places the far side by the delivery
/// stamp: the spec forbids moving it before a measurement confirms the lag, and this is the
/// measurement.
final class SystemCaptureLagREC33Tests: XCTestCase {

    func test_a_host_clock_presentation_time_converts_to_uptime_seconds() {
        let pts = CMTime(seconds: 12_345.5, preferredTimescale: 1_000_000_000)
        XCTAssertEqual(try XCTUnwrap(SystemCaptureClock.captureUptime(of: pts)), 12_345.5, accuracy: 1e-6)
    }

    func test_an_unusable_presentation_time_has_no_capture_uptime() {
        XCTAssertNil(SystemCaptureClock.captureUptime(of: .invalid))
        XCTAssertNil(SystemCaptureClock.captureUptime(of: .indefinite))
        XCTAssertNil(SystemCaptureClock.captureUptime(of: .positiveInfinity))
        XCTAssertNil(SystemCaptureClock.captureUptime(of: .zero))
    }

    /// The field's shape: a first buffer delivered 2 s after it was captured.
    func test_a_buffer_captured_two_seconds_before_delivery_reports_a_two_second_lag() {
        let captured = SystemCaptureClock.captureUptime(of: CMTime(seconds: 1_000, preferredTimescale: 48_000))
        XCTAssertEqual(try XCTUnwrap(SystemCaptureClock.lag(captureUptime: captured, deliveredAt: 1_002)), 2, accuracy: 1e-9)
    }

    func test_a_capture_time_off_the_host_clock_is_not_believed() {
        XCTAssertNil(SystemCaptureClock.lag(captureUptime: nil, deliveredAt: 1_000))
        XCTAssertNil(SystemCaptureClock.lag(captureUptime: 1_001, deliveredAt: 1_000), "after delivery")
        XCTAssertNil(SystemCaptureClock.lag(captureUptime: 10, deliveredAt: 1_000), "implausibly early")
        XCTAssertEqual(SystemCaptureClock.lag(captureUptime: 1_000, deliveredAt: 1_000), 0)
    }

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The lag is logged beside the offset, and the offset the merge uses is still the delivery
    /// stamp. When a measurement confirms the lag, flipping this is the fix, and this test says so.
    func test_the_lag_is_logged_and_the_merge_offset_is_unchanged() throws {
        let recorder = try source("Sources/MeetingPipe/MeetingRecorder.swift")
        XCTAssertTrue(recorder.contains("\"system_capture_lag_sec\": session.systemCaptureLagSec as Any"))
        XCTAssertTrue(recorder.contains("systemHeadOffsetSec: firstFrame > 0 ? max(0, firstFrame - startedAtUptime) : 0,"))
        let channel = try source("Sources/MeetingPipe/SystemAudioChannel.swift")
        XCTAssertTrue(channel.contains("self.systemFirstFrameUptime = deliveredAt"), "the head offset still keys off delivery")
        XCTAssertTrue(channel.contains("SystemCaptureClock.lag(\n                    captureUptime: capturedAt, deliveredAt: deliveredAt"))
    }
}
