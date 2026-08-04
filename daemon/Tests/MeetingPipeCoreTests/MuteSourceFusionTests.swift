import XCTest
@testable import MeetingPipeCore

/// MIC8: "log wins when present, AX carries when absent", as a rule you can read.
final class MuteSourceFusionRuleTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func test_a_log_reading_is_always_accepted() {
        XCTAssertTrue(MuteSourceFusion.accepts(source: .log, now: now, lastLogReadingAt: now))
        XCTAssertTrue(MuteSourceFusion.accepts(source: .log, now: now, lastLogReadingAt: nil))
    }

    /// The state every meeting starts in: the log is a transition stream, so until
    /// the first toggle only the AX read knows whether you joined muted.
    func test_ax_carries_when_the_log_has_never_spoken() {
        XCTAssertTrue(MuteSourceFusion.accepts(source: .ax, now: now, lastLogReadingAt: nil))
    }

    func test_ax_is_refused_while_a_log_reading_is_fresh() {
        XCTAssertFalse(MuteSourceFusion.accepts(
            source: .ax, now: now, lastLogReadingAt: now.addingTimeInterval(-1)
        ))
    }

    /// The one measured case that went against the log (an AX transition with no log
    /// line anywhere near it) is exactly what a fusion has to cover.
    func test_ax_carries_once_the_log_has_gone_quiet() {
        XCTAssertTrue(MuteSourceFusion.accepts(
            source: .ax, now: now,
            lastLogReadingAt: now.addingTimeInterval(-MuteSourceFusion.defaultLogFreshness - 0.001)
        ))
    }

    /// A backwards clock jump reads as "the log just spoke", which is the same side
    /// as the normal case rather than a sudden blind spot.
    func test_a_backwards_clock_jump_reads_as_fresh() {
        XCTAssertFalse(MuteSourceFusion.accepts(
            source: .ax, now: now, lastLogReadingAt: now.addingTimeInterval(600)
        ))
    }
}

final class MicGateMuteFusionTests: XCTestCase {

    private static let catalogue: MuteLabels = {
        try! MuteLabelsLoader.loadDefault()
    }()

