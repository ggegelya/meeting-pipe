import XCTest
@testable import MeetingPipe

/// REC9: the stop-time parity verdict, lifted out of `checkDurationParity` so the
/// rule is assertable without a recording.
final class RecordingDurationParityTests: XCTestCase {

    /// The recording this task exists for: 2026-07-15, where the merge kept 5.28 s
    /// of a 41.2 s meeting and the run was reported as a clean success.
    func test_the_2026_07_15_truncation_reads_as_short() {
        let parity = RecordingDurationParity.evaluate(audioSec: 5.28, wallclockSec: 41.2)
        XCTAssertTrue(parity.isShort)
        XCTAssertEqual(parity.ratio, 0.128, accuracy: 0.001)
        XCTAssertEqual(parity.audioSec, 5.28)
        XCTAssertEqual(parity.wallclockSec, 41.2)
    }

    /// A healthy recording is ~100% of its wallclock and must not warn; nor may the
    /// sub-second capture skew that every one of the owner's 153 recordings carries.
    func test_a_healthy_recording_is_not_short() {
        XCTAssertFalse(RecordingDurationParity.evaluate(audioSec: 600, wallclockSec: 600).isShort)
        XCTAssertFalse(RecordingDurationParity.evaluate(audioSec: 599.79, wallclockSec: 600).isShort)
    }

    /// The ratio floor, from both sides.
    func test_the_ratio_floor_is_where_the_warning_starts() {
        XCTAssertFalse(RecordingDurationParity.evaluate(audioSec: 86, wallclockSec: 100).isShort)
        XCTAssertTrue(RecordingDurationParity.evaluate(audioSec: 84, wallclockSec: 100).isShort)
    }

    /// A two-second mis-start would fail the ratio on rounding alone, so it is
    /// excluded rather than reported.
    func test_a_recording_too_short_to_judge_never_warns() {
        XCTAssertFalse(RecordingDurationParity.evaluate(audioSec: 0.1, wallclockSec: 1.5).isShort)
        XCTAssertTrue(RecordingDurationParity.evaluate(audioSec: 0.1, wallclockSec: 2.5).isShort)
    }

    /// An unusable wallclock (no start time) reads as parity rather than as a
    /// 0-second recording, so a missing input cannot manufacture a warning.
    func test_an_unusable_wallclock_reads_as_parity() {
        let parity = RecordingDurationParity.evaluate(audioSec: 12, wallclockSec: 0)
        XCTAssertEqual(parity.ratio, 1.0)
        XCTAssertFalse(parity.isShort)
    }

    /// The notice quotes lengths the owner can check against the meeting they just
    /// left, so the phrase is clock time, not a percentage.
    func test_clockPhrase_is_minutes_and_seconds() {
        XCTAssertEqual(RecordingDurationParity.clockPhrase(5.28), "0:05")
        XCTAssertEqual(RecordingDurationParity.clockPhrase(41.2), "0:41")
        XCTAssertEqual(RecordingDurationParity.clockPhrase(605), "10:05")
        XCTAssertEqual(RecordingDurationParity.clockPhrase(0), "0:00")
    }
}
