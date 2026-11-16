import XCTest
@testable import MeetingPipe

/// CONC6: `SystemAudioCapture`'s statics are written from the cooperative pool (`prewarm`, `start`) and
/// main (the display observer) and read on main by half the app. They sit behind one lock, and the
/// display observer slot is claimed under it, so two concurrent prewarms register one observer.
/// Clean under `swift test --sanitize=thread`.
final class SystemAudioCaptureStateTests: XCTestCase {

    override func tearDown() {
        SystemAudioCapture.setPermissionState(.unknown)
        SystemAudioCapture.resetDisplayObserverForTesting()
        super.tearDown()
    }

    func test_the_permission_state_is_never_torn_under_concurrent_writers_and_a_main_reader() {
        let valid: [SystemAudioCapture.PermissionState] = [.unknown, .granted, .denied]
        let states = valid
        let writersDone = LockedBoolBox()
        let invalid = ThreadSafeCounter()
        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: 20_000) { i in
                SystemAudioCapture.setPermissionState(states[i % states.count])
            }
            writersDone.set(true)
        }
        // A reader on main, the way StatusBarController and PermissionsCenter read it.
        let deadline = Date().addingTimeInterval(20)
        var reads = 0
        while !writersDone.value, Date() < deadline {
            if !valid.contains(SystemAudioCapture.permissionState) { invalid.increment() }
            reads += 1
        }
        XCTAssertTrue(writersDone.value, "the writers never finished")
        XCTAssertEqual(invalid.value, 0)
        XCTAssertGreaterThan(reads, 0)
    }

    func test_the_last_write_wins_and_reads_back_whole() {
        SystemAudioCapture.setPermissionState(.granted)
        XCTAssertEqual(SystemAudioCapture.permissionState, .granted)
        SystemAudioCapture.setPermissionState(.denied)
        XCTAssertEqual(SystemAudioCapture.permissionState, .denied)
    }

    func test_two_concurrent_prewarms_register_one_display_observer() {
        SystemAudioCapture.resetDisplayObserverForTesting()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            SystemAudioCapture.observeDisplayReconfiguration()
        }
        XCTAssertEqual(SystemAudioCapture.displayObserverRegistrations, 1)
    }

    func test_a_reset_lets_the_next_prewarm_register_again() {
        SystemAudioCapture.resetDisplayObserverForTesting()
        SystemAudioCapture.observeDisplayReconfiguration()
        SystemAudioCapture.observeDisplayReconfiguration()
        XCTAssertEqual(SystemAudioCapture.displayObserverRegistrations, 1)
    }
}
