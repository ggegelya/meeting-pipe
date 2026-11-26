import XCTest
@testable import MeetingPipe

/// T13 amendment (2026-11-21): resolving a call the production code has not made yet is a test bug,
/// so the fake fails the test there instead of carrying on as if the job had completed.
final class FakePipelineDriverTests: XCTestCase {

    private let wav = URL(fileURLWithPath: "/tmp/mp-t13-fake.wav")

    func test_finishing_with_nothing_parked_fails_the_test() {
        let driver = FakePipelineDriver()
        XCTExpectFailure("finish with no parked run-all must record a failure") {
            driver.finish(.success(nil))
        }
    }

    func test_landing_a_restore_that_was_never_asked_for_fails_the_test() {
        let driver = FakePipelineDriver()
        XCTExpectFailure("landRestore with no restore in flight must record a failure") {
            driver.landRestore()
        }
    }

    func test_finishing_a_parked_call_resolves_it_once() {
        let driver = FakePipelineDriver()
        var results: [Result<URL?, Error>] = []
        driver.runAll(wav: wav, summaryMode: .auto) { results.append($0) }

        driver.finish(.success(nil))
        XCTAssertEqual(results.count, 1)

        XCTExpectFailure("a finished call is consumed, so a second finish has nothing to resolve") {
            driver.finish(.success(nil))
        }
        XCTAssertEqual(results.count, 1)
    }
}
