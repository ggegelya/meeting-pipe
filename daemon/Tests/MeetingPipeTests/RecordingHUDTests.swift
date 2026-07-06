import XCTest
@testable import MeetingPipe

/// Pins the pure dBFS -> normalized-level mapping the DSN25 HUD port uses to drive
/// the shared `LEDMeterView`. The old bespoke `HUDLevelMeter` did this fraction math
/// inline; extracting it makes the mapping testable without the 10 Hz poll timer,
/// and documents the -60..0 dBFS window the meter reads.
final class RecordingHUDTests: XCTestCase {

    func test_normalizedLevel_maps_dbfs_window_to_unit_interval() {
        XCTAssertEqual(RecordingHUDWindow.normalizedLevel(db: 0), 1, accuracy: 0.0001)     // full scale
        XCTAssertEqual(RecordingHUDWindow.normalizedLevel(db: -60), 0, accuracy: 0.0001)   // floor = silence
        XCTAssertEqual(RecordingHUDWindow.normalizedLevel(db: -30), 0.5, accuracy: 0.0001) // midpoint
    }

    func test_normalizedLevel_clamps_out_of_range_input() {
        XCTAssertEqual(RecordingHUDWindow.normalizedLevel(db: 12), 1, accuracy: 0.0001)    // above 0 clamps high
        XCTAssertEqual(RecordingHUDWindow.normalizedLevel(db: -120), 0, accuracy: 0.0001)  // below the floor clamps low
    }

    /// The mapping composes with the meter's stepping: a mid level lights about half
    /// of the 10 segments (LEDMeterView rounds to the nearest segment).
    func test_normalizedLevel_feeds_led_segment_count() {
        let mid = RecordingHUDWindow.normalizedLevel(db: -30)
        XCTAssertEqual(LEDMeterView.litCount(forLevel: mid, segments: 10), 5)
    }
}
