import XCTest
@testable import MeetingPipe

/// UX37: the Ask run lives on the model, not on the view that started it.
///
/// Every test here simulates the thing that used to lose an answer: the view is
/// never constructed at all, so what survives is exactly what a rail switch
/// leaves behind. Before this the run's whole state was `@State` on `AskView`,
/// so switching to Facts destroyed it while the subprocess kept running.
@MainActor
final class AskModelTests: XCTestCase {

    /// Records what the model asked for and parks each completion, so a test
    /// decides when (and whether) an answer lands. Main-actor isolated by its
    /// conformance to `AskRunning`, which makes every read below race-free.
    private final class FakeRunner: AskRunning {
        private(set) var questions: [String] = []
        private(set) var cancelCalls = 0
        private var parked: [CheckedContinuation<Result<AskAnswer, Error>, Never>] = []

        /// True once a spawn has reached this runner and is waiting on an answer.
        var isRunning: Bool { !parked.isEmpty }

        func askMeetings(question: String) async -> Result<AskAnswer, Error> {
            questions.append(question)
            return await withCheckedContinuation { parked.append($0) }
        }

        func cancelAsk() { cancelCalls += 1 }

        /// Land the oldest parked run.
        func deliver(_ result: Result<AskAnswer, Error>) {
            guard !parked.isEmpty else { return }
            parked.removeFirst().resume(returning: result)
        }
    }

    private enum RunnerError: Error, LocalizedError {
        case killed
        var errorDescription: String? { "mp ask exited with status 15" }
    }

    /// Holds the deeplink's pending question the way `LibraryWindowModel` does,
    /// so a test can watch when it is cleared.
    private final class PendingBox {
        var question: String?
        init(_ q: String?) { question = q }
    }

    private var runner: FakeRunner!
    private var model: AskModel!

    override func setUp() {
        super.setUp()
        runner = FakeRunner()
        model = AskModel(runner: runner)
    }

    // MARK: - Helpers

