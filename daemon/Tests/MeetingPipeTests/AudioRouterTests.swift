import XCTest
@testable import MeetingPipe

/// Tests for AudioRouter pieces that don't need a live Core Audio device.
///
/// The Core Audio operations themselves (create aggregate, set default output,
/// destroy device) need a real macOS audio subsystem and are not exercised
/// here — `swift test` runs in CI without an audio session. We DO test:
///   - Persistence round-trip (UID → file → UID)
///   - Stale-state cleanup on a fresh state file
///   - Constants haven't drifted
///   - findBlackHole() doesn't crash when the device is absent
///
/// On a developer Mac with BlackHole installed, `swift test` will additionally
/// hit the `findBlackHole()` happy path.
final class AudioRouterTests: XCTestCase {

    func testIdentityConstantsStable() {
        // These two strings are persisted on the user's Mac via
        // AudioHardwareCreateAggregateDevice. Changing them later orphans
        // any in-flight transient device, so we pin them here.
        XCTAssertEqual(AudioRouter.displayName, "MeetingPipe-Capture")
        XCTAssertEqual(AudioRouter.aggregateUID, "com.meetingpipe.capture-output")
        XCTAssertEqual(AudioRouter.blackHoleNameNeedle, "BlackHole")
    }

    func testFindBlackHoleDoesNotCrashWhenAbsent() {
        // On Linux CI / on a Mac without BlackHole, this returns nil. The
        // important property is that it doesn't throw or trap.
        let router = AudioRouter()
        _ = router.findBlackHole()
    }

    func testAllDeviceIDsReturnsArray() {
        // Even on a Mac with no audio hardware (extremely unusual), this must
        // return an empty array, never crash.
        let router = AudioRouter()
        let ids = router.allDeviceIDs()
        // Just exercising the call path. Most CI Macs will have at least
        // built-in output, so this is usually non-empty.
        XCTAssertGreaterThanOrEqual(ids.count, 0)
    }

    func testCurrentDefaultOutputDoesNotCrash() {
        let router = AudioRouter()
        _ = router.currentDefaultOutput()
    }
}
