import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// DET17: the scheduled-Meet title shape, fenced by captured shape classes rather than a guess.
/// END5 narrowed `googleMeet` to the room code or host; a scheduled Meet's tab carries neither, so 5
/// of 6 Chrome Meet calls on the work laptop never prompted.
final class MeetTitleShapeFixtureTests: XCTestCase {

    private struct Shape: Decodable {
        let `class`: String
        let title: String
        let admit: Bool
        let pwa: Bool?
    }

    private struct Fixture: Decodable {
        let shapes: [Shape]
    }

    private func load() throws -> [Shape] {
        // A missing fixture is a failure, never a skip (T7).
        let url = try XCTUnwrap(Bundle.module.url(forResource: "browser_meet_title_shapes", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).shapes
    }

    func test_every_shape_class_matches_the_matchers_as_labelled() throws {
        let shapes = try load()
        XCTAssertGreaterThanOrEqual(shapes.count, 10)
        for shape in shapes {
            let matched = MeetingTitlePatterns.googleMeet(shape.title) || MeetingTitlePatterns.googleMeetNamed(shape.title)
            XCTAssertEqual(matched, shape.admit, "shape class \(shape.class)")
            let strong = BrowserMeetingLifecycleAdapter.strongTitleMatchers.contains { $0(shape.title) }
            XCTAssertEqual(strong, shape.admit, "the start gate disagrees on \(shape.class)")
        }
    }

    func test_the_admission_gate_admits_exactly_the_positive_classes() throws {
        for shape in try load() where shape.pwa != true {
            let admission = MeetingSourceScanner.decideBrowserAdmission(windowTitles: [shape.title], urlFragments: [])
            XCTAssertEqual(admission == .admit, shape.admit, "shape class \(shape.class) -> \(admission)")
        }
    }

    /// DET6's fence holds: a page about a product is refused as a weak title, not admitted.
    func test_a_product_comparison_page_stays_weak_title_only() {
        let title = "Webex vs Zoom Comparison"
        XCTAssertEqual(
            MeetingSourceScanner.decideBrowserAdmission(windowTitles: [title], urlFragments: []),
            .weakTitleOnly(matchedTitle: title)
        )
    }

    func test_the_brand_shape_classes_never_carry_the_title() {
        XCTAssertEqual(MeetingSourceScanner.meetBrandShape("Meet"), "meet_bare")
        XCTAssertEqual(MeetingSourceScanner.meetBrandShape("Google Meet"), "meet_landing")
        XCTAssertEqual(MeetingSourceScanner.meetBrandShape("Meet the team - Placeholder Corp"), "meet_other")
        XCTAssertNil(MeetingSourceScanner.meetBrandShape("Meeting notes - Google Docs"), "a whole word only")
    }

    /// Item 5: a brand-bearing unadmitted window emits one `browser_identity` row with a shape and
    /// no title, and repeats are throttled.
    func test_browser_identity_rows_are_shape_only_and_throttled() throws {
        let sightings = [MeetingSourceScanner.BrowserBrandSighting(bundleID: "com.google.Chrome", shape: "meet_bare")]
        let first = MeetingDiscoveryWatcher.browserIdentityRows(sightings, lastSignature: nil)
        XCTAssertEqual(first.rows, sightings)
        let repeated = MeetingDiscoveryWatcher.browserIdentityRows(sightings + sightings, lastSignature: first.signature)
        XCTAssertTrue(repeated.rows.isEmpty, "the same (bundle, shape) set logs once")
        XCTAssertNil(MeetingDiscoveryWatcher.browserIdentityRows([], lastSignature: first.signature).signature)

        let fm = FileManager.default
        let logs = fm.temporaryDirectory.appendingPathComponent("mp-det17-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: logs) }
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }
        MeetingDiscoveryWatcher.logBrowserIdentity(first.rows)
        let rows = try String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["action"] as? String == "browser_identity" }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["category"] as? String, "detector")
        XCTAssertEqual(rows.first?["shape"] as? String, "meet_bare")
        XCTAssertEqual(rows.first?["admitted"] as? Bool, false)
        XCTAssertNil(rows.first?["title"], "never a title")
    }
}