    private let teams = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2", kind: .native, pid: 1234
    )

    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeGate(eventLog: EventLog = NoopEventLog(), adapters: [MicGateAdapter] = []) -> MicGate {
        MicGate(
            catalogue: Self.catalogue,
            halBus: CoreAudioHALBus(),
            axBus: AXObserverBus(),
            eventLog: eventLog,
            adapters: adapters,
            now: { [weak self] in self?.clock ?? Date() }
        )
    }

    /// With no log reading in play the AX path behaves exactly as it did before
    /// MIC8: this is the regression guard on the shipped oracle.
    func test_ax_alone_still_drives_the_verdict() {
        let gate = makeGate()
        defer { gate.shutdown() }
        gate.injectAxMuteEvent(AXMuteButtonProbe.Event(state: .muted, label: "Unmute", locale: "en"))
        drain()
        XCTAssertEqual(gate.current, .mutedByApp(axLabel: "Unmute", locale: "en"))
    }

    /// Log wins while it is fresh: an AX reading that disagrees inside the window is
    /// refused rather than clobbering the oracle that leads it by ~50 ms.
    func test_a_fresh_log_reading_outranks_a_disagreeing_ax_reading() {
        let log = RecordingEventLog()
        let gate = makeGate(eventLog: log)
        defer { gate.shutdown() }

        gate.injectAxMuteEvent(logEvent(muted: true), source: .log)
        drain()
        guard case .mutedByApp = gate.current else {
            return XCTFail("the log's `.muted` must drive the verdict; got \(gate.current)")
        }

        clock = clock.addingTimeInterval(1)
        gate.injectAxMuteEvent(AXMuteButtonProbe.Event(state: .unmuted, label: "Mute", locale: "en"))
        drain()
        guard case .mutedByApp = gate.current else {
            return XCTFail("a fresh log reading must outrank the AX read; got \(gate.current)")
        }
        XCTAssertTrue(log.entries.contains {
            $0.action == "mute_reading_suppressed" && $0.attributes["source"] == "ax"
        })
    }

    /// AX carries once the log has gone quiet, which is the whole reason this is a
    /// fusion and not a supersede: one measured transition had no log line at all.
    func test_ax_carries_once_the_log_reading_is_stale() {
        let gate = makeGate()
        defer { gate.shutdown() }

        gate.injectAxMuteEvent(logEvent(muted: true), source: .log)
        drain()
        clock = clock.addingTimeInterval(MuteSourceFusion.defaultLogFreshness + 1)
        gate.injectAxMuteEvent(AXMuteButtonProbe.Event(state: .unmuted, label: "Mute", locale: "en"))
        drain()

        if case .mutedByApp = gate.current {
            XCTFail("a stale log reading must not out-vote the AX read; got \(gate.current)")
        }
    }

    /// A blind AX read is not evidence about the log. Clearing on it while a log
    /// reading is fresh would throw away the oracle that just answered.
    func test_clear_is_refused_while_a_log_reading_is_fresh_and_honoured_after() {
        let gate = makeGate()
        defer { gate.shutdown() }

        gate.injectAxMuteEvent(logEvent(muted: true), source: .log)
        drain()
        gate.clearAxMute()
        drain()
        guard case .mutedByApp = gate.current else {
            return XCTFail("clear must not discard a fresh log reading; got \(gate.current)")
        }

        clock = clock.addingTimeInterval(MuteSourceFusion.defaultLogFreshness + 1)
        gate.clearAxMute()
        drain()
        if case .mutedByApp = gate.current {
            XCTFail("clear must be honoured once the log is quiet; got \(gate.current)")
        }
    }

    /// One adapter per source, first match wins within a source: Teams gets both its
    /// AX scrape and its log reader.
    func test_start_runs_one_adapter_per_source() throws {
        let ax = FakeMuteAdapter(app: "teams", source: .ax)
        let logReader = FakeMuteAdapter(app: "teams", source: .log)
        let gate = makeGate(adapters: [ax, logReader])
        defer { gate.shutdown() }

        try gate.start(context: teams, handle: MicGateAdapterHandle())
        XCTAssertEqual(ax.starts, 1)
        XCTAssertEqual(logReader.starts, 1)

        gate.stop()
        XCTAssertEqual(ax.stops, 1)
        XCTAssertEqual(logReader.stops, 1)
    }

    /// The behaviour MIC8 must not disturb: two `.ax` adapters sharing one bundle set
    /// (the browser no-op pair) still start only the first, so their two distinct
    /// `micgate` actions keep telling the no-AX surfaces apart.
    func test_only_the_first_adapter_of_a_source_starts() throws {
        let first = FakeMuteAdapter(app: "meet", source: .ax)
        let second = FakeMuteAdapter(app: "browser", source: .ax)
        let gate = makeGate(adapters: [first, second])
        defer { gate.shutdown() }

        try gate.start(context: teams, handle: MicGateAdapterHandle())
        XCTAssertEqual(first.starts, 1)
        XCTAssertEqual(second.starts, 0)
    }

    /// A log adapter's reading reaches the same precedence chain the AX sink does.
    func test_an_adapter_tagged_log_stamps_the_fusion() throws {
        let logReader = FakeMuteAdapter(app: "teams", source: .log)
        let gate = makeGate(adapters: [logReader])
        defer { gate.shutdown() }
        try gate.start(context: teams, handle: MicGateAdapterHandle())

        logReader.send(logEvent(muted: true))
        drain()
        guard case .mutedByApp = gate.current else {
            return XCTFail("a `.log` adapter must drive the verdict; got \(gate.current)")
        }

        // ... and it stamped the freshness, so the AX read is now the fallback.
        gate.injectAxMuteEvent(AXMuteButtonProbe.Event(state: .unmuted, label: "Mute", locale: "en"))
        drain()
        guard case .mutedByApp = gate.current else {
            return XCTFail("the adapter's reading must gate the AX read; got \(gate.current)")
        }
    }

    private func logEvent(muted: Bool) -> AXMuteButtonProbe.Event {
        AXMuteButtonProbe.Event(
            state: muted ? .muted : .unmuted,
            label: SlimCoreMuteLog.transitionMarker + (muted ? "mute" : "unmute"),
            locale: ""
        )
    }

    /// The publish path is async on the gate's internal queue; wait a tick to drain.
    private func drain() {
        let exp = expectation(description: "drain")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }
}

/// Counts starts/stops and replays events into whatever sink MicGate installed.
private final class FakeMuteAdapter: MicGateAdapter {
    let bundleIDs: Set<String> = ["com.microsoft.teams2"]
    let app: String
    let source: MuteReadingSource

    private(set) var starts = 0
    private(set) var stops = 0
    private var sink: ((AXMuteButtonProbe.Event) -> Void)?

    init(app: String, source: MuteReadingSource) {
        self.app = app
        self.source = source
    }

    func start(
        context: MeetingLifecycleContext,
        handle: MicGateAdapterHandle,
        sink: @escaping (AXMuteButtonProbe.Event) -> Void
    ) throws {
        starts += 1
        self.sink = sink
    }

    func stop() { stops += 1 }

    func send(_ event: AXMuteButtonProbe.Event) { sink?(event) }
}
