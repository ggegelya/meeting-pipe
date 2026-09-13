import XCTest
@testable import MeetingPipe

/// LOCAL20: cancelling a model download reported it as failed, and a failed download had no exit
/// but Retry.
///
/// The owner's daemon log is the fixture and it settles the question on its own:
///
/// ```
/// [2026-08-04T15:00:14.626Z] model prefetch terminated rc=15 state=failed(... error: "prefetch exited 15")
/// ```
///
/// `rc=15` is SIGTERM, which is precisely what `cancel()` sends. Nothing failed. The prefetch ran
/// about three minutes of healthy traffic and was killed when the owner switched the backend back
/// to Anthropic, 99 seconds before they screenshotted a failure banner they could not discard. The
/// banner was manufactured by the act of switching away.
///
/// `cancel()` cleared `process` but left `state` at `.downloading`, and the termination handler
/// tested only that state and a non-zero status, so SIGTERM read as evidence of failure.
final class ModelDownloadCancelTests: XCTestCase {

    private typealias S = ModelDownloadSupervisor
    private let modelId = "mlx-community/Ministral-8B-Instruct-2410-4bit"
    private let otherModel = "mlx-community/Qwen2.5-7B-Instruct-4bit"

    private func downloading(_ id: String) -> S.State {
        .downloading(modelId: id, progress: 0.4, downloadedBytes: 1, totalBytes: 2)
    }

    // MARK: - The reported defect

    /// SIGTERM after a cancel must write nothing. The process is no longer tracked (`cancel()` nils
    /// it), which is the fact the old handler never consulted.
    func test_a_sigterm_after_cancel_is_not_a_failure() {
        let outcome = S.terminationOutcome(
            isTrackedProcess: false,
            state: downloading(modelId),
            terminationStatus: 15
        )
        XCTAssertEqual(outcome, .ignore, "rc=15 after a cancel is the cancel, not a failure")
    }

    /// The abandoned-process case, reachable today and never reported: `ensure` with a different
    /// model calls `cancel()` then `spawn()`, so the old process's termination arrives while a new
    /// download is live. It must not write `.failed` over the running one, and it must not tear
    /// down its handles either, which is why the outcome is `.ignore` rather than a softer verdict.
    func test_an_abandoned_process_cannot_fail_the_download_that_replaced_it() {
        let outcome = S.terminationOutcome(
            isTrackedProcess: false,
            state: downloading(otherModel),
            terminationStatus: 15
        )
        XCTAssertEqual(
            outcome, .ignore,
            "the previous model's death must not report the new download as failed"
        )
    }

    /// The fix must not blind the real case: a tracked process that exits non-zero with no stdout
    /// event to explain it is a genuine failure and still says so.
    func test_a_genuine_non_zero_exit_still_fails() {
        let outcome = S.terminationOutcome(
            isTrackedProcess: true,
            state: downloading(modelId),
            terminationStatus: 1
        )
        XCTAssertEqual(outcome, .fail(modelId: modelId, error: "prefetch exited 1"))
    }

    /// A clean exit is not a failure, and a terminal state a stdout event already wrote is left
    /// alone rather than overwritten by the exit code.
    func test_a_clean_exit_and_an_already_terminal_state_are_left_alone() {
        XCTAssertEqual(
            S.terminationOutcome(isTrackedProcess: true, state: downloading(modelId), terminationStatus: 0),
            .keep
        )
        XCTAssertEqual(
            S.terminationOutcome(
                isTrackedProcess: true,
                state: .failed(modelId: modelId, error: "out of disk"),
                terminationStatus: 1
            ),
            .keep,
            "the stdout event's error is the better one; the exit code must not replace it"
        )
        XCTAssertEqual(
            S.terminationOutcome(
                isTrackedProcess: true, state: .completed(modelId: modelId), terminationStatus: 0
            ),
            .keep
        )
    }

    // MARK: - Cancel leaves an honest state

    /// The other half of the fix. A supervisor that still believes it is downloading is what made
    /// the late SIGTERM plausible in the first place.
    func test_cancel_leaves_the_supervisor_idle() {
        let supervisor = S()
        var seen: [S.State] = []
        supervisor.onStateChange = { seen.append($0) }

        supervisor.cancel()
        XCTAssertEqual(supervisor.state, .idle)
        XCTAssertEqual(seen, [], "cancelling an idle supervisor is not a state change")
    }

