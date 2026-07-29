import AppKit
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

    // HYG1: the meter poll runs only while the panel is visible and a provider is set.
    func test_shouldMeterTick_only_when_visible_and_provider_set() {
        XCTAssertTrue(RecordingHUDWindow.shouldMeterTick(occlusionVisible: true, hasProvider: true))
        XCTAssertFalse(RecordingHUDWindow.shouldMeterTick(occlusionVisible: false, hasProvider: true))
        XCTAssertFalse(RecordingHUDWindow.shouldMeterTick(occlusionVisible: true, hasProvider: false))
        XCTAssertFalse(RecordingHUDWindow.shouldMeterTick(occlusionVisible: false, hasProvider: false))
    }
}

/// UX35: the pill is one width for both the recording and the off-the-record state, so toggling
/// off the record never resizes the HUD. The width decision lives on `HUDPanelGeometry` precisely
/// so that is a test rather than a code-reading exercise; a reintroduced per-state width fails here.
final class HUDPanelGeometryTests: XCTestCase {

    /// The load-bearing one. Off-the-record is an input to the decision and changes nothing.
    func test_off_the_record_does_not_change_the_pill_size() {
        XCTAssertEqual(
            HUDPanelGeometry.size(offRecord: false, degraded: false),
            HUDPanelGeometry.size(offRecord: true, degraded: false)
        )
    }

    /// It does not move the degraded card either: that state owns the geometry outright, and a
    /// span opened before the banner appeared must not shift it.
    func test_off_the_record_does_not_change_the_degraded_card_size() {
        XCTAssertEqual(
            HUDPanelGeometry.size(offRecord: false, degraded: true),
            HUDPanelGeometry.size(offRecord: true, degraded: true)
        )
    }

    /// Clearing the banner mid-span returns to the shared pill, not to a narrower recording-only
    /// width. That is what stops the pre-UX35 shrink under a label the pill could not fit.
    func test_clearing_degraded_returns_to_the_shared_pill_width() {
        XCTAssertEqual(HUDPanelGeometry.size(offRecord: true, degraded: false).width, HUDPanelGeometry.pillWidth)
        XCTAssertEqual(HUDPanelGeometry.size(offRecord: false, degraded: false).width, HUDPanelGeometry.pillWidth)
    }

    /// The degraded card is the only state that resizes, and it keeps its own 232pt width plus the
    /// banner's height on top of the pill's.
    func test_degraded_card_is_the_only_resize() {
        let pill = HUDPanelGeometry.size(offRecord: false, degraded: false)
        let card = HUDPanelGeometry.size(offRecord: false, degraded: true)
        XCTAssertEqual(pill, CGSize(width: HUDPanelGeometry.pillWidth, height: HUDPanelGeometry.height))
        XCTAssertEqual(card, CGSize(width: HUDPanelGeometry.cardWidth, height: HUDPanelGeometry.height + HUDPanelGeometry.bannerHeight))
        XCTAssertGreaterThan(card.width, pill.width)
    }

    /// The number itself: the pill has to fit the widest state label it can show. Measured the way
    /// the HUD lays it out, dot 8 + stack spacing 5 + the label's intrinsic width at 10pt medium,
    /// so a font or copy change that outgrows the constant fails here instead of clipping on screen.
    func test_pill_width_fits_both_state_labels() {
        for label in ["Recording", "Off the record"] {
            XCTAssertGreaterThan(
                HUDPanelGeometry.pillWidth,
                HUDPanelGeometryTests.dotRowWidth(label),
                "\(label) does not fit the shared pill width"
            )
        }
    }

    /// Reproduces `makeContentView`'s dot row: an 8pt dot and the state label in a 5pt-spaced
    /// horizontal stack.
    private static func dotRowWidth(_ text: String) -> CGFloat {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: MPType.medium)
        return 8 + 5 + label.intrinsicContentSize.width
    }
}
