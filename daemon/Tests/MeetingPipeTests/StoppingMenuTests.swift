import XCTest
@testable import MeetingPipe

/// UX79: the menu read "MeetingPipe: Idle" and offered an inert Start Recording for the whole of a
/// stop.
///
/// The menu-bar title read "Stopping…" while the menu header one click below it read
/// "MeetingPipe: Idle", because `setStopping` handed `rebuildMenu` a literal `.idle`. That was
/// deliberate across three revisions and each one documented it, which is why the correction needed
/// a row rather than a drive-by.
///
/// The half nobody had recorded is that the `.idle` menu also carries a **Start Recording** row,
/// whose action reaches `MeetingSessionController.toggleManual`'s `.stopping` case, which is a bare
/// `break`. So the app offered a control that did nothing, said nothing and logged nothing, for the
/// length of the post-processing. That is usually seconds; REC13's watchdog records 52 minutes of it
/// on a real recording on 2026-08-14, where this menu was the only surface a user could consult.
///
/// Route A of the three the spec offered, which is its stated default: hand `rebuildMenu` the real
/// state. The header agrees with the title and `rows(_:)` takes its `default: break`, which is what
/// that switch's own comment already said it wanted for a flush.
final class StoppingMenuTests: XCTestCase {

    private typealias M = StatusBarModel

    private func stopping() -> AppState {
        .stopping(
            file: URL(fileURLWithPath: "/tmp/recordings/20260814-163455.wav"),
            source: AppSource(bundleID: "com.microsoft.teams2", displayName: "Teams"),
            summaryMode: .auto
        )
    }

    private func recording() -> AppState {
        .recording(
            file: URL(fileURLWithPath: "/tmp/recordings/20260814-163455.wav"),
            source: AppSource(bundleID: "com.microsoft.teams2", displayName: "Teams"),
            summaryMode: .auto
        )
    }

    // MARK: - The header agrees with the title

    /// The reported defect. Against `main` the header for a stopping session read
    /// "MeetingPipe: Idle", because `.idle` is what `setStopping` handed it.
    func test_the_menu_header_says_stopping_during_a_stop() {
        XCTAssertEqual(M.headerLabel(.init(state: stopping())), "MeetingPipe: Stopping…")
    }

    /// And it agrees with the title, which was already correct and is not what this task changed.
    func test_the_header_and_the_title_agree() {
        let title = M.title(.init(state: stopping()))
        let header = M.headerLabel(.init(state: stopping()))
        XCTAssertEqual(title, " Stopping…")
        XCTAssertTrue(
            header.contains("Stopping…"),
            "the header must not contradict the title one click above it: \(header) vs \(title)"
        )
    }

    /// `headerLabel`'s `.stopping` branch is no longer test-only, which the spec required either
    /// way: an unreachable branch is CI6's finding class. The queue suffix rides it like any other.
    func test_the_stopping_header_carries_the_queue_suffix_like_every_other_state() {
        XCTAssertEqual(
            M.headerLabel(.init(state: stopping(), queue: QueueActivity(depth: 2, isRunning: true))),
            "MeetingPipe: Stopping… · Processing (2)"
        )
    }

    // MARK: - No inert control mid-flush

    /// The half nobody recorded. `toggleManual`'s `.stopping` case is a bare `break`, so a Start row
    /// offered here is a control that does nothing at all.
    func test_no_transport_row_is_offered_during_a_stop() {
        let rows = M.rows(.init(state: stopping()))
        for row in rows {
            switch row {
            case .startRecording, .recordSuppressedMeeting, .stopRecording:
                return XCTFail("a stop offers no transport row; \(row) reaches a no-op")
            default:
                continue
            }
        }
    }

    /// The neighbouring states are untouched, so the fix is not a blanket removal.
    func test_the_neighbouring_states_keep_their_transport_rows() {
        XCTAssertTrue(
            M.rows(.init(state: .idle)).contains { if case .startRecording = $0 { return true }; return false },
            "idle still offers Start"
        )
        XCTAssertTrue(
            M.rows(.init(state: recording())).contains { if case .stopRecording = $0 { return true }; return false },
            "recording still offers Stop"
        )
    }

    /// Everything that is not the transport row still renders during a flush, so the menu is not
    /// blank: a failed-meeting row, a permission consequence and the quit row all survive.
    func test_the_rest_of_the_menu_survives_a_stop() {
        let rows = M.rows(.init(
            state: stopping(),
            microphone: .denied,
            failedMeetingCount: 2
        ))
        XCTAssertTrue(rows.contains { if case .permissionConsequence = $0 { return true }; return false })
        XCTAssertTrue(rows.contains { if case .failedMeetings = $0 { return true }; return false })
        XCTAssertFalse(rows.isEmpty)
    }

    // MARK: - The regression that actually recurs

    /// `setStopping` passed `.idle` deliberately three times over, each revision documenting it, so
    /// the thing to fence is the call itself rather than only its output. A later caller reverting
    /// to `.idle` would restore both halves of the defect with every test above still green,
    /// because those read the model rather than the controller.
    func test_setStopping_hands_the_menu_the_real_state() throws {
        let source = try repoFile("daemon/Sources/MeetingPipe/StatusBarController.swift")
        // Scoped to the function's own body rather than a byte count: the comment explaining why
        // this line is what it is runs to 975 characters, and a fence that a later comment can
        // silently push out of range is not a fence.
        let start = try XCTUnwrap(source.range(of: "func setStopping("), "setStopping is gone")
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }"), "setStopping's body has no end")
        let body = String(rest[..<end.lowerBound])
        XCTAssertTrue(
            body.contains("rebuildMenu(state: titleState)"),
            "setStopping must hand the menu the state the title is showing"
        )
        XCTAssertFalse(
            body.contains("rebuildMenu(state: .idle)"),
            "the literal .idle is the defect; it was passed deliberately three revisions running"
        )
    }

    private func repoFile(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
            .deletingLastPathComponent()   // repo root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
