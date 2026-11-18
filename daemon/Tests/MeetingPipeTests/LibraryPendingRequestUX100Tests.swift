import XCTest
@testable import MeetingPipe

/// UX100: a Quick Find pick, a failure-notification click or a `meetingpipe://library`,
/// `ask` or `digest` link that reaches a Library window not yet built used to be dropped,
/// because `LibraryRootView` read `pendingSelection` and `pendingScope` only in `onChange`.
/// The decision is pure here; the fences below pin that the root applies it on appear and
/// clears both values on every attempt.
final class LibraryPendingRequestUX100Tests: XCTestCase {

    // MARK: - The decision

    func test_nothing_pending_changes_nothing() {
        XCTAssertNil(LibraryPendingRequest.decide(pendingScope: nil, pendingSelection: nil, hasPendingAsk: false))
        XCTAssertNil(LibraryPendingRequest.decide(pendingScope: nil, pendingSelection: nil, hasPendingAsk: true),
                     "a pending Ask alone is AskView's to consume, not the root's to drop")
    }

    /// Quick Find's Enter and the failure-notification click both go through
    /// `Coordinator.openMeeting(stem:)`, which sets `pendingSelection` before `show()`.
    func test_a_cold_open_selection_lands_on_all_meetings_with_that_stem() {
        let r = LibraryPendingRequest.decide(pendingScope: nil, pendingSelection: "2026-11-01_1000", hasPendingAsk: false)
        XCTAssertEqual(r, LibraryPendingRequest(scope: .allMeetings, selection: "2026-11-01_1000", dropsPendingAsk: false))
    }

    func test_a_scope_link_lands_on_that_rail() {
        for scope in [LibraryScope.facts, .people, .stats, .digests, .ask] {
            let r = LibraryPendingRequest.decide(pendingScope: scope, pendingSelection: nil, hasPendingAsk: false)
            XCTAssertEqual(r?.scope, scope)
            XCTAssertNil(r?.selection)
            XCTAssertEqual(r?.dropsPendingAsk, false)
        }
    }

    /// Quick Find's Cmd+Return sets the `.ask` scope and then the question: the question is
    /// left for `AskView` to run once it mounts.
    func test_an_ask_scope_keeps_its_question() {
        let r = LibraryPendingRequest.decide(pendingScope: .ask, pendingSelection: nil, hasPendingAsk: true)
        XCTAssertEqual(r, LibraryPendingRequest(scope: .ask, selection: nil, dropsPendingAsk: false))
    }

    /// The backstop: an Ask request superseded by a later scope must not run on its own the
    /// next time the owner happens to open the Ask rail.
    func test_a_superseded_ask_question_is_dropped() {
        XCTAssertEqual(
            LibraryPendingRequest.decide(pendingScope: .facts, pendingSelection: nil, hasPendingAsk: true)?.dropsPendingAsk,
            true)
        XCTAssertEqual(
            LibraryPendingRequest.decide(pendingScope: .ask, pendingSelection: "s", hasPendingAsk: true)?.dropsPendingAsk,
            true, "a meeting picked after the Ask request lands on All meetings, so the question is orphaned")
    }

    /// Scope first, then selection: a selection forces All meetings.
    func test_a_selection_wins_over_a_scope_in_the_same_turn() {
        let r = LibraryPendingRequest.decide(pendingScope: .facts, pendingSelection: "s", hasPendingAsk: false)
        XCTAssertEqual(r?.scope, .allMeetings)
        XCTAssertEqual(r?.selection, "s")
    }

    // MARK: - The model's take (read, clear, decide)

    private func headlessModel() throws -> LibraryWindowModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ux100-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return LibraryWindowModel(recordingsDir: dir, savedSearchesURL: dir.appendingPathComponent("searches.json"))
    }

    /// A cold open: the caller set the stem before the view existed; the first take selects
    /// it and leaves the model clear.
    func test_take_selects_and_clears_the_pending_selection() throws {
        let model = try headlessModel()
        model.pendingSelection = "2026-11-01_1000"
        XCTAssertEqual(model.takePendingRequest()?.selection, "2026-11-01_1000")
        XCTAssertNil(model.pendingSelection)
        XCTAssertNil(model.takePendingRequest(), "a second appear with nothing new pending changes nothing")
    }

    /// The same stem twice in a row: the take cleared the first, so the second is a fresh value.
    func test_the_same_stem_twice_selects_it_both_times() throws {
        let model = try headlessModel()
        model.pendingSelection = "s"
        XCTAssertEqual(model.takePendingRequest()?.selection, "s")
        model.pendingSelection = "s"
        XCTAssertEqual(model.takePendingRequest()?.selection, "s")
        XCTAssertNil(model.pendingSelection)
    }

    func test_take_lands_a_scope_link_and_clears_it() throws {
        let model = try headlessModel()
        model.pendingScope = .facts
        XCTAssertEqual(model.takePendingRequest()?.scope, .facts)
        XCTAssertNil(model.pendingScope)
        model.pendingScope = .facts
        XCTAssertEqual(model.takePendingRequest()?.scope, .facts, "a repeat of the same scope is a fresh edge")
    }

    /// Quick Find's Cmd+Return: the Ask question stays for `AskView` to run once it mounts.
    func test_take_keeps_the_question_of_an_ask_request() throws {
        let model = try headlessModel()
        model.pendingScope = .ask
        model.pendingAsk = .init(question: "what did we decide", run: true)
        XCTAssertEqual(model.takePendingRequest()?.scope, .ask)
        XCTAssertEqual(model.pendingAsk?.question, "what did we decide")
    }

    func test_take_drops_an_ask_question_a_later_request_superseded() throws {
        let model = try headlessModel()
        model.pendingAsk = .init(question: "what did we decide", run: true)
        model.pendingScope = .facts
        XCTAssertEqual(model.takePendingRequest()?.scope, .facts)
        XCTAssertNil(model.pendingAsk, "the question would otherwise run on the next visit to Ask")
    }

    // MARK: - Wiring fences

    private func rootViewSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
        return try String(contentsOf: root.appendingPathComponent("Sources/MeetingPipe/LibraryWindow.swift"),
                          encoding: .utf8)
    }

    /// The cold open: the root's `onAppear` applies the pending request, so a value set
    /// before `LibraryWindow.show()` built the view is not lost.
    func test_the_root_applies_the_pending_request_on_appear() throws {
        let source = try rootViewSource()
        guard let appear = source.range(of: ".onAppear {\n            meetingStore.start()"),
              let disappear = source.range(of: ".onDisappear {", range: appear.upperBound..<source.endIndex) else {
            return XCTFail("LibraryRootView's onAppear no longer has this shape; re-point this fence")
        }
        let body = source[appear.upperBound..<disappear.lowerBound]
        XCTAssertTrue(body.contains("applyPendingRequest()"),
                      "a Quick Find, notification or scope request set before the window existed is dropped without this (UX100)")
    }

    /// Both changes route through the one consumer, and nothing else reads the two values.
    func test_both_changes_route_through_the_one_consumer() throws {
        let source = try rootViewSource()
        XCTAssertTrue(source.contains(".onChange(of: model.pendingSelection) { _, _ in applyPendingRequest() }"))
        XCTAssertTrue(source.contains(".onChange(of: model.pendingScope) { _, _ in applyPendingRequest() }"))
    }
}
