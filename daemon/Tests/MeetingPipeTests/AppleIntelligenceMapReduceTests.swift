import os
import XCTest
@testable import MeetingPipe

/// PIPE36: the Apple summarize's map/reduce loop, driven through its `respond` seam so no test
/// reaches the on-device model (and the CI runner, which has no `FoundationModels`, runs them):
/// a Cancel stops it before the next call, a call past the ceiling fails `.timedOut`, and it
/// beats once per planned call.
final class AppleIntelligenceMapReduceTests: XCTestCase {

    private static let partial = AppleIntelligenceSummarizer.parse(
        #"{"title":"t","summary":["s"],"decisions":[],"actions":[],"questions":[],"attendees":[],"detected_language":"en"}"#
    )!

    private var gates: [TestGate] = []

    override func tearDown() {
        gates.forEach { $0.open() }
        gates = []
        super.tearDown()
    }

    private func run(
        windows: Int,
        ceiling: Double = 5,
        respond: @escaping AppleIntelligenceSummarizer.Respond,
        onCall: ((Int, Int) -> Void)? = nil
    ) async throws -> MeetingSummary {
        try await AppleIntelligenceSummarizer.mapReduce(
            windows: (0..<windows).map { "window \($0)" },
            instructions: "map",
            reduceInstructions: "reduce",
            reduceBatch: 4,
            callCeiling: ceiling,
            respond: respond,
            onCall: onCall
        )
    }

    func test_planned_calls_count_the_map_and_every_reduce_round() {
        XCTAssertEqual(AppleIntelligenceSummarizer.plannedCalls(windows: 0, reduceBatch: 4), 1)
        XCTAssertEqual(AppleIntelligenceSummarizer.plannedCalls(windows: 1, reduceBatch: 4), 1)
        XCTAssertEqual(AppleIntelligenceSummarizer.plannedCalls(windows: 4, reduceBatch: 4), 5)
        // 5 windows: groups [4][1] (one call), then [2] (one call).
        XCTAssertEqual(AppleIntelligenceSummarizer.plannedCalls(windows: 5, reduceBatch: 4), 7)
        // The spec's 3 h meeting: about 148 map calls and 51 reduce calls, about 200 in all.
        // Rounds: 148 -> 37 partials (37 calls) -> 10 (9 calls, one group of one passes
        // through) -> 3 (3 calls) -> 1 (1 call).
        XCTAssertEqual(AppleIntelligenceSummarizer.plannedCalls(windows: 148, reduceBatch: 4), 148 + 37 + 9 + 3 + 1)
    }

    /// The count the beats report is the count the loop makes, at every size that changes the
    /// reduce shape, and the beats arrive once per call, before it, counting up from zero.
    func test_it_beats_once_before_every_call_and_the_plan_matches_the_calls() async throws {
        for windows in [1, 2, 3, 4, 5, 9, 17] {
            let calls = OSAllocatedUnfairLock(initialState: 0)
            var beats: [(Int, Int)] = []
            _ = try await run(
                windows: windows,
                respond: { _, _, _ in
                    calls.withLock { $0 += 1 }
                    return Self.partial
                },
                onCall: { beats.append(($0, $1)) }
            )
            let planned = AppleIntelligenceSummarizer.plannedCalls(windows: windows, reduceBatch: 4)
            XCTAssertEqual(calls.withLock { $0 }, planned, "\(windows) windows")
            XCTAssertEqual(beats.map(\.0), Array(0..<planned), "\(windows) windows")
            XCTAssertTrue(beats.allSatisfy { $0.1 == planned })
        }
    }

    /// A Cancel during a call lets that call finish (nothing can interrupt it) and stops the
    /// loop before the next one, as a cancellation, not as a fault.
    func test_a_cancel_during_the_map_loop_stops_before_the_next_call() async throws {
        let gate = TestGate()
        gates.append(gate)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let inFirstCall = expectation(description: "first call running")
        let task = Task {
            try await self.run(windows: 5, respond: { _, _, _ in
                if calls.withLock({ $0 += 1; return $0 }) == 1 {
                    inFirstCall.fulfill()
                    await gate.wait()
                }
                return Self.partial
            })
        }
        await fulfillment(of: [inFirstCall], timeout: 2)
        task.cancel()
        gate.open()
        do {
            _ = try await task.value
            XCTFail("a cancelled summarize must not produce a summary")
        } catch {
            XCTAssertTrue(PipelineLauncher.isCancellation(error), "\(error)")
        }
        XCTAssertEqual(calls.withLock { $0 }, 1, "no call after the click")
    }

    /// A call past the ceiling fails `.timedOut`, which PIPE25's fallback must not read as a
    /// deterministic backend failure, and which is not a cancellation either.
    func test_a_call_past_the_ceiling_fails_timed_out() async throws {
        let gate = TestGate()
        gates.append(gate)
        do {
            _ = try await run(windows: 3, ceiling: 0.2, respond: { _, _, _ in
                await gate.wait()
                return Self.partial
            })
            XCTFail("expected the ceiling to fire")
        } catch let error as AppleIntelligenceError {
            guard case .timedOut(let seconds) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(seconds, 0.2)
            XCTAssertFalse(error.isDeterministicBackendFailure, "a hang is not the transcript's fault")
            XCTAssertFalse(PipelineLauncher.isCancellation(error))
            XCTAssertTrue(
                FailurePresentation(diagnostics: error.localizedDescription).explanation
                    .contains(error.localizedDescription),
                "the row shows the reason as written"
            )
        }
    }

    /// A failure is a failure: an error from one call propagates as itself.
    func test_a_failed_call_propagates_its_own_error() async throws {
        struct Boom: Error {}
        do {
            _ = try await run(windows: 2, respond: { _, _, _ in throw Boom() })
            XCTFail("expected Boom")
        } catch {
            XCTAssertTrue(error is Boom, "\(error)")
        }
    }

    func test_the_ceiling_is_at_least_twenty_times_the_slowest_measured_call() {
        XCTAssertGreaterThanOrEqual(AppleIntelligenceSummarizer.callCeilingSeconds, 20 * 7.2)
        XCTAssertEqual(AppleIntelligenceSummarizer().callCeilingSeconds, AppleIntelligenceSummarizer.callCeilingSeconds)
    }
}
