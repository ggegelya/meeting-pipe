import AVFoundation
import XCTest
@testable import MeetingPipe

/// ARCH8: the device-change recovery procedure, driven through `InputDeviceRecoveryHost` with a
/// fake, so the paths that need a live recording run without an engine or the HAL. The idle-side
/// pins written against the unextracted recorder are in `MeetingRecorderPinsARCH8Tests`.
/// T7 source fence (deliberate): two tests grep InputDeviceRecovery and MeetingRecorder for the REC13 observer registration and the REC16 one swap site. Missing seam: none for the behaviour, which the fake-host tests drive; these pin the spelling REC13 bans.
@MainActor
final class InputDeviceRecoveryTests: XCTestCase {

    private var host: FakeRecoveryHost!
    private var recovery: InputDeviceRecovery!

    override func setUp() async throws {
        host = FakeRecoveryHost()
        recovery = InputDeviceRecovery()
        recovery.host = host
    }

    override func tearDown() async throws {
        host.releaseHalt()
        host.releaseRead()
        await recovery.standDown()
        recovery = nil
        host = nil
    }

    private func postConfigurationChange(on object: AnyObject? = nil) {
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: object ?? host.observedEngine)
    }

    /// Lets the observer's explicit main hop and anything it enqueued run.
    private func drainMainQueue() async {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }

    // MARK: - The observer and the one-at-a-time guard

    func test_aConfigurationChangeWhileRecordingStartsARecovery() async {
        host.holdHalt = true
        let halted = expectation(description: "recovery reached the engine")
        host.onHalt = { halted.fulfill() }
        recovery.armConfigurationChangeObserver()

        postConfigurationChange()

        await fulfillment(of: [halted], timeout: 2)
        XCTAssertNotNil(recovery.recoveryTask)
        XCTAssertEqual(host.haltCalls, 1)
    }

    /// A re-entrant change while a restart is in flight is dropped, not queued beside it.
    func test_aSecondChangeDuringAnInFlightRecoveryDoesNotStartAnother() async {
        host.holdHalt = true
        let halted = expectation(description: "first recovery reached the engine")
        host.onHalt = { halted.fulfill() }
        recovery.armConfigurationChangeObserver()
        postConfigurationChange()
        await fulfillment(of: [halted], timeout: 2)

        postConfigurationChange()
        await drainMainQueue()

        XCTAssertEqual(host.haltCalls, 1, "the guard on recoveryTask drops the second change")
    }

    /// `stop()` must not tear the engine down under a recovery that is restarting it.
    func test_standDownWaitsForAnInFlightRecovery() async {
        host.holdHalt = true
        let halted = expectation(description: "recovery reached the engine")
        host.onHalt = { halted.fulfill() }
        recovery.armConfigurationChangeObserver()
        postConfigurationChange()
        await fulfillment(of: [halted], timeout: 2)

        var stoodDown = false
        let standDown = Task { @MainActor in
            await self.recovery.standDown()
            stoodDown = true
        }
        await drainMainQueue()
        XCTAssertFalse(stoodDown, "standDown returned while the recovery was still in flight")

        host.releaseHalt()
        await standDown.value

        XCTAssertTrue(stoodDown)
        XCTAssertEqual(host.restartCalls, 1, "the drained recovery ran to its end before standDown returned")
        XCTAssertNil(recovery.recoveryTask)
    }

    func test_standDownStopsObservingDeviceChanges() async {
        recovery.armConfigurationChangeObserver()
        await recovery.standDown()

        postConfigurationChange()
        await drainMainQueue()

        XCTAssertEqual(host.haltCalls, 0)
        XCTAssertNil(recovery.recoveryTask)
    }

    /// REC16: the observer is bound to one engine instance, so a swap has to disarm and re-arm
    /// it, which is what `MeetingRecorder.replaceEngine(reason:)` does with these two calls.
    func test_aReArmedObserverFollowsTheReplacedEngine() async {
        recovery.armConfigurationChangeObserver()
        let old = host.observedEngine
        XCTAssertTrue(recovery.disarmConfigurationChangeObserver())
        host.observedEngine = NSObject()
        recovery.armConfigurationChangeObserver()

        postConfigurationChange(on: old)
        await drainMainQueue()
        XCTAssertEqual(host.haltCalls, 0, "the old engine posts to nothing now")

        let halted = expectation(description: "the replacement is heard")
        host.onHalt = { halted.fulfill() }
        postConfigurationChange()
        await fulfillment(of: [halted], timeout: 2)
    }

    // MARK: - The procedure

    /// Bluetooth publishes the route before the format is readable, so a 0 Hz read queues a retry.
    /// REC27: the format read is bounded now, so it runs in the recovery slot and the decision
    /// lands once that task does.
    func test_aChangeWithNoUsableFormatSchedulesARetryNotARecovery() async {
        host.liveFormat = nil
        recovery.handleConfigurationChange()
        await recovery.recoveryTask?.value

        XCTAssertEqual(host.haltCalls, 0)
        XCTAssertNotNil(recovery.pendingRecoveryRetry)
        XCTAssertEqual(recovery.configurationRecoveryAttempts, 1)
        XCTAssertNil(recovery.recoveryTask)
    }

    func test_aSuccessfulRecoveryPadsTheGapAndResetsTheFailureRun() async {
        recovery.reportRecoveryFailure()
        XCTAssertEqual(recovery.consecutiveRecoveryFailures, 1)

        recovery.handleConfigurationChange()
        await recovery.recoveryTask?.value

        XCTAssertEqual(host.outcomes, [.failed, .resumed])
        XCTAssertEqual(recovery.consecutiveRecoveryFailures, 0)
        XCTAssertEqual(host.padFormats, [host.fileFormat], "the pad is written in the file's format")
        XCTAssertEqual(host.installFormats, [host.fileFormat])
        XCTAssertEqual(host.converters, [false], "a same-format change needs no converter")
    }

    /// REC13: a wedged engine ends the recovery before anything touches the tap. REC27: and the
    /// engine is retired, once, so nothing asks the wedged instance anything again.
    func test_aHaltThatTimesOutFailsWithoutTouchingTheTap() async {
        host.haltResult = (engineStopped: false, tapRemoved: true)
        recovery.handleConfigurationChange()
        await recovery.recoveryTask?.value

        XCTAssertEqual(host.outcomes, [.failed])
        XCTAssertEqual(host.installFormats, [])
        XCTAssertEqual(host.restartCalls, 0)
        XCTAssertEqual(host.retireReasons, ["recovery_halt_timed_out"])
    }

    /// REC27: after a timed-out halt the watchdog still reads the engine, but only through the
    /// bounded host call, and it reads the retired engine's replacement.
    func test_afterAHaltTimeoutTheWatchdogReadsOnlyThroughTheBoundedCall() async {
        host.haltResult = (engineStopped: false, tapRemoved: true)
        recovery.handleConfigurationChange()
        await recovery.recoveryTask?.value
        XCTAssertEqual(host.readCalls, 0)

        host.haltResult = (engineStopped: true, tapRemoved: true)
        host.engineIsRunning = false
        recovery.checkTapLiveness()
        await recovery.recoveryTask?.value

        XCTAssertEqual(host.readCalls, 1)
        XCTAssertEqual(host.haltCalls, 2, "the stopped replacement is re-armed by the next tick")
        XCTAssertEqual(host.outcomes, [.failed, .resumed])
    }

    /// REC27: a format read that times out is a wedge too.
    func test_aFormatReadThatTimesOutRetiresTheEngineWithoutHaltingIt() async {
        host.formatReadTimesOut = true
        recovery.handleConfigurationChange()
        await recovery.recoveryTask?.value

        XCTAssertEqual(host.retireReasons, ["configuration_change_format_read_timed_out"])
        XCTAssertEqual(host.haltCalls, 0)
        XCTAssertEqual(host.outcomes, [.failed])
        XCTAssertNil(recovery.pendingRecoveryRetry, "a wedge is not a route still settling")
    }

    /// REC27: an install that does not return ends the recovery before the restart.
    func test_aTapInstallThatTimesOutRetiresTheEngineAndDoesNotRestart() async {
        host.installResults = [nil]
        recovery.handleConfigurationChange()
        await recovery.recoveryTask?.value

        XCTAssertEqual(host.retireReasons, ["recovery_install_tap_timed_out"])
        XCTAssertEqual(host.restartCalls, 0)
        XCTAssertEqual(host.padFormats, [])
        XCTAssertEqual(host.outcomes, [.failed])
    }

    /// REC15: a caught raise condemns the engine, so recovery replaces it once and retries.
    func test_aRaiseReplacesTheEngineOnceAndRetriesTheTap() async {
        host.installResults = [.raised, .installed]
        recovery.handleConfigurationChange()
        await recovery.recoveryTask?.value

        XCTAssertEqual(host.retireReasons, ["condemned_mid_recording"])
        XCTAssertEqual(host.installFormats.count, 2)
        XCTAssertEqual(host.outcomes, [.resumed])
        XCTAssertFalse(recovery.micCaptureAbandoned)
    }

    /// A replacement that raises again will not stop raising, so the mic is given up at once.
    func test_aReplacementThatRaisesAgainAbandonsTheMic() async {
        host.installResults = [.raised, .raised]
        recovery.handleConfigurationChange()
        await recovery.recoveryTask?.value

        XCTAssertEqual(host.retireReasons, ["condemned_mid_recording"], "once, never a loop against a moving format")
        XCTAssertTrue(recovery.micCaptureAbandoned)
        XCTAssertEqual(host.outcomes, [.failed])
        XCTAssertEqual(host.restartCalls, 0)
    }

    /// REC27: and it retires the engine the abandoned restart may still be wedged on. The comment
    /// that used to forbid this cited an observer REC16's `replaceEngine` already re-arms.
    func test_aRestartThatTimesOutIsAFailure() async {
        host.restartResult = .timedOut
        recovery.handleConfigurationChange()
        await recovery.recoveryTask?.value

        XCTAssertEqual(host.outcomes, [.failed])
        XCTAssertEqual(recovery.consecutiveRecoveryFailures, 1)
        XCTAssertEqual(host.retireReasons, ["recovery_restart_timed_out"])
    }

    /// A restart that throws is a failure but not a wedge: the engine answered.
    func test_aRestartThatFailsDoesNotRetireTheEngine() async {
        host.restartResult = .failed("nope")
        recovery.handleConfigurationChange()
        await recovery.recoveryTask?.value

        XCTAssertEqual(host.outcomes, [.failed])
        XCTAssertEqual(host.retireReasons, [])
    }

    // MARK: - The tap watchdog

    /// REC8: a stopped engine re-arms on the first tick, whatever the counter says.
    func test_aTapWatchdogTickOnAStoppedEngineStartsARecovery() async {
        host.engineIsRunning = false
        recovery.checkTapLiveness()

        XCTAssertNotNil(recovery.recoveryTask)
        await recovery.recoveryTask?.value
        XCTAssertEqual(host.haltCalls, 1)
    }

    /// REC15: once the mic is abandoned the tick has nothing left to try. REC27: and it does not
    /// even read the engine, which it used to do before the policy looked at the flag.
    func test_anAbandonedMicIsNotReArmedByTheWatchdog() {
        host.engineIsRunning = false
        for _ in 0..<InputDeviceRecovery.recoveryFailureBudget {
            recovery.reportRecoveryFailure()
        }
        recovery.checkTapLiveness()
        XCTAssertNil(recovery.recoveryTask)
        XCTAssertEqual(host.readCalls, 0)
    }

    /// REC25: the writer backlog check rides the tap tick ahead of the abandonment guard. An
    /// abandoned mic still has a writer that a hung volume can stall, so giving up on the tap must
    /// not also give up on watching the memory behind it. Not recording, it checks nothing.
    func test_theTapTickChecksTheWriterBacklogEvenWithTheMicAbandoned() {
        recovery.checkTapLiveness()
        XCTAssertEqual(host.backlogChecks, 1)

        for _ in 0..<InputDeviceRecovery.recoveryFailureBudget {
            recovery.reportRecoveryFailure()
        }
        XCTAssertTrue(recovery.micCaptureAbandoned)
        recovery.checkTapLiveness()
        XCTAssertEqual(host.backlogChecks, 2)

        host.isRecording = false
        recovery.checkTapLiveness()
        XCTAssertEqual(host.backlogChecks, 2)
    }

    /// REC27: the watchdog's read is single-flight, so a wedged read costs one thread rather than
    /// one a second; and a read that times out is itself a wedge: the engine is retired once and
    /// the watchdog stops asking for this recording.
    func test_aWatchdogReadThatTimesOutRetiresTheEngineAndIsNeverAskedTwice() async {
        host.holdRead = true
        let reading = expectation(description: "the first read is outstanding")
        host.onRead = { reading.fulfill() }
        recovery.checkTapLiveness()
        await fulfillment(of: [reading], timeout: 2)

        recovery.checkTapLiveness()
        recovery.checkTapLiveness()
        XCTAssertEqual(host.readCalls, 1, "no second read while the first is outstanding")

        host.engineReadTimesOut = true
        host.releaseRead()
        await recovery.recoveryTask?.value

        XCTAssertEqual(host.retireReasons, ["tap_watchdog_read_timed_out"])
        XCTAssertTrue(recovery.micCaptureAbandoned)
        XCTAssertEqual(host.outcomes, [.failed], "the mic is lost, and the HUD has to say so")
        XCTAssertEqual(host.haltCalls, 0, "nothing else is asked of the wedged engine")

        recovery.checkTapLiveness()
        XCTAssertNil(recovery.recoveryTask)
        XCTAssertEqual(host.readCalls, 1, "and the watchdog stops asking for this recording")
    }

    /// REC8 + REC27: the wake re-check reads through the same bounded slot and re-arms a stopped
    /// engine.
    func test_aWakeOnAStoppedEngineStartsARecoveryThroughTheBoundedRead() async {
        host.engineIsRunning = false
        recovery.recheckAfterWake()
        await recovery.recoveryTask?.value

        XCTAssertEqual(host.readCalls, 1)
        XCTAssertEqual(host.haltCalls, 1)
        XCTAssertEqual(host.outcomes, [.resumed])
    }

    func test_aWakeOnARunningEngineDoesNothingMore() async {
        recovery.recheckAfterWake()
        await recovery.recoveryTask?.value

        XCTAssertEqual(host.readCalls, 1)
        XCTAssertEqual(host.haltCalls, 0)
    }

    /// The watchdog does not read while a recovery holds the slot, so engine calls never overlap.
    func test_theWatchdogDoesNotReadWhileARecoveryIsInFlight() async {
        host.holdHalt = true
        let halted = expectation(description: "recovery reached the engine")
        host.onHalt = { halted.fulfill() }
        recovery.handleConfigurationChange()
        await fulfillment(of: [halted], timeout: 2)

        recovery.checkTapLiveness()
        XCTAssertEqual(host.readCalls, 0)
    }

    // MARK: - Wiring fences

    /// REC13 moved with the code: the observer registers through `addMainQueueObserver` (nil
    /// queue, explicit main hop) and never with a non-nil `queue:`, which makes AVFAudio's own
    /// engine queue wait on the handler. The behavioural half is the observer tests above.
    func test_theObserverRegistersThroughTheMainQueueHelperOnly() throws {
        // Code only: the doc comments name the spelling they forbid.
        let text = try daemonSource("Sources/MeetingPipe/InputDeviceRecovery.swift")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertEqual(text.components(separatedBy: "addMainQueueObserver(").count - 1, 1)
        XCTAssertFalse(
            text.contains("addObserver(forName"),
            "the queue-taking registration is the 2026-08-14 deadlock; go through the REC13 helper"
        )
    }

    /// REC16: the engine is swapped in exactly one place, and that place re-arms through recovery.
    func test_theRecorderHasNoSecondEngineSwapOutsideReplaceEngine() throws {
        let recovery = try daemonSource("Sources/MeetingPipe/InputDeviceRecovery.swift")
        XCTAssertFalse(recovery.contains("AVAudioEngine()"), "recovery asks the host to swap; it never builds an engine")
        let recorder = try daemonSource("Sources/MeetingPipe/MeetingRecorder.swift")
        XCTAssertTrue(recorder.contains("let wasArmed = deviceRecovery.disarmConfigurationChangeObserver()"))
    }

    private func daemonSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

