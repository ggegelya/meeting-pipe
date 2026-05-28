import XCTest
@testable import MeetingPipe

/// TECH-UX1: the first-run gate that decides whether onboarding shows on launch.
final class OnboardingGateTests: XCTestCase {

    private var original: Bool = false

    override func setUp() {
        super.setUp()
        original = UserDefaults.standard.bool(forKey: OnboardingGate.key)
    }

    override func tearDown() {
        UserDefaults.standard.set(original, forKey: OnboardingGate.key)
        super.tearDown()
    }

    func test_reset_marks_not_completed() {
        OnboardingGate.reset()
        XCTAssertFalse(OnboardingGate.isCompleted)
    }

    func test_markCompleted_sets_completed() {
        OnboardingGate.reset()
        OnboardingGate.markCompleted()
        XCTAssertTrue(OnboardingGate.isCompleted)
    }

    func test_reset_clears_a_prior_completion() {
        OnboardingGate.markCompleted()
        OnboardingGate.reset()
        XCTAssertFalse(OnboardingGate.isCompleted)
    }
}
