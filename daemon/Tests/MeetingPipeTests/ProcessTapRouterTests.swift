import XCTest
@testable import MeetingPipe

/// ProcessTapRouter wraps macOS 14.2+ Core Audio APIs that can't be
/// exercised in CI without a live audio session and Screen Recording
/// permission. These tests pin the things we CAN check without that:
///   - Identity constants don't drift (they're persisted in user-visible
///     device names; changing them later orphans live aggregates).
///   - The availability check is honest (returns `true` only when the
///     APIs are linkable).
///   - On macOS 14.2+ at runtime, basic enumeration / construction of
///     the helper doesn't crash.
final class ProcessTapRouterTests: XCTestCase {

    func testIdentityConstantsStable() {
        if #available(macOS 14.2, *) {
            XCTAssertEqual(ProcessTapRouter.displayName, "MeetingPipe-Tap-Capture")
            XCTAssertEqual(ProcessTapRouter.aggregateUID, "com.meetingpipe.tap-capture")
            XCTAssertEqual(ProcessTapRouter.tapName, "MeetingPipe System Tap")
        }
    }

    func testAvailabilityMatchesRuntime() {
        // We linked the binary against an SDK that has the CATap APIs.
        // isAvailable() reflects the deployment target check.
        if #available(macOS 14.2, *) {
            XCTAssertTrue(ProcessTapRouter.isAvailable())
        } else {
            XCTAssertFalse(ProcessTapRouter.isAvailable())
        }
    }

    func testInstantiationDoesNotCrashOnSupportedOS() {
        if #available(macOS 14.2, *) {
            // No prepare() call — that needs Screen Recording perm and
            // would actually create a tap. We just check the type loads.
            _ = ProcessTapRouter()
        }
    }

    func testCleanupStaleIsSafeWhenNothingExists() {
        // Idempotent on a clean system — fresh install or after a clean
        // shutdown should not throw / hang.
        if #available(macOS 14.2, *) {
            ProcessTapRouter.cleanupStale()
        }
    }
}
