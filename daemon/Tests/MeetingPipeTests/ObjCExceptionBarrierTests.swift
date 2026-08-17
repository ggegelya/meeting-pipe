import MeetingPipeObjC
import XCTest

/// REC12 item 2. The `MeetingPipeObjC` target exists for one function, and this is its
/// contract.
///
/// **What these cannot prove, said plainly rather than implied: that the process would
/// otherwise have died.** XCTest installs its own Objective-C exception handler around each
/// test case, so neutering `MPRunCatchingObjCException` to a bare `body()` turns these into
/// ordinary red tests ("required condition is false: ... (NSInvalidArgumentException)"),
/// not an aborted binary. Measured 2026-08-17, because the first draft of this comment
/// asserted the abort and was wrong. The daemon has no such handler, which is exactly why
/// the same raise there reached `objc_terminate` and `abort()` four times, and it is why
/// nothing in this file can be more than the testable half: a raise comes back as a value,
/// carrying the reason.
final class ObjCExceptionBarrierTests: XCTestCase {

    func test_a_body_that_returns_normally_reports_no_raise() {
        let ran = expectation(description: "body ran")
        let raise = MPRunCatchingObjCException { ran.fulfill() }

        wait(for: [ran], timeout: 1)
        XCTAssertNil(raise, "a healthy call must not be reported as a failure")
    }

    /// The whole point: a raise comes back as a value.
    func test_a_raise_comes_back_as_a_string_rather_than_escaping_the_call() throws {
        let raise = MPRunCatchingObjCException {
            NSException(
                name: .invalidArgumentException,
                reason: "required condition is false: format.sampleRate == hwFormat.sampleRate",
                userInfo: nil
            ).raise()
        }

        let text = try XCTUnwrap(raise)
        XCTAssertTrue(text.contains("NSInvalidArgumentException"), "the name is half the diagnosis: \(text)")
        XCTAssertTrue(
            text.contains("format.sampleRate == hwFormat.sampleRate"),
            "the reason is the string no crash report carries, and it is the reason this returns one: \(text)"
        )
    }

    /// `reason` is optional on `NSException`, and a bare name reads like a truncated
    /// string. Say so instead.
    func test_a_raise_with_no_reason_still_names_itself() throws {
        let raise = MPRunCatchingObjCException {
            NSException(name: .genericException, reason: nil, userInfo: nil).raise()
        }

        let text = try XCTUnwrap(raise)
        XCTAssertTrue(text.contains("NSGenericException"))
        XCTAssertTrue(text.contains("no reason given"), text)
    }

    /// The barrier is not a general error trap. A Swift error thrown inside the body is
    /// not an ObjC raise and must be left to Swift's own `do/catch`, or a caller would
    /// start reading one mechanism's failures through the other's.
    func test_a_swift_error_is_not_the_barriers_business() {
        struct Boom: Error {}
        var caught: Error?

        let raise = MPRunCatchingObjCException {
            do { throw Boom() } catch { caught = error }
        }

        XCTAssertNil(raise)
        XCTAssertTrue(caught is Boom)
    }

    /// A raise from further down the stack, which is the real shape: AVFAudio raises
    /// several frames inside `installTap`, not in the closure the caller wrote.
    func test_a_raise_from_a_nested_call_is_caught_the_same_way() throws {
        func inner() { NSException(name: .internalInconsistencyException, reason: "deep", userInfo: nil).raise() }
        func middle() { inner() }

        let raise = MPRunCatchingObjCException { middle() }

        XCTAssertTrue(try XCTUnwrap(raise).contains("deep"))
    }

    /// Consecutive raises each come back, so the barrier holds no state and one catch does
    /// not spend it. The *engine* is what a catch retires, and that lives in
    /// `GuardedTapInstall`, not here.
    func test_the_barrier_holds_no_state_between_calls() {
        for index in 0..<3 {
            let raise = MPRunCatchingObjCException {
                NSException(name: .genericException, reason: "raise \(index)", userInfo: nil).raise()
            }
            XCTAssertEqual(raise, "NSGenericException: raise \(index)")
        }
        XCTAssertNil(MPRunCatchingObjCException {}, "a spent barrier would report a healthy call as a failure")
    }
}