/// Stands in for `MeetingRecorder`: records what recovery asked of it.
private final class FakeRecoveryHost: InputDeviceRecoveryHost {
    let fileFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    lazy var liveFormat: AVAudioFormat? = fileFormat

    var isRecording = true
    var micFires: UInt64 = 0
    var engineIsRunning = true
    var observedEngine: AnyObject = NSObject()
    var micFileFormat: AVAudioFormat? { fileFormat }

    var installResults: [GuardedTapInstall.Outcome?] = []
    var haltResult = (engineStopped: true, tapRemoved: true)
    var restartResult: EngineStartOutcome = .started
    var holdHalt = false
    var onHalt: (() -> Void)?
    /// REC27: a format read that does not return in its budget.
    var formatReadTimesOut = false
    /// REC27: an `isRunning` read that does not return in its budget.
    var engineReadTimesOut = false
    /// REC27: park the `isRunning` read until `releaseRead()`, to hold it outstanding.
    var holdRead = false
    var onRead: (() -> Void)?

    private(set) var haltCalls = 0
    private(set) var restartCalls = 0
    private(set) var readCalls = 0
    private(set) var formatReads = 0
    private(set) var retireReasons: [String] = []
    private(set) var installFormats: [AVAudioFormat] = []
    private(set) var padFormats: [AVAudioFormat] = []
    private(set) var converters: [Bool] = []
    private(set) var outcomes: [MeetingRecorder.CaptureRecoveryOutcome] = []
    private(set) var backlogChecks = 0
    private var haltRelease: CheckedContinuation<Void, Never>?
    private var readRelease: CheckedContinuation<Void, Never>?

