import XCTest
@testable import MeetingPipe

/// AUTO4: the drift fence between the in-app automation reference and the parser
/// it documents.
///
/// The reference exists because the `meetingpipe://` verbs had no in-app
/// documentation at all. A list that can go stale silently would be worse than
/// that, since it teaches a URL that quietly does nothing, so it is pinned both
/// ways, the way `MeetingPipeAppIntentsTests` pins the native intents' URLs:
///
/// - forward, `test_every_listed_template_parses_to_the_command_it_claims`:
///   every template a row displays parses, and lands on the command that row
///   claims. A renamed verb, a dropped query key, or a typo fails here.
/// - back, `test_every_command_the_parser_can_produce_is_listed`: every case of
///   `AutomationCommand` has a row. The switch inside it is exhaustive with no
///   `default`, so adding a case to the enum cannot compile until somebody opens
///   this file; the paragraph on `everyCommand` is what they read when they get
///   here, and `test_the_list_is_one_row_per_command` fails the moment the two
///   lists stop being the same length.
///
/// What that does not buy is a compiler proof that `everyCommand` grew: a case
/// added to the switch arm below with no matching sample would pass. Closing
/// that last inch would mean giving the parser a `CaseIterable` verb enum beside
/// `AutomationCommand.verb`, whose exact strings are the shipped event-log
/// vocabulary; the cost of touching those outweighs the inch (AUTO4).
final class AutomationReferenceTests: XCTestCase {

    /// One sample per command the router can be handed, including both sides of
    /// the `byo` flag, since `AutomationCommand.verb` tells them apart and the
    /// reference gives each its own row.
    ///
    /// **Adding a case to `AutomationCommand` means adding a sample here**, not
    /// only an arm to the switch that sent you to this file. The row count pin
    /// below is the runtime half of that reminder.
    private static let everyCommand: [AutomationCommand] = [
        .record(byo: false),
        .record(byo: true),
        .stop,
        .toggle,
        .openLibrary(scope: nil),
        .openMeeting(stem: "2026-01-14-1000-standup", seek: 42),
        .ask(question: "what did we decide"),
        .digest,
    ]

    // MARK: - Forward: the list cannot show a URL that does not work

    func test_every_listed_template_parses_to_the_command_it_claims() {
        for row in AutomationReference.rows {
            guard let url = URL(string: row.template) else {
                XCTFail("\(row.template) is not a URL at all, so the copy button hands out a dead string")
                continue
            }
            XCTAssertEqual(AutomationCommand.parse(url), row.command,
                           "\(row.template) does not do what its row says it does")
        }
    }

    func test_every_template_uses_the_scheme_the_app_registers() {
        for row in AutomationReference.rows {
            XCTAssertEqual(URL(string: row.template)?.scheme, AutomationCommand.scheme,
                           "\(row.template) is not on the registered scheme")
        }
    }

    // MARK: - Back: the parser cannot accept a verb the list omits

    func test_every_command_the_parser_can_produce_is_listed() {
        for command in Self.everyCommand {
            // Exhaustive on purpose, with no `default`: adding a case to
            // `AutomationCommand` breaks this compile, which is the only thing
            // that forces `everyCommand` above to keep up with the enum. Without
            // it, a new verb could ship undocumented and every test still pass.
            switch command {
            case .record, .stop, .toggle, .openLibrary, .openMeeting, .ask, .digest:
                XCTAssertTrue(
                    AutomationReference.rows.contains { $0.command.verb == command.verb },
                    "the parser produces \(command.verb) but no row documents it")
            }
        }
    }

    /// The parser also takes spellings that are not verbs of their own: `start`
    /// for `record`, a bare `byo`, and `open` as a synonym of `library`. Those
    /// need no row (the list is one row per verb, not per spelling), but each has
    /// to land on something the list documents, so an alias can never be the only
    /// route to a capability.
    func test_the_parser_aliases_land_on_listed_commands() {
        for alias in ["meetingpipe://start",
                      "meetingpipe://byo",
                      "meetingpipe://open",
                      "meetingpipe://library?scope=facts"] {
            guard let url = URL(string: alias), let command = AutomationCommand.parse(url) else {
                XCTFail("\(alias) no longer parses; re-point this fence")
                continue
            }
            XCTAssertTrue(AutomationReference.rows.contains { $0.command.verb == command.verb },
                          "\(alias) reaches \(command.verb), which the reference does not list")
        }
    }

    // MARK: - The list's own shape

    /// The template is the row's identity (the `ForEach` id and the copy
    /// payload), so a duplicate would render two rows nobody can tell apart and
    /// lose one of them to SwiftUI's id collision. Two rows on one verb is the
    /// same problem read from the other end.
    func test_templates_and_verbs_are_unique() {
        let templates = AutomationReference.rows.map(\.template)
        XCTAssertEqual(Set(templates).count, templates.count, "duplicate template in the reference")
        let verbs = AutomationReference.rows.map(\.command.verb)
        XCTAssertEqual(Set(verbs).count, verbs.count, "two rows document the same verb")
    }

    /// One row per verb, and no verb without a row, counted rather than sampled.
    /// This is what catches the half of a new-verb change that the exhaustive
    /// switch cannot: a row added with no sample, or a sample with no row.
    func test_the_list_is_one_row_per_command() {
        XCTAssertEqual(AutomationReference.rows.count, Self.everyCommand.count,
                       "the reference and the command list have drifted apart; one of them is missing a verb")
    }

    /// Every row has to carry its one line. An empty purpose renders as a bare
    /// URL, which is the README-with-worse-formatting the group exists to beat.
    func test_every_row_carries_a_purpose() {
        for row in AutomationReference.rows {
            XCTAssertFalse(row.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(row.template) has no purpose line")
        }
    }

    // MARK: - The copy button

    /// The row hands the pasteboard its template verbatim, so what lands on the
    /// clipboard is the string the fence above proved works. Run against a
    /// scratch pasteboard: a test has no business overwriting what the owner
    /// last copied.
    func test_copying_a_row_puts_its_template_on_the_pasteboard() throws {
        let scratch = NSPasteboard(name: NSPasteboard.Name("mp.auto4.tests"))
        defer { scratch.releaseGlobally() }
        for row in AutomationReference.rows {
            row.copyTemplate(to: scratch)
            XCTAssertEqual(scratch.string(forType: .string), row.template,
                           "copying \(row.template) put something else on the pasteboard")
        }
    }

    // MARK: - The pane renders the fenced list, not a second copy

    /// The fence above is only worth anything where the pane renders *from*
    /// `AutomationReference.rows`. A hand-written row in the view would be a
    /// second copy of the vocabulary, which is exactly the failure this file
    /// exists to prevent. SwiftUI content is not observable headlessly, so this
    /// is pinned in source, the way `SummaryLayoutTests` pins the tab underline.
    func test_the_advanced_pane_renders_the_reference_rather_than_its_own_list() throws {
        let pane = try daemonSource("Sources/MeetingPipe/Preferences/PreferencesView+Advanced.swift")
        XCTAssertTrue(pane.contains("AutomationReference.rows"),
                      "the Automation group must render AutomationReference.rows")
        XCTAssertFalse(pane.contains("\(AutomationCommand.scheme)://"),
                       "a URL literal in the pane is a second copy of the vocabulary; it belongs in AutomationReference")
    }

    /// Source of a file in the daemon target.
    private func daemonSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
