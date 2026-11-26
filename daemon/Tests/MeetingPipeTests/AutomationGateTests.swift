import XCTest
@testable import MeetingPipe

/// AUTO7: a `meetingpipe://` link's state-changing verbs ask first; in-app callers and UI-only verbs
/// do not. Driven through `AutomationRouter` with a fake confirm presenter, so no panel appears and
/// no `Coordinator` is needed.
final class AutomationGateTests: XCTestCase {
    private let gated: [AutomationCommand] = [.toggle, .record(byo: false), .record(byo: true), .stop, .digest]
    private let ungated: [AutomationCommand] = [
        .openLibrary(scope: nil), .openLibrary(scope: "ask"), .openMeeting(stem: "s", seek: 1), .ask(question: "q"),
    ]

    private var logs: URL!

    override func setUpWithError() throws {
        logs = FileManager.default.temporaryDirectory.appendingPathComponent("mp-auto7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDown() {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: logs)
    }

    private func rows(_ action: String) -> [[String: Any]] {
        ((try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["action"] as? String == action }
    }

    /// A presenter that records each request and holds its completion until the test answers.
    private final class FakePresenter {
        var requests: [AutomationConfirmation] = []
        var pending: ((Bool) -> Void)?
        func confirm(_ request: AutomationConfirmation, _ completion: @escaping (Bool) -> Void) {
            requests.append(request)
            pending = completion
        }
    }

    func test_each_gated_url_verb_waits_for_the_confirm_and_runs_on_accept() {
        for command in gated {
            let presenter = FakePresenter()
            let router = AutomationRouter(confirm: presenter.confirm)
            var performed = 0
            router.route(command, source: AutomationGate.urlSource, isRecording: { false }) { performed += 1 }
            XCTAssertEqual(presenter.requests.map(\.verb), [command.verb], "\(command)")
            XCTAssertEqual(performed, 0, "\(command) must not act before the confirm")
            presenter.pending?(true)
            XCTAssertEqual(performed, 1, "\(command) acts once accepted")
            XCTAssertFalse(router.isConfirming)
        }
    }

    func test_declining_performs_nothing_and_logs_command_declined() {
        for command in gated {
            let presenter = FakePresenter()
            let router = AutomationRouter(confirm: presenter.confirm)
            var performed = 0
            router.route(command, source: AutomationGate.urlSource, isRecording: { true }) { performed += 1 }
            presenter.pending?(false)
            XCTAssertEqual(performed, 0, "\(command)")
        }
        XCTAssertEqual(rows("command_declined").compactMap { $0["verb"] as? String },
                       gated.map(\.verb))
    }

    func test_an_in_app_source_acts_at_once_without_a_confirm() {
        for command in gated + ungated {
            let presenter = FakePresenter()
            let router = AutomationRouter(confirm: presenter.confirm)
            var performed = 0
            router.route(command, source: "quick_find", isRecording: { false }) { performed += 1 }
            XCTAssertTrue(presenter.requests.isEmpty, "\(command)")
            XCTAssertEqual(performed, 1, "\(command)")
        }
    }

    func test_ui_only_verbs_and_ask_never_present_the_confirm_from_a_url() {
        for command in ungated {
            let presenter = FakePresenter()
            let router = AutomationRouter(confirm: presenter.confirm)
            var performed = 0
            router.route(command, source: AutomationGate.urlSource, isRecording: { false }) { performed += 1 }
            XCTAssertTrue(presenter.requests.isEmpty, "\(command)")
            XCTAssertEqual(performed, 1, "\(command)")
        }
    }

    /// A second gated link while the panel is up is dropped and logged, never stacked.
    func test_a_second_link_while_a_confirm_is_open_is_dropped() {
        let presenter = FakePresenter()
        let router = AutomationRouter(confirm: presenter.confirm)
        var performed: [String] = []
        router.route(.stop, source: AutomationGate.urlSource, isRecording: { true }) { performed.append("stop") }
        router.route(.toggle, source: AutomationGate.urlSource, isRecording: { true }) { performed.append("toggle") }
        XCTAssertEqual(presenter.requests.count, 1)
        XCTAssertEqual(rows("command_dropped").first?["verb"] as? String, "toggle")
        presenter.pending?(true)
        XCTAssertEqual(performed, ["stop"])
    }

    /// AUTO7 amendment (2026-11-21, M2): a toggle link that arrived while idle asks to start; a
    /// recording that began while the panel waited must not be stopped by accepting it.
    func test_a_toggle_decided_as_start_does_nothing_if_a_recording_began_before_accept() {
        let presenter = FakePresenter()
        let router = AutomationRouter(confirm: presenter.confirm)
        var recording = false
        var performed = 0
        router.route(.toggle, source: AutomationGate.urlSource, isRecording: { recording }) { performed += 1 }
        XCTAssertEqual(presenter.requests.first?.actionTitle, "Start Recording")
        recording = true
        presenter.pending?(true)
        XCTAssertEqual(performed, 0, "accepting a stale Start must not stop the live recording")
        XCTAssertFalse(router.isConfirming)
        XCTAssertEqual(rows("command_stale").map { $0["decided"] as? String }, ["start"])
        XCTAssertTrue(rows("command_confirmed").isEmpty, "the stale row is the one terminal row")
    }

    /// The reverse: a stop decided at arrival must not start a new recording after the meeting ended.
    func test_a_toggle_decided_as_stop_does_nothing_if_the_recording_ended_before_accept() {
        let presenter = FakePresenter()
        let router = AutomationRouter(confirm: presenter.confirm)
        var recording = true
        var performed = 0
        router.route(.toggle, source: AutomationGate.urlSource, isRecording: { recording }) { performed += 1 }
        XCTAssertEqual(presenter.requests.first?.actionTitle, "Stop Recording")
        recording = false
        presenter.pending?(true)
        XCTAssertEqual(performed, 0, "accepting a stale Stop must not start a recording")
        XCTAssertFalse(router.isConfirming)
        XCTAssertEqual(rows("command_stale").map { $0["decided"] as? String }, ["stop"])
        XCTAssertTrue(rows("command_confirmed").isEmpty, "the stale row is the one terminal row")
    }

    /// The arrival decision is what `toggleManual` would do, not idle-or-not: a prompt starts
    /// (attached), and a start in flight is cancelled, which is a stop.
    func test_toggle_stops_matches_what_toggleManual_would_do() {
        let teams = AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams")
        let file = URL(fileURLWithPath: "/tmp/x.wav")
        XCTAssertFalse(AutomationGate.toggleStops(.idle, startInFlight: false))
        XCTAssertFalse(AutomationGate.toggleStops(.prompting(source: teams), startInFlight: false))
        XCTAssertFalse(AutomationGate.toggleStops(.suppressed(source: teams), startInFlight: false))
        XCTAssertTrue(AutomationGate.toggleStops(.recording(file: file, source: nil, summaryMode: .auto), startInFlight: false))
        XCTAssertTrue(AutomationGate.toggleStops(.stopping(file: file, source: nil, summaryMode: .auto), startInFlight: false))
        XCTAssertTrue(AutomationGate.toggleStops(.idle, startInFlight: true))
        XCTAssertTrue(AutomationGate.toggleStops(.prompting(source: teams), startInFlight: true))
    }

    func test_the_toggle_confirm_names_what_it_will_do() {
        let stop = AutomationGate.confirmation(for: .toggle, source: AutomationGate.urlSource, isRecording: true)
        let start = AutomationGate.confirmation(for: .toggle, source: AutomationGate.urlSource, isRecording: false)
        XCTAssertEqual(stop?.actionTitle, "Stop Recording")
        XCTAssertEqual(start?.actionTitle, "Start Recording")
        XCTAssertTrue(stop?.message.hasPrefix("A link asked MeetingPipe") ?? false)
    }

    func test_a_url_ask_prefills_and_an_in_app_ask_runs() {
        XCTAssertFalse(AutomationGate.asksRun(source: AutomationGate.urlSource))
        XCTAssertTrue(AutomationGate.asksRun(source: "quick_find"))
    }
}