    /// Give the model's unstructured `Task` (and a delivered completion) a turn
    /// on the main actor. Bounded so a broken expectation fails the assertion
    /// rather than hanging the suite.
    private func pump(until condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
        }
    }

    /// Yield a few times where there is nothing to wait *for*: proving that
    /// something did NOT happen needs the runway it would have happened in.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func answer(_ text: String, error: String? = nil) -> AskAnswer {
        AskAnswer(
            question: "q",
            answer: text,
            citations: [],
            sourcesConsidered: [],
            backend: "local",
            model: nil,
            verified: true,
            empty: false,
            error: error
        )
    }

    // MARK: - Surviving the view

    func testAnswerLandsOnTheModelAfterTheViewIsGone() async {
        model.question = "what did we decide about the budget?"
        XCTAssertTrue(model.ask())
        await pump { runner.isRunning }
        XCTAssertTrue(model.isAsking, "the run should be visible as in flight")

        // The rail switched here: no view exists, and the completion arrives anyway.
        runner.deliver(.success(answer("we deferred it to Q3")))
        await pump { !model.isAsking }

        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.latest?.question, "what did we decide about the budget?")
        XCTAssertEqual(model.latest?.answer?.answer, "we deferred it to Q3")
        XCTAssertNil(model.latest?.errorText)
    }

    func testQuestionTextSurvivesTheRun() async {
        model.question = "  hiring plan  "
        XCTAssertTrue(model.ask())
        await pump { runner.isRunning }
        // Trimmed on the way to the subprocess, untouched in the field.
        XCTAssertEqual(runner.questions, ["hiring plan"])
        XCTAssertEqual(model.question, "  hiring plan  ")
    }

    func testBlankQuestionNeverSpawns() async {
        model.question = "   \n "
        XCTAssertFalse(model.ask())
        await settle()
        XCTAssertTrue(runner.questions.isEmpty)
        XCTAssertFalse(model.isAsking)
    }

    // MARK: - One at a time

    /// The recorded decision for UX37: a second ask while one runs is refused,
    /// neither queued nor swapped in. Cancel is the explicit way to make room.
    func testSecondAskWhileOneRunsIsRefused() async {
        XCTAssertTrue(model.ask("first question"))
        await pump { runner.isRunning }

        XCTAssertFalse(model.ask("second question"))
        await settle()

        XCTAssertEqual(runner.questions, ["first question"])
        XCTAssertEqual(model.inFlight?.question, "first question")
        // A refused ask leaves the field alone rather than half-applying itself.
        XCTAssertEqual(model.question, "first question")
    }

    // MARK: - Cancel

    func testCancelReachesTheRunnerAndNamesTheOutcome() async {
        XCTAssertTrue(model.ask("something slow"))
        await pump { runner.isRunning }

        model.cancel()

        XCTAssertEqual(runner.cancelCalls, 1, "cancel has to reach the launcher's ask process")
        XCTAssertFalse(model.isAsking)
        XCTAssertEqual(model.latest?.wasCancelled, true)
        XCTAssertEqual(model.latest?.question, "something slow")
    }

    func testTheKilledRunsLateFailureDoesNotOverwriteTheCancel() async {
        XCTAssertTrue(model.ask("something slow"))
        await pump { runner.isRunning }
        model.cancel()

        // Terminating the subprocess makes `runMP` report a non-zero exit. That
        // is the user's own kill coming back, and it must not land as an error.
        runner.deliver(.failure(RunnerError.killed))
        await settle()

        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.latest?.wasCancelled, true)
        XCTAssertNil(model.latest?.errorText)
    }

    func testCancelWithNothingRunningIsANoOp() async {
        model.cancel()
        XCTAssertEqual(runner.cancelCalls, 0)
        XCTAssertTrue(model.history.isEmpty)
    }

    func testAskIsAllowedAgainAfterACancel() async {
        XCTAssertTrue(model.ask("first"))
        await pump { runner.isRunning }
        model.cancel()

        XCTAssertTrue(model.ask("second"))
        await pump { runner.questions.count == 2 }
        XCTAssertEqual(runner.questions, ["first", "second"])
    }

    // MARK: - Failure shapes

    func testEngineRefusalIsAFailedOutcomeNotAnEmptyAnswer() async {
        XCTAssertTrue(model.ask("anything"))
        await pump { runner.isRunning }

        // `mp ask` reports an engine-level refusal as a successful run carrying
        // a non-empty `error`; both shapes have to read as one failed outcome.
        runner.deliver(.success(answer("", error: "the index is still building")))
        await pump { !model.isAsking }

        XCTAssertEqual(model.latest?.errorText, "the index is still building")
        XCTAssertNil(model.latest?.answer)
    }

    func testSpawnFailureIsRecordedAsFailed() async {
        XCTAssertTrue(model.ask("anything"))
        await pump { runner.isRunning }

        runner.deliver(.failure(RunnerError.killed))
        await pump { !model.isAsking }

        XCTAssertEqual(model.latest?.errorText, "mp ask exited with status 15")
    }

    // MARK: - Deeplink

    func testDeeplinkQuestionSurvivesAMountUnmountMountUntilItsRunCompletes() async {
        let pending = PendingBox("what did we say about hiring?")

        // Mount: the deeplink starts running.
        model.acceptDeeplink(pending.question) { pending.question = nil }
        await pump { runner.isRunning }
        XCTAssertEqual(model.question, "what did we say about hiring?")
        XCTAssertNotNil(pending.question, "consumed on render is what used to lose it")

        // Unmount, then mount again mid-run: the same still-pending question
        // arrives a second time and must not spawn a second subprocess.
        model.acceptDeeplink(pending.question) { pending.question = nil }
        await settle()
        XCTAssertEqual(runner.questions.count, 1)
        XCTAssertNotNil(pending.question)

        // The run finishes: only now is the deeplink consumed.
        runner.deliver(.success(answer("we agreed on two hires")))
        await pump { !model.isAsking }
        XCTAssertNil(pending.question)
        XCTAssertEqual(model.latest?.answer?.answer, "we agreed on two hires")
    }

    func testCancellingADeeplinkedRunConsumesItToo() async {
        let pending = PendingBox("slow question")
        model.acceptDeeplink(pending.question) { pending.question = nil }
        await pump { runner.isRunning }

        model.cancel()

        // Otherwise the next mount would re-run a question the user just stopped.
        XCTAssertNil(pending.question)
        XCTAssertEqual(model.latest?.wasCancelled, true)
    }

    func testEmptyDeeplinkIsIgnored() async {
        var consumed = false
        model.acceptDeeplink(nil) { consumed = true }
        model.acceptDeeplink("   ") { consumed = true }
        await settle()
        XCTAssertTrue(runner.questions.isEmpty)
        XCTAssertFalse(consumed)
        XCTAssertFalse(model.isAsking)
    }

    // MARK: - History

    func testHistoryIsNewestFirstAndCapped() async {
        let total = AskModel.historyLimit + 3
        for i in 0..<total {
            XCTAssertTrue(model.ask("q\(i)"))
            await pump { runner.isRunning }
            runner.deliver(.success(answer("a\(i)")))
            await pump { !model.isAsking }
        }

        XCTAssertEqual(model.history.count, AskModel.historyLimit)
        XCTAssertEqual(model.history.first?.question, "q\(total - 1)", "newest first")
        XCTAssertEqual(model.history.last?.question, "q\(total - AskModel.historyLimit)")
        XCTAssertEqual(model.latest?.answer?.answer, "a\(total - 1)")
    }
}
