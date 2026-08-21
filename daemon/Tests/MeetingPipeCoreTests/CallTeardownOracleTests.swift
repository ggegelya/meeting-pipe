import XCTest
@testable import MeetingPipeCore

/// END9. The defect: `rescueProvisionalEnd` walks the AX tree ~120 ms after `AXLeaveButtonSignal`
/// walked it, and treats a second empty result as proof the call ended. Both land inside the same
/// 1-to-65 s accessibility blackout, so the empty walk means "Teams' tree is blank" at least as
/// often as "the call is over". These pin the replacement: Teams' own teardown line decides.
final class CallTeardownOracleTests: XCTestCase {

    private let teamsContext = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2",
        kind: .native,
        pid: 91771
    )

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func input(
        now: TimeInterval,
        provisionalStartedAt: TimeInterval,
        lastTeardownAt: TimeInterval?,
        oracleAvailable: Bool = true
    ) -> CallTeardownOracle.Input {
        CallTeardownOracle.Input(
            now: at(now),
            provisionalStartedAt: at(provisionalStartedAt),
            lastTeardownAt: lastTeardownAt.map(at),
            oracleAvailable: oracleAvailable
        )
    }

    /// `Date(timeIntervalSince1970:)` does not round-trip a fractional second exactly, so the
    /// elapsed value is compared with a tolerance while the *case* is compared exactly. Asserting
    /// on the case alone would let a confirm masquerade as a hold, which is the one thing these
    /// tests exist to catch.
    private func assertHold(
        _ verdict: CallTeardownOracle.Verdict,
        elapsed: TimeInterval,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .hold(let actual) = verdict else {
            return XCTFail("expected .hold, got \(verdict). \(message)", file: file, line: line)
        }
        XCTAssertEqual(actual, elapsed, accuracy: 0.001, message, file: file, line: line)
    }

    // MARK: - The regression fixture, pre-registered in the spec

    /// The 2026-08-03 12:51:19Z false end, which cost 9 m 53 s of a meeting. A healthy-to-invalid
    /// edge, an empty re-walk, a second empty re-walk 120 ms later, and Teams' teardown log carrying
    /// nothing anywhere near it (the call really ended at 13:01:13Z, 9m53s later). The old path
    /// confirmed on the second empty walk; this must hold.
    func test_the_2026_08_03_false_end_is_held_not_confirmed() {
        let provisional: TimeInterval = 0
        // The signal's own re-walk, then the rescue's 120 ms later. Neither can see a teardown,
        // because Teams has not written one.
        for consult in [0.0, 0.120] {
            assertHold(
                CallTeardownOracle.decide(
                    input(now: provisional + consult, provisionalStartedAt: provisional, lastTeardownAt: nil)
                ),
                elapsed: consult,
                "an empty AX walk is not evidence of an end; Teams logged no teardown"
            )
        }
    }

    /// The other half of that trace: the live-call signature returned 32.5 s later, well inside the
    /// cap, so the recording was still running to receive it.
    func test_the_2026_08_03_call_is_still_held_when_the_live_signature_returns() {
        assertHold(
            CallTeardownOracle.decide(input(now: 32.5, provisionalStartedAt: 0, lastTeardownAt: nil)),
            elapsed: 32.5
        )
    }

    // MARK: - 2026-08-20, the incident that triggered the build

    /// Same morning, both outcomes, which is what makes it a good pair. The 12:30:44 local end had
    /// no teardown within 27 minutes either side and chopped the recording at 8.5 s. The 13:39:54
    /// end had one 0.81 s before it and was genuine.
    func test_the_2026_08_20_pair_splits_correctly() {
        assertHold(
            CallTeardownOracle.decide(input(now: 0.06, provisionalStartedAt: 0, lastTeardownAt: nil)),
            elapsed: 0.06,
            "12:30:44 local: no teardown, so the call was still up and the recording must continue"
        )
        XCTAssertEqual(
            CallTeardownOracle.decide(
                input(now: 0.06, provisionalStartedAt: 0, lastTeardownAt: -0.81)
            ),
            .confirm(reason: .teardownObserved),
            "13:39:54 local: Teams logged the teardown 0.81 s earlier, so this really ended"
        )
    }

    // MARK: - The lookback

    /// The teardown leads the AX edge (p50 ~1.3 s, largest observed 6.82 s), so the normal case is a
    /// line that is already on disk when the provisional opens.
    func test_a_teardown_just_inside_the_lookback_confirms() {
        XCTAssertEqual(
            CallTeardownOracle.decide(
                input(now: 0.12, provisionalStartedAt: 0, lastTeardownAt: -14.9)
            ),
            .confirm(reason: .teardownObserved)
        )
    }

    /// The bound that stops a *previous* call's teardown confirming this one. Without it, any
    /// meeting following another within the lookback would end on its predecessor's evidence.
    func test_a_teardown_from_a_previous_call_does_not_confirm() {
        assertHold(
            CallTeardownOracle.decide(input(now: 0.12, provisionalStartedAt: 0, lastTeardownAt: -15.1)),
            elapsed: 0.12
        )
    }

    /// A teardown that lands after the provisional opens is caught by a later consult rather than by
    /// a second constant. This is why the host re-consults on a tick instead of deciding once.
    func test_a_teardown_arriving_after_the_provisional_confirms_on_the_next_consult() {
        assertHold(
            CallTeardownOracle.decide(input(now: 1.0, provisionalStartedAt: 0, lastTeardownAt: nil)),
            elapsed: 1.0
        )
        XCTAssertEqual(
            CallTeardownOracle.decide(input(now: 3.0, provisionalStartedAt: 0, lastTeardownAt: 2.0)),
            .confirm(reason: .teardownObserved)
        )
    }

    // MARK: - Degradation and the ceiling

    /// The safety property that makes this change never worse than what it replaces: no usable log
    /// means today's behaviour, an immediate confirm, never a hold.
    func test_an_unavailable_oracle_confirms_immediately() {
        XCTAssertEqual(
            CallTeardownOracle.decide(
                input(now: 0, provisionalStartedAt: 0, lastTeardownAt: nil, oracleAvailable: false)
            ),
            .confirm(reason: .oracleUnavailable)
        )
    }

    /// Availability is checked before everything, so a broken log cannot be held even at the moment
    /// a real teardown would have confirmed anyway.
    func test_unavailability_outranks_a_present_teardown() {
        XCTAssertEqual(
            CallTeardownOracle.decide(
                input(now: 0, provisionalStartedAt: 0, lastTeardownAt: -1, oracleAvailable: false)
            ),
            .confirm(reason: .oracleUnavailable)
        )
    }

    /// A held provisional **always** terminates. Two multi-thousand-second provisional stalls
    /// already exist in the event log; this is the guard against a third, and it is a property of
    /// the pure type rather than of the timer plumbing so it cannot be lost to a scheduling bug.
    func test_a_held_provisional_always_terminates_at_the_cap() {
        for elapsed in stride(from: 0.0, through: 400.0, by: 0.5) {
            let verdict = CallTeardownOracle.decide(
                input(now: elapsed, provisionalStartedAt: 0, lastTeardownAt: nil)
            )
            if elapsed < CallTeardownOracle.defaultHoldCapSec {
                assertHold(verdict, elapsed: elapsed)
            } else {
                XCTAssertEqual(verdict, .confirm(reason: .holdCapReached))
            }
        }
    }

    /// Ordering: a real end confirms on its own evidence, so the reason recorded in the log is the
    /// teardown rather than the timeout, even past the ceiling.
    func test_a_teardown_outranks_the_cap() {
        XCTAssertEqual(
            CallTeardownOracle.decide(
                input(now: 1_000, provisionalStartedAt: 0, lastTeardownAt: -1)
            ),
            .confirm(reason: .teardownObserved)
        )
    }

    // MARK: - Parsing the line

    private static let realTeardownLine =
        "2026-08-20T09:57:40.907203+03:00 0x00000001fb809d80 <INFO> "
        + "SlimCoreModule::WindowContentProtectionProvider: UnregisterCall 378"

    /// The SlimCore timestamp prints UTC and then suffixes the machine's local offset, so this line
    /// happened at 09:57:40 UTC and not at 06:57:40. Getting it wrong is silently wrong by the local
    /// offset and correct-looking on a UTC machine.
    func test_parses_the_verbatim_line_and_reads_the_clock_as_utc() {
        let parsed = SlimCoreTeardownLog.parse(line: Self.realTeardownLine)
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 20
        components.hour = 9; components.minute = 57; components.second = 40
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let expected = utc.date(from: components)!.addingTimeInterval(0.907203)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.0001)
    }

    /// The registration line brackets the same DRM object at call **start**. Accepting it would read
    /// every call's beginning as its end.
    func test_rejects_the_registration_line() {
        let line = "2026-08-20T10:38:56.531207+03:00 0x1 <INFO> "
            + "SlimCoreModule::WindowContentProtectionProvider: SetWindowContentProtection 385"
        XCTAssertNil(SlimCoreTeardownLog.parse(line: line))
    }

    /// Teams' shell log dumps a large config blob whose keys are matched by loose tokens. A phantom
    /// teardown is worse than a missed one: it confirms an end that never happened.
    func test_rejects_a_loose_token_in_a_config_blob() {
        let line = "2026-08-20T10:15:07.664710+03:00 0x1 <INFO> EcsSettings: "
            + "{\"unregisterCallEnabled\":true,\"UnregisterCall\":1}"
        XCTAssertNil(SlimCoreTeardownLog.parse(line: line))
    }

    func test_rejects_a_marker_with_no_call_id() {
        let line = "2026-08-20T09:57:40.907203+03:00 0x1 <INFO> "
            + "SlimCoreModule::WindowContentProtectionProvider: UnregisterCall success result"
        XCTAssertNil(SlimCoreTeardownLog.parse(line: line))
    }

    /// SlimCore flushes mid-line routinely, and the live file's last line is usually truncated.
    /// Measured on 2026-08-20: the file ended at a bare "20" mid-timestamp, and the teardown it was
    /// part way through writing appeared only on a later read. Without the carry that teardown is
    /// dropped and a real end is held to the cap.
    func test_carries_a_partial_line_between_ticks() {
        let full = Self.realTeardownLine + "\n"
        let split = full.index(full.startIndex, offsetBy: 30)
        let firstChunk = Data(full[full.startIndex..<split].utf8)
        let secondChunk = Data(full[split...].utf8)

        let tick1 = SlimCoreTeardownLog.newestTeardown(inChunk: firstChunk, pending: Data())
        XCTAssertNil(tick1.newest, "half a line is not a teardown")
        XCTAssertFalse(tick1.carry.isEmpty)

        let tick2 = SlimCoreTeardownLog.newestTeardown(inChunk: secondChunk, pending: tick1.carry)
        XCTAssertNotNil(tick2.newest, "the carried remainder completes the line")
        XCTAssertTrue(tick2.carry.isEmpty)
    }

    /// A tick that catches up on several calls at once needs only the last, because the oracle only
    /// ever asks whether a teardown happened recently.
    func test_newest_wins_when_one_chunk_holds_several() {
        let older = "2026-08-20T09:57:40.907203+03:00 0x1 <INFO> "
            + "SlimCoreModule::WindowContentProtectionProvider: UnregisterCall 378\n"
        let newer = "2026-08-20T10:39:53.309807+03:00 0x1 <INFO> "
            + "SlimCoreModule::WindowContentProtectionProvider: UnregisterCall 385\n"
        let result = SlimCoreTeardownLog.newestTeardown(
            inChunk: Data((older + "noise\n" + newer).utf8), pending: Data()
        )
        XCTAssertEqual(result.newest, SlimCoreTeardownLog.parse(line: newer))
    }

    // MARK: - Driven through the real PromotionEngine

    private func event(
        _ kind: PrimarySignalKind, _ state: PrimarySignalState, at seconds: TimeInterval
    ) -> PrimarySignalEvent {
        PrimarySignalEvent(kind: kind, state: state, timestamp: at(seconds), context: teamsContext)
    }

    /// Bring a real engine to `.endingProvisional` the way an ax-leave edge does.
    private func engineInProvisionalEnd() -> PromotionEngine {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.axLeaveButton, .ended, at: 100))
        return engine
    }

    /// The whole defect, at the level it actually bit. The host consults the oracle instead of
    /// confirming on its own empty walk, so the engine is never driven to `.ended` and the recording
    /// survives the blackout.
    ///
    /// Neuter `CallTeardownOracle.decide` to always `.confirm` and this goes red: that neutering is
    /// exactly what `main` does, an unconditional `confirmProvisionalEnd()` after one empty walk.
    func test_the_2026_08_03_sequence_never_reaches_ended() {
        let engine = engineInProvisionalEnd()

        // The signal's own re-walk and the rescue's, 120 ms apart, both inside the blackout.
        for consult in [100.0, 100.12] {
            let verdict = CallTeardownOracle.decide(
                input(now: consult, provisionalStartedAt: 100, lastTeardownAt: nil)
            )
            guard case .confirm = verdict else { continue }
            _ = engine.confirmProvisionalEnd()
        }
        XCTAssertNil(
            engine.tick(at: at(100.12)),
            "an uncorroborated ax-leave lead must not promote on the debounce either"
        )

        // The live-call signature returns 32.5 s later and reverts through END8.
        let revert = engine.ingest(event(.axLeaveButton, .live, at: 132.5))
        XCTAssertEqual(
            revert?.verdict, .inMeeting(context: teamsContext),
            "the recording was still running to receive the returning Leave button"
        )
    }

    /// The companion the spec requires: a genuine end must not pay for this. Teams logged the
    /// teardown before the AX edge, so the very first consult confirms and there is no added latency.
    func test_a_genuine_end_confirms_on_the_first_consult_with_no_added_latency() {
        let engine = engineInProvisionalEnd()
        let verdict = CallTeardownOracle.decide(
            input(now: 100.12, provisionalStartedAt: 100, lastTeardownAt: 98.7)
        )
        XCTAssertEqual(verdict, .confirm(reason: .teardownObserved))

        let decision = engine.confirmProvisionalEnd()
        guard case .ended(let context, let reason)? = decision?.verdict else {
            return XCTFail("a confirmed teardown must promote to .ended")
        }
        XCTAssertEqual(context, teamsContext)
        XCTAssertEqual(reason.leadingSignal, PrimarySignalKind.axLeaveButton.rawValue)
    }

    // MARK: - END10 item 6: a teardown has to belong to *this* recording

    /// Red before END10: the 2026-08-21 chop in miniature. The last teardown landed at 13:36:02,
    /// fifteen seconds before `20260821-133615.wav` even started, and the 15 s lookback reached
    /// back past the recording's own beginning to confirm it.
    func testTeardownBeforeTheRecordingStartedDoesNotConfirm() {
        let recordingStart = Date(timeIntervalSince1970: 1_000_000)
        // The teardown has to land *inside* the 15 s lookback and still *before* the recording
        // began, or this passes against the unfixed code for the wrong reason: the provisional
        // opens 5 s in, so the old floor reaches back to recordingStart - 10, and a teardown at
        // recordingStart - 3 is the case where a previous call's line confirms this recording.
        let verdict = CallTeardownOracle.decide(CallTeardownOracle.Input(
            now: recordingStart.addingTimeInterval(30),
            provisionalStartedAt: recordingStart.addingTimeInterval(5),
            lastTeardownAt: recordingStart.addingTimeInterval(-3),
            oracleAvailable: true,
            recordingStartedAt: recordingStart,
            logLastWrittenAt: recordingStart.addingTimeInterval(20)
        ))
        guard case .hold = verdict else {
            return XCTFail("a previous call's teardown must not confirm this recording, got \(verdict)")
        }
    }

    func testTeardownInsideThisRecordingStillConfirms() {
        let recordingStart = Date(timeIntervalSince1970: 1_000_000)
        let verdict = CallTeardownOracle.decide(CallTeardownOracle.Input(
            now: recordingStart.addingTimeInterval(60),
            provisionalStartedAt: recordingStart.addingTimeInterval(50),
            lastTeardownAt: recordingStart.addingTimeInterval(48),
            oracleAvailable: true,
            recordingStartedAt: recordingStart,
            logLastWrittenAt: recordingStart.addingTimeInterval(48)
        ))
        XCTAssertEqual(verdict, .confirm(reason: .teardownObserved))
    }

    /// The lookback still has to work: the line leads the AX edge by about 1.3 s, so a teardown a
    /// moment before the provisional opened is the normal path for a genuine end.
    func testLookbackStillReachesBackWithinTheRecording() {
        let recordingStart = Date(timeIntervalSince1970: 1_000_000)
        let provisional = recordingStart.addingTimeInterval(300)
        let verdict = CallTeardownOracle.decide(CallTeardownOracle.Input(
            now: provisional,
            provisionalStartedAt: provisional,
            lastTeardownAt: provisional.addingTimeInterval(-6.82),
            oracleAvailable: true,
            recordingStartedAt: recordingStart,
            logLastWrittenAt: provisional
        ))
        XCTAssertEqual(
            verdict, .confirm(reason: .teardownObserved),
            "the largest observed lead is 6.82 s and must still confirm"
        )
    }

    // MARK: - END10 item 5: a frozen generation is a dead log, not a quiet one

    /// The 2026-08-21 case: the generation was last written at 13:36:15 and was still frozen at
    /// 14:06 while the call ran to 13:56. Before END10 that read as a healthy oracle with nothing
    /// to report, so every genuine end would have held the full 150 s cap.
    func testGenerationFrozenBeforeTheRecordingConfirmsAsStale() {
        let recordingStart = Date(timeIntervalSince1970: 1_000_000)
        let verdict = CallTeardownOracle.decide(CallTeardownOracle.Input(
            now: recordingStart.addingTimeInterval(120),
            provisionalStartedAt: recordingStart.addingTimeInterval(110),
            lastTeardownAt: nil,
            oracleAvailable: true,
            recordingStartedAt: recordingStart,
            logLastWrittenAt: recordingStart.addingTimeInterval(-60)
        ))
        XCTAssertEqual(
            verdict, .confirm(reason: .logStale),
            "a log not written since the recording began cannot be evidence that no call ended"
        )
    }

    func testFreshGenerationWithNoTeardownStillHolds() {
        let recordingStart = Date(timeIntervalSince1970: 1_000_000)
        let verdict = CallTeardownOracle.decide(CallTeardownOracle.Input(
            now: recordingStart.addingTimeInterval(120),
            provisionalStartedAt: recordingStart.addingTimeInterval(110),
            lastTeardownAt: nil,
            oracleAvailable: true,
            recordingStartedAt: recordingStart,
            logLastWrittenAt: recordingStart.addingTimeInterval(115)
        ))
        guard case .hold = verdict else {
            return XCTFail("a live log with no teardown is the whole point of the hold, got \(verdict)")
        }
    }

    /// Staleness is checked before the teardown lookback, so a dead log cannot be rescued by a
    /// teardown it logged before it died.
    func testStalenessOutranksAnOldTeardown() {
        let recordingStart = Date(timeIntervalSince1970: 1_000_000)
        let verdict = CallTeardownOracle.decide(CallTeardownOracle.Input(
            now: recordingStart.addingTimeInterval(120),
            provisionalStartedAt: recordingStart.addingTimeInterval(110),
            lastTeardownAt: recordingStart.addingTimeInterval(105),
            oracleAvailable: true,
            recordingStartedAt: recordingStart,
            logLastWrittenAt: recordingStart.addingTimeInterval(-60)
        ))
        XCTAssertEqual(verdict, .confirm(reason: .logStale))
    }

    /// The pre-END10 call shape (no recording start, no mtime) must keep behaving exactly as it did,
    /// so this change cannot regress anything that still calls it that way.
    func testOmittedEnd10InputsPreserveTheOriginalBehaviour() {
        let provisional = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(
            CallTeardownOracle.decide(CallTeardownOracle.Input(
                now: provisional,
                provisionalStartedAt: provisional,
                lastTeardownAt: provisional.addingTimeInterval(-2),
                oracleAvailable: true
            )),
            .confirm(reason: .teardownObserved)
        )
    }

}
