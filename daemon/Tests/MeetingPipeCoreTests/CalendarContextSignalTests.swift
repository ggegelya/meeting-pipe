import XCTest
@testable import MeetingPipeCore

final class CalendarContextSignalTests: XCTestCase {

    private let teamsContext = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2",
        kind: .native,
        pid: 1234
    )

    private func manualScheduler(_ store: ManualScheduler) -> CalendarContextSignal.Scheduler {
        return { _, action in
            store.tick = action
            return { store.tick = nil }
        }
    }

    final class ManualScheduler { var tick: (() -> Void)? }

    func test_unknown_when_probe_returns_nil() {
        let scheduler = ManualScheduler()
        var observed: [CalendarContextSignal.State] = []
        let signal = CalendarContextSignal(
            probe: { _ in nil },
            scheduler: manualScheduler(scheduler),
            clock: { Date(timeIntervalSince1970: 0) }
        )
        signal.onChange = { observed.append($0) }

        signal.start(context: teamsContext)
        XCTAssertEqual(observed, [.unknown])
    }

    func test_within_schedule_when_clock_before_end_plus_hysteresis() {
        let scheduler = ManualScheduler()
        var observed: [CalendarContextSignal.State] = []
        let signal = CalendarContextSignal(
            probe: { _ in Date(timeIntervalSince1970: 1000) },
            scheduler: manualScheduler(scheduler),
            clock: { Date(timeIntervalSince1970: 500) },
            hysteresis: 60
        )
        signal.onChange = { observed.append($0) }

        signal.start(context: teamsContext)
        XCTAssertEqual(observed, [.withinSchedule])
    }

    func test_past_scheduled_end_when_clock_exceeds_end_plus_hysteresis() {
        let scheduler = ManualScheduler()
        var observed: [CalendarContextSignal.State] = []
        let signal = CalendarContextSignal(
            probe: { _ in Date(timeIntervalSince1970: 1000) },
            scheduler: manualScheduler(scheduler),
            clock: { Date(timeIntervalSince1970: 2000) },
            hysteresis: 60
        )
        signal.onChange = { observed.append($0) }

        signal.start(context: teamsContext)
        XCTAssertEqual(observed, [.pastScheduledEnd(buffer: 60)])
    }

    func test_state_transitions_emit_once_per_change() {
        let scheduler = ManualScheduler()
        var now = Date(timeIntervalSince1970: 500)
        var observed: [CalendarContextSignal.State] = []
        let signal = CalendarContextSignal(
            probe: { _ in Date(timeIntervalSince1970: 1000) },
            scheduler: manualScheduler(scheduler),
            clock: { now },
            hysteresis: 60
        )
        signal.onChange = { observed.append($0) }

        signal.start(context: teamsContext)
        now = Date(timeIntervalSince1970: 2000)
        scheduler.tick?()
        scheduler.tick?()

        XCTAssertEqual(observed, [.withinSchedule, .pastScheduledEnd(buffer: 60)])
    }
}
