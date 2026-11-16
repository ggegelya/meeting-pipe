import XCTest
@testable import MeetingPipe

/// PIPE41: the one bounded automatic re-run of a failed summarize job. The policy, the bound's store, the
/// pickup and the launch notice are pure over injected inputs; the wiring (that the real failure branch marks,
/// and that both triggers pick up) is pinned in `SinkDispatcherTests`, `PipelineJobDispatcherTests` and the
/// source fence at the bottom, because END9 shipped 28 green tests over a watcher nothing ever started.
final class AutoRetryTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-autoretry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func store() -> AutoRetryStore { AutoRetryStore(url: dir.appendingPathComponent("auto_retry.json")) }

    private func retryable(cause: FailureMetadata.Cause = .timeout, remedy: String? = "retry") -> FailureMetadata {
        FailureMetadata(cause: cause, operation: .summary, remedy: remedy)
    }

    // MARK: - Eligibility, decided at failure time

    func test_eligibility_matrix() {
        let ok = retryable()
        XCTAssertTrue(AutoRetryEligibility.isEligible(kind: .full, summaryMode: .auto, stage: .pipeline, metadata: ok))
        // A BYO meeting is never re-run (REC2's no-auto-egress posture).
        XCTAssertFalse(AutoRetryEligibility.isEligible(kind: .full, summaryMode: .byo, stage: .pipeline, metadata: ok))
        XCTAssertFalse(AutoRetryEligibility.isEligible(kind: .retranscribe, summaryMode: .auto, stage: .pipeline, metadata: ok))
        XCTAssertFalse(AutoRetryEligibility.isEligible(
            kind: .libraryRun(LibraryRun(verb: .regenerate, stem: "m", backend: nil)),
            summaryMode: .auto, stage: .pipeline, metadata: ok))
        // Only the pipeline stage; every other stage is the owner's.
        for stage in [PipelineFailureSidecar.Stage.transcribe, .publish, .launch, .interrupted, .memory] {
            XCTAssertFalse(AutoRetryEligibility.isEligible(kind: .full, summaryMode: .auto, stage: stage, metadata: ok), "\(stage)")
        }
        // The remedy is the pipeline's own claim that a retry helps.
        for remedy in ["billing", "integrations", "model", nil] as [String?] {
            XCTAssertFalse(AutoRetryEligibility.isEligible(
                kind: .full, summaryMode: .auto, stage: .pipeline,
                metadata: retryable(cause: .credits, remedy: remedy)), "\(remedy ?? "nil")")
        }
        XCTAssertFalse(AutoRetryEligibility.isEligible(kind: .full, summaryMode: .auto, stage: .pipeline, metadata: nil))
    }

    // MARK: - The bound

    func test_the_bound_is_spent_once_and_survives_a_relaunch() {
        let s = store()
        XCTAssertTrue(s.markEligible(stem: "m", failedAt: "2026-10-22T07:49:57Z"))
        XCTAssertFalse(s.markEligible(stem: "m", failedAt: "2026-10-22T07:49:57Z"), "the same failure is not marked twice")
        XCTAssertTrue(s.claim(stem: "m"))
        XCTAssertFalse(s.claim(stem: "m"), "one re-run, spent once")

        // A failure produced by the re-run itself comes back through the same branch: not marked again.
        XCTAssertFalse(s.markEligible(stem: "m", failedAt: "2026-10-22T07:52:00Z"))

        // The whole store is re-read from disk, as a relaunch does.
        let relaunched = store()
        XCTAssertFalse(relaunched.markEligible(stem: "m", failedAt: "2026-11-14T09:00:00Z"))
        XCTAssertTrue(relaunched.pending().isEmpty)
        relaunched.dropPending(stem: "m")
        XCTAssertEqual(relaunched.entries["m"]?.state, .spent, "dropping a pending entry never forgets a spent one")
    }

    func test_a_pending_entry_survives_a_relaunch_and_is_dropped_when_it_succeeds() {
        let s = store()
        s.markEligible(stem: "m", failedAt: "t1")
        XCTAssertEqual(store().pending().map(\.stem), ["m"])
        s.dropPending(stem: "m")
        XCTAssertTrue(store().pending().isEmpty)
    }

    func test_prune_forgets_a_meeting_with_no_files_left() {
        let s = store()
        s.markEligible(stem: "gone", failedAt: "t1")
        s.markEligible(stem: "kept", failedAt: "t2")
        s.prune(keepingStems: ["kept"])
        XCTAssertEqual(store().entries.keys.sorted(), ["kept"])
    }

    // MARK: - The pickup

    private func failure(stage: PipelineFailureSidecar.Stage = .pipeline, ts: String) -> PipelineFailureSidecar.Failure {
        PipelineFailureSidecar.Failure(stage: stage, reason: "r", ts: ts)
    }

    func test_an_eligible_stem_is_re_run_once_at_the_next_launch_and_never_again() {
        let s = store()
        s.markEligible(stem: "m", failedAt: "t1")
        var retries: [String] = []
        func pass(_ store: AutoRetryStore) -> [String] {
            AutoRetryPass.run(
                store: store, readFailure: { _ in self.failure(ts: "t1") }, hasSummary: { _ in false },
                retry: { retries.append($0); return .success(()) })
        }
        XCTAssertEqual(pass(s), ["m"])
        XCTAssertEqual(retries, ["m"])

        // The re-run fails: the same branch that marks eligible runs again and refuses.
        XCTAssertFalse(s.markEligible(stem: "m", failedAt: "t2"))
        // The next launch, and the one after a later successful job, both see nothing pending.
        XCTAssertEqual(pass(store()), [], "a simulated relaunch re-reads the store from disk")
        XCTAssertEqual(pass(s), [])
        XCTAssertEqual(retries, ["m"], "one re-run in all")
    }

    func test_the_entry_is_spent_before_the_re_run_starts() {
        let s = store()
        s.markEligible(stem: "m", failedAt: "t1")
        var spentWhenRetryRan: Bool?
        AutoRetryPass.run(
            store: s, readFailure: { _ in self.failure(ts: "t1") }, hasSummary: { _ in false },
            retry: { stem in
                // What a crash inside the re-run would leave behind on disk.
                spentWhenRetryRan = self.store().entries[stem]?.state == .spent
                return .success(())
            })
        XCTAssertEqual(spentWhenRetryRan, true)
    }

    func test_a_failure_that_changed_or_went_is_dropped_not_re_run() {
        func outcome(_ f: PipelineFailureSidecar.Failure?, summary: Bool = false) -> (started: [String], skips: [AutoRetryPass.Skip], pending: Int) {
            let s = AutoRetryStore(url: dir.appendingPathComponent(UUID().uuidString + ".json"))
            s.markEligible(stem: "m", failedAt: "t1")
            var skips: [AutoRetryPass.Skip] = []
            let started = AutoRetryPass.run(
                store: s, readFailure: { _ in f }, hasSummary: { _ in summary },
                retry: { _ in .success(()) }, onSkip: { skips.append($1) })
            return (started, skips, s.pending().count)
        }
        XCTAssertEqual(outcome(nil).skips, [.failureGone], "the owner retried or deleted it")
        XCTAssertEqual(outcome(failure(stage: .publish, ts: "t1")).skips, [.notPipelineStage])
        XCTAssertEqual(outcome(failure(ts: "t9")).skips, [.differentFailure])
        XCTAssertEqual(outcome(failure(ts: "t1"), summary: true).skips, [.summaryExists])
        for o in [outcome(nil), outcome(failure(ts: "t9"))] {
            XCTAssertTrue(o.started.isEmpty)
            XCTAssertEqual(o.pending, 0, "a skipped entry is dropped, not left to fire later")
        }
    }

    func test_pending_stems_run_oldest_failure_first() {
        let s = store()
        s.markEligible(stem: "b", failedAt: "2026-11-02T00:00:00Z")
        s.markEligible(stem: "a", failedAt: "2026-11-01T00:00:00Z")
        XCTAssertEqual(AutoRetryPass.run(
            store: s, readFailure: { stem in self.failure(ts: stem == "a" ? "2026-11-01T00:00:00Z" : "2026-11-02T00:00:00Z") },
            hasSummary: { _ in false }, retry: { _ in .success(()) }), ["a", "b"])
    }

    func test_a_refused_re_run_is_spent_logged_and_not_counted_as_started() {
        let s = store()
        s.markEligible(stem: "m", failedAt: "t1")
        var skips: [AutoRetryPass.Skip] = []
        let started = AutoRetryPass.run(
            store: s, readFailure: { _ in self.failure(ts: "t1") }, hasSummary: { _ in false },
            retry: { _ in .failure(NSError(domain: "t", code: 1)) }, onSkip: { skips.append($1) })
        XCTAssertTrue(started.isEmpty)
        XCTAssertEqual(skips, [.refused])
        XCTAssertEqual(s.entries["m"]?.state, .spent, "one attempt, even a refused one")
    }

    // MARK: - The launch pass as one unit (injected clock, files and retry)

    private let launchNow = ISO8601DateFormatter().date(from: "2026-11-16T12:00:00Z")!

    func test_the_launch_pass_re_runs_once_and_notices_only_what_nothing_will_re_run() {
        let s = store()
        s.markEligible(stem: "eligible", failedAt: "2026-11-10T00:00:00Z")           // re-run now
        var retried: [String] = []
        let result = AutoRetryPass.launch(
            store: s,
            snapshot: .init(names: ["eligible.error.json", "old.error.json", "fresh.error.json", "eligible.md"],
                            failures: [
                                (stem: "eligible", ts: "2026-11-10T00:00:00Z"),
                                (stem: "old", ts: "2026-11-01T00:00:00Z"),          // a day or more, nothing pending
                                (stem: "fresh", ts: "2026-11-16T08:00:00Z"),        // under a day
                            ]),
            now: launchNow,
            readFailure: { stem in stem == "eligible" ? self.failure(ts: "2026-11-10T00:00:00Z") : nil },
            hasSummary: { _ in false },
            retry: { retried.append($0); return .success(()) })
        XCTAssertEqual(retried, ["eligible"])
        XCTAssertEqual(result.started, ["eligible"])
        XCTAssertEqual(result.unresolved, ["old"], "the one whose re-run just started is not counted, nor is a fresh failure")
    }

    func test_the_notice_leaves_out_a_failure_whose_spent_re_run_is_still_the_one_on_disk() {
        // A successful job earlier in this launch already started the re-run; on the summary path its error
        // sidecar (same ts) stays until the run finishes, and a notice for it would be wrong.
        let s = store()
        s.markEligible(stem: "m", failedAt: "2026-11-01T00:00:00Z")
        XCTAssertTrue(s.claim(stem: "m"))
        var retried = 0
        let result = AutoRetryPass.launch(
            store: s, snapshot: .init(names: ["m.error.json"], failures: [(stem: "m", ts: "2026-11-01T00:00:00Z")]),
            now: launchNow, readFailure: { _ in nil }, hasSummary: { _ in false },
            retry: { _ in retried += 1; return .success(()) })
        XCTAssertEqual(retried, 0)
        XCTAssertTrue(result.unresolved.isEmpty)

        // The re-run failed and rewrote the sidecar: a new ts, so the owner is told once it is a day old.
        let later = AutoRetryPass.launch(
            store: s, snapshot: .init(names: ["m.error.json"], failures: [(stem: "m", ts: "2026-11-05T00:00:00Z")]),
            now: launchNow, readFailure: { _ in nil }, hasSummary: { _ in false },
            retry: { _ in .success(()) })
        XCTAssertEqual(later.unresolved, ["m"])
    }

    func test_a_listing_that_failed_does_not_wipe_the_bound() {
        let s = store()
        s.markEligible(stem: "spent", failedAt: "t1")
        XCTAssertTrue(s.claim(stem: "spent"))
        s.markEligible(stem: "waiting", failedAt: "t2")
        _ = AutoRetryPass.launch(
            store: s, snapshot: .init(names: nil, failures: []), now: launchNow,
            readFailure: { _ in nil }, hasSummary: { _ in false }, retry: { _ in .success(()) })
        XCTAssertEqual(s.entries["spent"]?.state, .spent, "an unreadable folder is not a folder with no meetings")
        // And a listing that worked does forget a meeting with no files left.
        _ = AutoRetryPass.launch(
            store: s, snapshot: .init(names: ["waiting.error.json"], failures: []), now: launchNow,
            readFailure: { _ in nil }, hasSummary: { _ in false }, retry: { _ in .success(()) })
        XCTAssertNil(s.entries["spent"])
    }

    func test_an_unreadable_store_is_moved_aside_not_overwritten() throws {
        let url = dir.appendingPathComponent("auto_retry.json")
        try Data("not json".utf8).write(to: url)
        let s = AutoRetryStore(url: url)
        XCTAssertTrue(s.entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
    }

    // MARK: - The launch notice

    func test_notice_counts_failures_a_day_old_with_no_re_run_left() {
        let now = ISO8601DateFormatter().date(from: "2026-11-16T12:00:00Z")!
        let stems = UnresolvedFailureNotice.stems(
            failures: [
                (stem: "old", ts: "2026-11-10T12:00:00Z"),
                (stem: "older", ts: "2026-10-22T07:49:57Z"),
                (stem: "fresh", ts: "2026-11-16T09:00:00Z"),       // under a day: still the owner's to notice
                (stem: "boundary", ts: "2026-11-15T12:00:00Z"),    // exactly 24 h counts
                (stem: "rerunning", ts: "2026-11-10T12:00:00Z"),   // its re-run just started
                (stem: "unreadable", ts: "not a date"),
            ],
            excluding: ["rerunning"], now: now)
        XCTAssertEqual(stems, ["older", "old", "boundary"], "oldest first")
    }

    func test_notice_is_silent_when_every_old_failure_is_resolved_or_pending() {
        let now = ISO8601DateFormatter().date(from: "2026-11-16T12:00:00Z")!
        XCTAssertTrue(UnresolvedFailureNotice.stems(failures: [], excluding: [], now: now).isEmpty)
        XCTAssertTrue(UnresolvedFailureNotice.stems(
            failures: [(stem: "p", ts: "2026-10-01T00:00:00Z")], excluding: ["p"], now: now).isEmpty)
    }

    // MARK: - Who asked

    func test_only_the_automatic_re_run_adds_a_trigger_to_retry_requested() {
        XCTAssertEqual(MeetingLibraryService.RetryTrigger.auto.attributes["trigger"] as? String, "auto")
        XCTAssertTrue(MeetingLibraryService.RetryTrigger.user.attributes.isEmpty,
                      "the Library's Retry keeps logging the row it always did")
    }

    // MARK: - Wiring (END9: a component that only works if somebody calls it)

    /// The Coordinator is not constructible in a test, so this fences the calling: the launch pass is armed
    /// after the stranded-job reconcile, the success trigger runs the pass, and the store is handed to the
    /// dispatcher that decides eligibility.
    func test_the_coordinator_arms_both_triggers_and_hands_the_store_to_the_dispatcher() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe/Coordinator.swift"), encoding: .utf8)
        let reconcile = try XCTUnwrap(source.range(of: "        reconcileStrandedJobs()\n"))
        let arm = try XCTUnwrap(source.range(of: "scheduleLaunchAutoRetry()"))
        XCTAssertLessThan(reconcile.lowerBound, arm.lowerBound, "the launch pass is armed after the reconcile")
        XCTAssertTrue(source.contains("onJobSucceeded: { [weak self] in\n                self?.runAutoRetry()"),
                      "a successful job runs the pass")
        XCTAssertTrue(source.contains("sinkDispatcher.autoRetryStore = autoRetryStore"),
                      "the dispatcher that decides eligibility is given the store")
        let retryExtension = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe/Coordinator+AutoRetry.swift"), encoding: .utf8)
        XCTAssertTrue(retryExtension.contains("retryMeeting(stem: stem, trigger: .auto)"),
                      "the re-run goes through the Library's Retry, not a second path")
    }
}
