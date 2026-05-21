import XCTest
@testable import MeetingPipeCore

final class ShareableContentSignalTests: XCTestCase {

    typealias Summary = ShareableContentSignal.ShareableWindowSummary

    private let teamsContext = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2",
        kind: .native,
        pid: 1234
    )

    private func manualScheduler(_ store: ManualScheduler) -> ShareableContentSignal.Scheduler {
        return { interval, action in
            store.lastInterval = interval
            store.tick = action
            return { store.tick = nil }
        }
    }

    final class ManualScheduler {
        var tick: (() -> Void)?
        var lastInterval: TimeInterval = 0
    }

    func test_window_present_when_bundle_matches() {
        let scheduler = ManualScheduler()
        var observed: [Bool] = []
        let signal = ShareableContentSignal(
            probe: {
                [Summary(bundleIdentifier: "com.microsoft.teams2", title: "Standup | Meeting")]
            },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        signal.start(context: teamsContext)
        XCTAssertEqual(observed, [true])
        XCTAssertEqual(signal.lastValue, true)
    }

    func test_window_absent_when_bundle_does_not_match() {
        let scheduler = ManualScheduler()
        var observed: [Bool] = []
        let signal = ShareableContentSignal(
            probe: {
                [Summary(bundleIdentifier: "us.zoom.xos", title: "Zoom")]
            },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        signal.start(context: teamsContext)
        XCTAssertEqual(observed, [false])
    }

    func test_title_match_filters_chat_threads() {
        let scheduler = ManualScheduler()
        var observed: [Bool] = []
        let signal = ShareableContentSignal(
            probe: {
                [Summary(bundleIdentifier: "com.microsoft.teams2", title: "Chat - Acme")]
            },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        signal.start(context: teamsContext) { title in
            (title ?? "").lowercased().contains("meeting")
        }
        XCTAssertEqual(observed, [false])
    }

    func test_present_transitions_to_absent_when_window_closes() {
        let scheduler = ManualScheduler()
        var windows: [Summary] = [
            Summary(bundleIdentifier: "com.microsoft.teams2", title: "Standup")
        ]
        var observed: [Bool] = []
        let signal = ShareableContentSignal(
            probe: { windows },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        signal.start(context: teamsContext)
        windows = []
        scheduler.tick?()
        XCTAssertEqual(observed, [true, false])
    }

    func test_cadence_switches_between_active_and_idle() {
        let scheduler = ManualScheduler()
        var windows: [Summary] = []
        let signal = ShareableContentSignal(
            probe: { windows },
            scheduler: manualScheduler(scheduler),
            activeInterval: 0.5,
            idleInterval: 1.0
        )

        signal.start(context: teamsContext)
        XCTAssertEqual(scheduler.lastInterval, 1.0, "Starts on idle cadence until a window is present")

        windows = [Summary(bundleIdentifier: "com.microsoft.teams2", title: "Standup")]
        scheduler.tick?()
        XCTAssertEqual(scheduler.lastInterval, 0.5, "Switches to active cadence once a window is present")

        windows = []
        scheduler.tick?()
        XCTAssertEqual(scheduler.lastInterval, 1.0, "Returns to idle when window disappears")
    }

    func test_nil_probe_logs_unavailable_without_flapping() {
        let log = RecordingEventLog()
        let scheduler = ManualScheduler()
        var observed: [Bool] = []
        var probeReturn: [Summary]? = [Summary(bundleIdentifier: "com.microsoft.teams2", title: "Meeting")]
        let signal = ShareableContentSignal(
            eventLog: log,
            probe: { probeReturn },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        signal.start(context: teamsContext)
        probeReturn = nil
        scheduler.tick?()

        XCTAssertEqual(observed, [true])
        XCTAssertTrue(log.entries.contains { $0.action == "shareable_content_unavailable" })
    }

    func test_no_match_logs_candidate_titles_for_diagnosis() {
        let log = RecordingEventLog()
        let scheduler = ManualScheduler()
        let signal = ShareableContentSignal(
            eventLog: log,
            probe: {
                [Summary(bundleIdentifier: "com.microsoft.teams2", title: "Chat - Acme")]
            },
            scheduler: manualScheduler(scheduler)
        )

        signal.start(context: teamsContext) { title in
            (title ?? "").lowercased().contains("meeting")
        }

        XCTAssertTrue(
            log.entries.contains { $0.action == "shareable_content_no_match" },
            "A bundle-owned window that fails the title match is logged for diagnosis"
        )
    }
}