    /// The staleness rule the spec asked for, and the owner's exact route out: switching to a
    /// non-local backend takes `.cancelAndIdle`, which cancels, and a failure for a model the app
    /// is no longer configured to use does not survive that.
    func test_cancel_clears_a_failure_for_a_model_being_switched_away_from() {
        let supervisor = S(state: .failed(modelId: modelId, error: "prefetch exited 15"))

        supervisor.cancel()

        XCTAssertEqual(
            supervisor.state, .idle,
            "a failure for a model no longer configured is stale by definition"
        )
    }

    // MARK: - A failure that is real and current

    /// Dismiss is the exit that is not Retry. Retry re-downloads the model, which is the wrong
    /// answer when the reason you want the banner gone is that you moved off that model.
    func test_a_failure_can_be_dismissed_without_retrying() {
        let supervisor = S(state: .failed(modelId: modelId, error: "network unreachable"))

        supervisor.dismissFailure()

        XCTAssertEqual(supervisor.state, .idle)
    }

    /// Dismiss is only for a notice. An in-flight download is not one, and `.completed` already
    /// collapses on its own, so neither may be cleared this way.
    func test_dismiss_only_applies_to_a_failure() {
        let running = S(state: downloading(modelId))
        running.dismissFailure()
        XCTAssertEqual(running.state, downloading(modelId), "a running download is not a notice")

        let done = S(state: .completed(modelId: modelId))
        done.dismissFailure()
        XCTAssertEqual(done.state, .completed(modelId: modelId))
    }

    // MARK: - What the menu and the title do with it

    /// The failed row keeps Retry and gains the second exit.
    func test_the_failed_row_offers_both_retry_and_dismiss() throws {
        let row = try XCTUnwrap(
            StatusBarModel.downloadRow(.failed(modelId: modelId, error: "prefetch exited 1"))
        )
        guard case .modelDownload(let title, let retryable, let toolTip, let dismissible) = row else {
            return XCTFail("expected a model-download row, got \(row)")
        }
        XCTAssertTrue(title.contains("Model download failed"))
        XCTAssertTrue(retryable, "LOCAL1's retry stays; a real failure is worth retrying")
        XCTAssertTrue(dismissible, "and it must be clearable without re-downloading the model")
        XCTAssertEqual(toolTip, "Retry when you are ready, or open Details to inspect the failure.")
    }

    /// Nothing else is dismissible: a download in flight and a finished one are not notices to
    /// clear, and offering the row would suggest cancelling is what it does.
    func test_only_the_failed_row_is_dismissible() throws {
        for state in [downloading(modelId), .completed(modelId: modelId)] as [S.State] {
            let row = try XCTUnwrap(StatusBarModel.downloadRow(state))
            guard case .modelDownload(_, _, _, let dismissible) = row else {
                return XCTFail("expected a model-download row, got \(row)")
            }
            XCTAssertFalse(dismissible, "\(state) is not a notice to dismiss")
        }
        XCTAssertNil(StatusBarModel.downloadRow(.idle), "idle shows no row at all")
    }

    /// The second-order cost named in the spec. `applyTitle` gives the download clause priority
    /// over the processing clause while idle, so a phantom failure spent the menu bar's one clause
    /// on the untrue thing: the owner's screenshot showed `↓ failed` above "24 meetings failed".
    /// Clearing the failure has to give the processing clause back.
    func test_clearing_the_failure_returns_the_title_to_the_processing_clause() {
        let queue = QueueActivity(depth: 3, isRunning: true)

        let withFailure = StatusBarModel.title(.init(
            state: .idle, queue: queue,
            download: .failed(modelId: modelId, error: "prefetch exited 15")
        ))
        XCTAssertEqual(withFailure, " ↓ failed", "the download clause wins while it is there")

        let cleared = StatusBarModel.title(.init(state: .idle, queue: queue, download: .idle))
        XCTAssertEqual(cleared, " Processing (3)", "and the processing clause is reachable again")
    }
}
