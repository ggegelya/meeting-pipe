import Foundation
import XCTest
@testable import MeetingPipe

/// FEAT15's maintenance story, as a suite (the task's own bar: "If the answer is
/// 'a human notices', the shape is wrong").
///
/// A tour that drives the real UI is a set of claims about controls that exist,
/// are called what the narration says they are called, and live where it says
/// they live. Those claims rot the way DOC7's and DOC9's stale sentences did,
/// except a stale tour cannot be grepped by a reader, only seen by someone
/// running it and paying attention. So each claim is checked here instead:
///
/// | Goes stale | Caught by |
/// | --- | --- |
/// | The control is deleted | its `.tutorialAnchor(...)` goes with it, so the anchor is unattached |
/// | The control is renamed | the literal in `namedIn` no longer matches the anchor's `control` |
/// | Narration re-spells a name | prose repeating its own anchor's control |
/// | A tour surface stops being openable | the window has no `.tutorialStage(...)`, or the presenter dropped a case |
/// | The anchor itself is deleted | the compiler, at every step that named it |
///
/// Source fences rather than a rendered view, for the reason `SummaryLayoutTests`
/// and `PreferencesSurfaceTests` are: SwiftUI offers no runtime read of which
/// view a modifier was applied to, and none of this is observable from a
/// constructed view. Everything below runs on the checkout, which is where the
/// claims are written.
final class TutorialFenceTests: XCTestCase {

    // MARK: - Reading the tree