    func checkMicWriterBacklog() {
        backlogChecks += 1
    }

    @MainActor
    func readEngineIsRunning() async -> Bool? {
        readCalls += 1
        onRead?()
        if holdRead {
            await withCheckedContinuation { readRelease = $0 }
        }
        return engineReadTimesOut ? nil : engineIsRunning
    }

    @MainActor
    func liveInputFormat() async -> LiveInputFormatRead {
        formatReads += 1
        if formatReadTimesOut { return .timedOut }
        return liveFormat.map { .usable($0) } ?? .unusable
    }

    @MainActor
    func installMicTap(captureFormat: AVAudioFormat) async -> GuardedTapInstall.Outcome? {
        installFormats.append(captureFormat)
        return installResults.isEmpty ? .installed : installResults.removeFirst()
    }

    func setMicConverter(_ converter: AVAudioConverter?) { converters.append(converter != nil) }
    @MainActor func retireEngine(reason: String) async { retireReasons.append(reason) }
    func padMicGap(frames: AVAudioFrameCount, format: AVAudioFormat) { padFormats.append(format) }
    func reportConfigurationChange(_ outcome: MeetingRecorder.CaptureRecoveryOutcome) { outcomes.append(outcome) }

    func releaseHalt() {
        holdHalt = false
        haltRelease?.resume()
        haltRelease = nil
    }

    func releaseRead() {
        holdRead = false
        readRelease?.resume()
        readRelease = nil
    }

    @MainActor
    func haltEngineForRecovery() async -> (engineStopped: Bool, tapRemoved: Bool) {
        haltCalls += 1
        onHalt?()
        if holdHalt {
            await withCheckedContinuation { haltRelease = $0 }
        }
        return haltResult
    }

    @MainActor
    func restartEngine() async -> EngineStartOutcome {
        restartCalls += 1
        return restartResult
    }
}
