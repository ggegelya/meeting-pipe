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

    // MARK: - UX82 item 4: resume at Permissions after the Accessibility relaunch

    private func scratchDefaults() throws -> (UserDefaults, String) {
        let suite = "onboarding-resume-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    func test_a_persisted_permissions_step_resumes_there_once() throws {
        let (defaults, suite) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        OnboardingResume.persist(step: OnboardingResume.permissionsStep, defaults: defaults)
        XCTAssertEqual(OnboardingResume.take(defaults: defaults), 1, "resumes at Permissions")
        XCTAssertEqual(OnboardingResume.take(defaults: defaults), 0, "cleared after use")
    }

    func test_no_persisted_step_starts_at_welcome() throws {
        let (defaults, suite) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(OnboardingResume.take(defaults: defaults), 0)
    }

    /// Only Permissions resumes: the later steps hold their choices in memory (WF9).
    func test_a_later_step_is_not_resumed() throws {
        let (defaults, suite) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        OnboardingResume.persist(step: 3, defaults: defaults)
        XCTAssertEqual(OnboardingResume.take(defaults: defaults), 0)
    }

    /// The notice never names a button that is not there.
    func test_the_accessibility_notice_matches_whether_relaunch_is_offered() {
        XCTAssertTrue(OnboardingStepPermissions.accessibilityNotice(canRelaunch: true).contains("relaunch MeetingPipe"))
        XCTAssertFalse(OnboardingStepPermissions.accessibilityNotice(canRelaunch: false).lowercased().contains("relaunch"))
    }
}