    private static let sourceRoot = "daemon/Sources/MeetingPipe"

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
            .deletingLastPathComponent()   // repo root
    }

    private func repoFile(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Every Swift file in the app target, by repo-relative path.
    private func daemonSources() throws -> [String: String] {
        let root = repoRoot().appendingPathComponent(Self.sourceRoot)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            XCTFail("cannot walk \(Self.sourceRoot)")
            return [:]
        }
        var out: [String: String] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            let name = url.path.replacingOccurrences(of: repoRoot().path + "/", with: "")
            out[name] = try String(contentsOf: url, encoding: .utf8)
        }
        XCTAssertGreaterThan(out.count, 100, "the walk found almost nothing; re-point this fence")
        return out
    }

    /// The same source with whole-line comments dropped, so a fence that asks
    /// whether the app *says* something cannot be satisfied by a comment
    /// describing it. `PreferencesView+Permissions.swift` carries a comment
    /// reading "Regulated mode lives here", which is exactly the false pass this
    /// avoids.
    private func code(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = haystack.startIndex ..< haystack.endIndex
        while let found = haystack.range(of: needle, range: range) {
            count += 1
            range = found.upperBound ..< haystack.endIndex
        }
        return count
    }

    /// Whether `phrase` appears in `text` as itself rather than inside a longer
    /// word. "Record" must not match "Recording": the fence is about the control's
    /// name being spelled, not about the topic being discussed.
    private func mentions(_ phrase: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("bad pattern for \(phrase)")
            return false
        }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - The control is still there

    /// The deletion case, which is the one the task named first. A control that
    /// is removed takes its `.tutorialAnchor(...)` with it, because the modifier
    /// is written on the control rather than kept in a list beside it. There is
    /// then no attachment for the anchor, and this fails.
    func test_every_anchor_is_attached_to_a_control_in_the_file_it_names() throws {
        let sources = try daemonSources()
        for anchor in TutorialAnchor.allCases {
            let call = ".tutorialAnchor(.\(anchor.rawValue))"
            guard let source = sources[anchor.home.attachedIn] else {
                XCTFail("\(anchor.rawValue) names \(anchor.home.attachedIn), which is not in the target")
                continue
            }
            XCTAssertTrue(code(source).contains(call),
                          "\(anchor.home.attachedIn) no longer attaches \(anchor.rawValue): the control it pointed at is gone or moved")
        }
    }

    /// And exactly once, anywhere. Two controls claiming one anchor is a tour
    /// pointing at whichever of them laid out last, which is not a state anybody
    /// would debug from the symptom.
    func test_no_anchor_is_attached_twice() throws {
        let sources = try daemonSources()
        for anchor in TutorialAnchor.allCases {
            let call = ".tutorialAnchor(.\(anchor.rawValue))"
            let total = sources.values.reduce(0) { $0 + occurrences(of: call, in: code($1)) }
            XCTAssertEqual(total, 1, "\(anchor.rawValue) is attached \(total) times; exactly one control may claim it")
        }
    }

    // MARK: - The control is still called that

    /// The rename case. The tour speaks a control's name, so the name it speaks
    /// has to be a string the window actually renders. Checked against the
    /// quoted literal in the file that renders it, with comments stripped, so a
    /// prose mention cannot stand in for the label.
    func test_every_anchor_names_a_string_its_control_still_renders() throws {
        let sources = try daemonSources()
        for anchor in TutorialAnchor.allCases {
            guard let source = sources[anchor.home.namedIn] else {
                XCTFail("\(anchor.rawValue) names \(anchor.home.namedIn), which is not in the target")
                continue
            }
            XCTAssertTrue(code(source).contains("\"\(anchor.control)\""),
                          "\(anchor.home.namedIn) no longer spells \"\(anchor.control)\"; the tour is naming a control the app renamed")
        }
    }

    /// And the other half of one-home-per-name: the narration never re-spells it.
    /// The card renders `anchor.control`, so a rename is one edit in
    /// `TutorialAnchor`. Prose that repeated the label would be a second copy,
    /// which is how `SummarizationEngine` and `PublishLanding` came to exist
    /// (UX31, UX49).
    func test_no_step_re_spells_the_control_it_points_at() {
        for step in TutorialScript.steps {
            let name = step.anchor.control
            XCTAssertFalse(mentions(name, in: step.headline),
                           "step \(step.anchor.rawValue) spells its own control in the headline; the card already renders it")
            XCTAssertFalse(mentions(name, in: step.body),
                           "step \(step.anchor.rawValue) spells its own control in the body; the card already renders it")
        }
    }

    // MARK: - The surface can still be reached

    /// A step is only pointable if its window carries a stage. Both windows are
    /// checked, not only the ones a step happens to use today, so adding a case
    /// to `TutorialWindow` without wiring it is a red suite rather than a tour
    /// that dims nothing.
    func test_every_window_carries_exactly_one_stage() throws {
        let sources = try daemonSources()
        for window in TutorialWindow.allCases {
            let call = ".tutorialStage(.\(window.rawValue))"
            let total = sources.values.reduce(0) { $0 + occurrences(of: call, in: code($1)) }
            XCTAssertEqual(total, 1, "\(window.rawValue) has \(total) stages; a window hosts exactly one")
        }
    }

    /// The presenter answers every surface. The compiler already forces the
    /// switch to be exhaustive, so what this adds is that it stayed exhaustive
    /// *by case* rather than by growing a `default:` that quietly does nothing
    /// for a surface added later.
    func test_the_presenter_answers_each_surface_by_name() throws {
        let actions = code(try repoFile("daemon/Sources/MeetingPipe/Coordinator+MenuActions.swift"))
        guard let start = actions.range(of: "func presentTutorialSurface("),
              let end = actions.range(of: "\n    }", range: start.upperBound ..< actions.endIndex) else {
            return XCTFail("presentTutorialSurface no longer has the shape this fence reads; re-point it")
        }
        let body = String(actions[start.upperBound ..< end.lowerBound])
        for surface in TutorialSurface.allCases {
            XCTAssertTrue(body.contains("case .\(surface.rawValue):"),
                          "the presenter has no branch for \(surface.rawValue)")
        }
        XCTAssertFalse(body.contains("default:"),
                       "a default branch would swallow the next surface added instead of failing to compile")
    }

    func test_the_tour_is_reachable_from_the_menu_bar() throws {
        let statusBar = code(try repoFile("daemon/Sources/MeetingPipe/StatusBarController.swift"))
        XCTAssertTrue(statusBar.contains("#selector(Coordinator.menuOpenTutorial)"))
        XCTAssertTrue(statusBar.contains("\"Tutorial…\""),
                      "the menu row is the tour's only entry point")
    }

    // MARK: - It is not a first-run wizard

    /// The scope boundary the reversal was granted under, as a fence rather than
    /// as a promise in a comment. The root `CLAUDE.md` still defers first-run
    /// tours; what it now carves out is a tour someone opens on purpose. The
    /// difference is entirely that the tour is started from a menu action and
    /// from nowhere else, so nothing on a launch path may start one.
    func test_nothing_on_a_launch_path_starts_the_tour() throws {
        let sources = try daemonSources()
        let starters = sources
            .filter { code($0.value).contains("TutorialSession.shared.start(") }
            .keys
            .sorted()
        XCTAssertEqual(starters, ["daemon/Sources/MeetingPipe/Coordinator+MenuActions.swift"],
                       "the tour starts from the menu action and nowhere else")

        for launchPath in ["daemon/Sources/MeetingPipe/App.swift",
                           "daemon/Sources/MeetingPipe/Coordinator.swift",
                           "daemon/Sources/MeetingPipe/Onboarding/OnboardingWindow.swift"] {
            guard let source = sources[launchPath] else {
                XCTFail("\(launchPath) is not in the target; re-point this fence")
                continue
            }
            XCTAssertFalse(code(source).contains("TutorialSession"),
                           "\(launchPath) is a launch path; a tour that runs from one is the wizard the deferral still covers")
        }
    }

    /// The same boundary stated where the rule lives, so the repo and the rule
    /// cannot disagree. FEAT15's acceptance requires the amendment to land with
    /// the first code; this is what stops a later edit quietly widening it back
    /// into the deferred list.
    func test_the_root_claude_md_carves_the_tutorial_out_and_keeps_the_rest_deferred() throws {
        let claude = try repoFile("CLAUDE.md")
        XCTAssertTrue(claude.contains("FEAT15"),
                      "the carve-out names the task that opened it")
        XCTAssertTrue(claude.contains("Tutorial…"),
                      "the carve-out names the one surface it covers")
        for stillDeferred in ["first-run wizards", "coach marks", "videos", "a hosted docs site"] {
            XCTAssertTrue(claude.contains(stillDeferred),
                          "\(stillDeferred) must stay named as deferred; the carve-out is one surface, not the list")
        }
    }

    // MARK: - Register

    /// The tour is product copy, so it answers to `PRODUCT.md` like every other
    /// string in the app: no em-dash anywhere in the repo, and no exclamation
    /// marks ever ("Successfully published your summary!" is the named anti-goal).
    func test_the_narration_holds_the_products_register() {
        for step in TutorialScript.steps {
            for text in [step.headline, step.body] {
                XCTAssertFalse(text.contains("\u{2014}"), "em-dash in tutorial copy: \(text)")
                XCTAssertFalse(text.contains("!"), "no exclamation marks in product copy: \(text)")
            }
            XCTAssertFalse(step.headline.isEmpty)
            XCTAssertFalse(step.body.isEmpty)
        }
    }

    /// DSN3, applied to the new surface at the same strictness CI applies to a
    /// diff. The tokens are in `Design/Tokens.swift`; a tour is not the place a
    /// raw font size gets reintroduced.
    func test_the_tutorial_surface_uses_type_tokens() throws {
        let sources = try daemonSources()
        for (path, source) in sources where path.contains("/Tutorial/") {
            XCTAssertFalse(code(source).contains(".system(size:"),
                           "\(path) sets a raw font size; use an MPType token or a Dynamic-Type font")
        }
    }
}
