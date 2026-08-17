import AVFoundation
import XCTest
@testable import MeetingPipe

/// REC13: `MicLevelMonitor`'s `engine.start()` was the last unbounded
/// `AVAudioEngine.start()` in the tree. It runs on this monitor's private serial
/// queue and so does `stop()`, so an unbounded wedged start did not merely leave the
/// waveform flat, it made the monitor un-stoppable for the process lifetime with the
/// tap and the engine still open behind it.
final class MicLevelMonitorTests: XCTestCase {

    private let budget = 0.15

    func test_startBounded_reports_running_when_the_engine_comes_up() {
        let tapRemoved = OSAllocatedUnfairLockBox<Bool>(false)
        let running = MicLevelMonitor.startBounded(
            budgetSeconds: budget,
            startEngine: {},
            removeTap: { tapRemoved.value = true }
        )
        XCTAssertTrue(running)
        XCTAssertFalse(tapRemoved.value, "a successful start keeps the tap")
    }

    /// The load-bearing one: a start that never returns is abandoned inside the budget
    /// and reported as not running, so the caller's queue is free for `stop()`.
    func test_startBounded_is_bounded_when_the_engine_start_wedges() {
        let tapRemoved = OSAllocatedUnfairLockBox<Bool>(false)
        let started = Date()
        let running = MicLevelMonitor.startBounded(
            budgetSeconds: budget,
            startEngine: { Thread.sleep(forTimeInterval: 5) },
            removeTap: { tapRemoved.value = true }
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(running)
        XCTAssertLessThan(elapsed, budget + 2.0, "the wedged start was not abandoned inside its budget")
        XCTAssertTrue(
            tapRemoved.value,
            "the tap must come off: a live tap feeding a monitor that reports itself stopped is the worse state"
        )
    }

    /// A throwing start (no mic permission, wedged device) keeps its existing
    /// behaviour: not running, tap removed, warning logged.
    func test_startBounded_removes_the_tap_when_the_engine_throws() {
        struct Boom: Error {}
        let tapRemoved = OSAllocatedUnfairLockBox<Bool>(false)
        let running = MicLevelMonitor.startBounded(
            budgetSeconds: budget,
            startEngine: { throw Boom() },
            removeTap: { tapRemoved.value = true }
        )
        XCTAssertFalse(running)
        XCTAssertTrue(tapRemoved.value)
    }

    // MARK: - REC12: the guard sits between the format read and the install

    private var unusableFormat: AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: 0, channels: 1)! }
    private var healthyFormat: AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)! }

    /// Fails against `main`, which reads `outputFormat(forBus: 0)` and passes it straight
    /// through: the engine start would run and the tap would already have aborted the
    /// process on a real node.
    func test_arm_refuses_an_unusable_format_before_touching_the_engine() {
        let installed = OSAllocatedUnfairLockBox<Bool>(false)
        let started = OSAllocatedUnfairLockBox<Bool>(false)

        let running = MicLevelMonitor.arm(
            format: unusableFormat,
            budgetSeconds: budget,
            installTap: { installed.value = true },
            startEngine: { started.value = true },
            removeTap: {}
        )

        XCTAssertFalse(running)
        XCTAssertFalse(installed.value, "installTap raises on this format and Swift cannot catch it")
        XCTAssertFalse(started.value, "no point starting an engine we refused to tap")
    }

    /// The retry property, which is why the guard returns rather than latching a flag: a
    /// refused install leaves nothing behind, so the next prompt starts from scratch. The
    /// format that made the app abort was transitional, and the device it belonged to was
    /// usable seconds later.
    func test_a_refused_install_leaves_metering_not_live_so_a_later_start_can_retry() {
        XCTAssertFalse(MicLevelMonitor.arm(
            format: unusableFormat, budgetSeconds: budget,
            installTap: {}, startEngine: {}, removeTap: {}
        ))
        XCTAssertTrue(MicLevelMonitor.arm(
            format: healthyFormat, budgetSeconds: budget,
            installTap: {}, startEngine: {}, removeTap: {}
        ), "a monitor latched out by one bad format never meters again for the process lifetime")
    }

    /// Not a blanket disable: a healthy format still installs and still brings the engine up.
    func test_arm_installs_the_tap_for_a_healthy_format() {
        let installed = OSAllocatedUnfairLockBox<Bool>(false)
        let started = OSAllocatedUnfairLockBox<Bool>(false)

        let running = MicLevelMonitor.arm(
            format: healthyFormat,
            budgetSeconds: budget,
            installTap: { installed.value = true },
            startEngine: { started.value = true },
            removeTap: {}
        )

        XCTAssertTrue(running)
        XCTAssertTrue(installed.value)
        XCTAssertTrue(started.value)
    }

    /// The other half of "the callback still fires": the level the tap block publishes.
    /// Lifted out of the render callback so it can be checked at all, the way
    /// `MeetingRecorder.meterLevelDb` was.
    func test_meterLevel_shapes_a_quiet_room_and_a_speaking_voice_apart() {
        XCTAssertEqual(MicLevelMonitor.meterLevel(rms: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(MicLevelMonitor.meterLevel(rms: 0.01), 0.037, accuracy: 0.005)
        XCTAssertEqual(MicLevelMonitor.meterLevel(rms: 0.5), 0.740, accuracy: 0.005)
        XCTAssertGreaterThan(
            MicLevelMonitor.meterLevel(rms: 0.5), MicLevelMonitor.meterLevel(rms: 0.01) * 10,
            "the log shape is what keeps quiet speech off the floor of a linear scale"
        )
        XCTAssertLessThanOrEqual(MicLevelMonitor.meterLevel(rms: 4), 1, "clamped, so a clipping buffer cannot overdraw")
        XCTAssertGreaterThanOrEqual(MicLevelMonitor.meterLevel(rms: -1), 0)
    }

    // MARK: - REC12 item 4: the monitor and the engine cannot disagree

    /// A device or route change stops the engine and drops its taps with no notice. Before
    /// this observer the flag went on saying "metering", and `start`'s `!isRunning` guard
    /// then refused to rebuild the tap that was already gone.
    func test_a_configuration_change_clears_the_metering_flag() {
        let engine = AVAudioEngine()
        let center = NotificationCenter()
        let monitor = MicLevelMonitor(engine: engine, notificationCenter: center)
        monitor.markMeteringLiveForTest()
        XCTAssertTrue(monitor.isMeteringLive)

        center.post(name: .AVAudioEngineConfigurationChange, object: engine)

        // `addMainQueueObserver` hops to main; the handler then hops to the monitor's own
        // queue, and `isMeteringLive` reads that queue synchronously, so draining main once
        // is enough to see the settled value.
        let drained = expectation(description: "main drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)

        XCTAssertFalse(
            monitor.isMeteringLive,
            "the monitor still believes it is metering an engine that stopped itself"
        )
    }

    /// Scoped to its own engine, so an unrelated engine's route change does not stand the
    /// prompt's waveform down.
    func test_another_engines_configuration_change_is_ignored() {
        let engine = AVAudioEngine()
        let center = NotificationCenter()
        let monitor = MicLevelMonitor(engine: engine, notificationCenter: center)
        monitor.markMeteringLiveForTest()

        center.post(name: .AVAudioEngineConfigurationChange, object: AVAudioEngine())

        let drained = expectation(description: "main drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)

        XCTAssertTrue(monitor.isMeteringLive)
    }

    /// `stop()` no longer asks the flag first. REC13 documented the residual this closes:
    /// an abandoned start that later succeeds leaves a running engine the monitor believes
    /// is stopped, and the old `guard isRunning` skipped the teardown, stranding a live tap
    /// for the process lifetime.
    ///
    /// A source fence, deliberately. Calling the real `stop()` here would touch
    /// `engine.inputNode`, and reaching the HAL from a test is exactly what the rest of this
    /// file is closure-injected to avoid; on a machine with no input device that call is
    /// itself in the raise class this task is about. The distinguishing case is "flag false,
    /// teardown must still run", which cannot be observed without either a device or an
    /// injected teardown seam that no app code would ever use.
    func test_stop_does_not_gate_its_teardown_on_the_metering_flag() throws {
        let source = try daemonSource("Sources/MeetingPipe/Design/MicLevelMonitor.swift")
        let stopBody = try XCTUnwrap(source.components(separatedBy: "func stop() {").last).prefix(500)
        XCTAssertTrue(stopBody.contains("runBoundedSync"), "the fence is anchored on the wrong body")
        XCTAssertFalse(
            stopBody.contains("self.isRunning else"),
            "stop() gates its teardown on isRunning again; that flag is exactly what desyncs from the engine"
        )
    }

    private func daemonSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
