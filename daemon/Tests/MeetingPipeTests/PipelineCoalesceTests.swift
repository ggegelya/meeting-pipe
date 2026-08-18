import XCTest
@testable import MeetingPipe

/// PIPE18: PIPE11's duplicate-click coalescing covered one enqueue path of three.
///
/// On 2026-08-14 the owner pressed **Retry pipeline** seven times in twelve seconds and got seven
/// full `mp run-all` passes queued for one 25-minute recording, then removed six by hand. Their
/// event log shows `pipeline_queued` at depths 1 through 7 and zero `pipeline_coalesced`, because
/// nothing on the `.full` path could emit one: the guard existed, on `enqueueLibraryRun` only.
///
/// The first click had already worked. That run started at 11:57:05 and succeeded at 11:58:11, so
/// every later click was made while the retry the owner wanted was already running, and the six
/// extra passes would each have re-transcribed and re-summarized over the sidecars the previous one
/// wrote, on a cloud backend, for a result already on disk.
final class PipelineCoalesceTests: XCTestCase {

    private typealias D = SinkDispatcher

    private func job(_ stem: String, kind: ProcessingJobKind = .full) -> ProcessingJob {
        ProcessingJob(
            id: UUID(),
            file: URL(fileURLWithPath: "/tmp/recordings/\(stem).wav"),
            summaryMode: .auto,
            startedAt: Date(),
            kind: kind
        )
    }

    private func libraryRun(_ stem: String, verb: LibraryRun.Verb, backend: String? = nil) -> ProcessingJobKind {
        .libraryRun(LibraryRun(verb: verb, stem: stem, backend: backend))
    }

    // MARK: - The reported defect

    /// The exact case. Against `main` the second `.full` reached the queue and the depth read 2.
    func test_a_second_full_job_for_the_same_stem_is_a_duplicate() {
        let queued = [job("20260813-170019")]
        XCTAssertTrue(
            D.isAlreadyQueued(job("20260813-170019"), in: queued),
            "seven Retry clicks on one meeting are one ask, not seven"
        )
    }

    /// The other unguarded kind, same rule.
    func test_a_second_retranscribe_for_the_same_stem_is_a_duplicate() {
        let queued = [job("20260813-170019", kind: .retranscribe)]
        XCTAssertTrue(D.isAlreadyQueued(job("20260813-170019", kind: .retranscribe), in: queued))
    }

    // MARK: - The guard is a coalescer, not a lockout

    /// The clause that makes this safe. The predicate only ever reads what is *in the queue*, so
    /// once a job has run and left, the same ask queues again. A fix that blocked the legitimate
    /// second attempt after a second failure would be worse than the bug.
    func test_the_same_ask_queues_again_once_the_queue_has_drained() {
        XCTAssertFalse(
            D.isAlreadyQueued(job("20260813-170019"), in: []),
            "an empty queue can never hold a duplicate"
        )
    }

    /// Per stem, not global. Coalescing the library into one job at a time would be a far worse
    /// bug than the one being fixed.
    func test_two_stems_both_queue() {
        let queued = [job("20260813-170019")]
        XCTAssertFalse(D.isAlreadyQueued(job("20260814-090000"), in: queued))
    }

    /// Different kinds are different work and both are wanted. A re-transcribe and a run-all on one
    /// meeting do different things, so neither may swallow the other.
    func test_different_kinds_on_one_stem_do_not_coalesce() {
        let stem = "20260813-170019"
        XCTAssertFalse(
            D.isAlreadyQueued(job(stem, kind: .retranscribe), in: [job(stem, kind: .full)]),
            "a re-transcribe is not a run-all"
        )
        XCTAssertFalse(
            D.isAlreadyQueued(job(stem, kind: .full), in: [job(stem, kind: .retranscribe)])
        )
        XCTAssertFalse(
            D.isAlreadyQueued(
                job(stem, kind: libraryRun(stem, verb: .regenerate)),
                in: [job(stem, kind: .full)]
            )
        )
    }

    // MARK: - PIPE11's identity survives being folded in

    /// PIPE11's rule was `(verb, stem, backend)`, and folding its guard onto the shared predicate
    /// must not widen it. Local-then-Anthropic is two asks the owner deliberately made.
    func test_a_library_run_still_keys_on_verb_stem_and_backend() {
        let stem = "20260813-170019"
        let local = job(stem, kind: libraryRun(stem, verb: .regenerate, backend: "local"))
        let cloud = job(stem, kind: libraryRun(stem, verb: .regenerate, backend: "anthropic"))
        let republish = job(stem, kind: libraryRun(stem, verb: .republish, backend: "local"))

        XCTAssertTrue(D.isAlreadyQueued(local, in: [local]), "the identical ask still coalesces")
        XCTAssertFalse(
            D.isAlreadyQueued(cloud, in: [local]),
            "a different backend is a different ask; PIPE11 chose that deliberately"
        )
        XCTAssertFalse(D.isAlreadyQueued(republish, in: [local]), "a different verb is a different ask")
    }

    /// Same run, different meeting.
    func test_a_library_run_on_another_stem_is_not_a_duplicate() {
        let a = job("a", kind: libraryRun("a", verb: .regenerate))
        let b = job("b", kind: libraryRun("b", verb: .regenerate))
        XCTAssertFalse(D.isAlreadyQueued(b, in: [a]))
    }

    /// Identity for the two file-shaped kinds is the recording itself, not its basename. The first
    /// draft of this guard compared `lastPathComponent`, which looks equivalent because one
    /// directory holds every recording under a timestamp stem, and is not: two files named
    /// `clip.wav` under different parents are different recordings. `SinkDispatcherTests` builds
    /// exactly that shape from per-test temp directories and caught it.
    func test_the_same_basename_under_a_different_parent_is_a_different_recording() {
        let a = ProcessingJob(
            id: UUID(), file: URL(fileURLWithPath: "/tmp/mp-sink-A/clip.wav"),
            summaryMode: .auto, startedAt: Date(), kind: .full
        )
        let b = ProcessingJob(
            id: UUID(), file: URL(fileURLWithPath: "/tmp/mp-sink-B/clip.wav"),
            summaryMode: .auto, startedAt: Date(), kind: .full
        )
        XCTAssertFalse(
            D.isAlreadyQueued(b, in: [a]),
            "a shared basename is not a shared meeting"
        )
        XCTAssertTrue(D.isAlreadyQueued(a, in: [a]), "the same recording still coalesces")
    }

    /// `stem(of:)` stays the log's vocabulary, matching `pendingJobs`, and is not what the guard
    /// keys on.
    func test_the_stem_helper_reads_the_timestamp_name() {
        XCTAssertEqual(
            D.stem(of: URL(fileURLWithPath: "/tmp/recordings/20260813-170019.wav")),
            "20260813-170019"
        )
    }
}

/// PIPE18's other half. Coalescing makes the burst harmless; this is what stops it happening.
///
/// The window already contradicted itself: the detail header rendered `Queued: Reprocess` with a
/// working Remove while the Summary pane, about 200 points below, still said `Pipeline failed` and
/// offered `Retry pipeline`. Both now read one `ProcessingPresentation`.
final class RetryAffordanceTests: XCTestCase {

    private func queued(_ label: String = "Reprocess") -> ProcessingPresentation {
        .queued(QueuedJob(id: UUID(), stem: "20260813-170019", label: label))
    }

    private func active() -> ProcessingPresentation {
        .active(ActiveProcessing(stem: "20260813-170019", stage: "transcribe", elapsedSec: 12, stalled: false))
    }

    /// The reported case: a queued job for this meeting means there is nothing to ask for.
    func test_retry_is_not_offered_while_a_job_is_queued() {
        let affordance = RetryAffordance.decide(processing: queued())
        XCTAssertFalse(affordance.isOffered)
        XCTAssertEqual(affordance, .inFlight(label: "Queued: Reprocess"))
    }

    /// And the case the owner was actually in for six of the seven clicks: the run was already
    /// going. It had started 5 seconds before the second click and finished 66 seconds in.
    func test_retry_is_not_offered_while_a_job_is_active() {
        XCTAssertFalse(RetryAffordance.decide(processing: active()).isOffered)
    }

    /// Idle is the only state that offers it, so a genuine retry after a failure still works.
    func test_retry_is_offered_when_nothing_is_in_flight() {
        XCTAssertEqual(RetryAffordance.decide(processing: .idle), .offer)
        XCTAssertTrue(RetryAffordance.decide(processing: .idle).isOffered)
    }

    /// The label is the row's own, not a second wording. That is the whole point of deriving it:
    /// the header said `Queued: Reprocess` while the pane said `Pipeline failed`, and one window
    /// disagreeing with itself is what sent the owner clicking.
    func test_the_pane_says_what_the_header_says() {
        for presentation in [queued(), queued("Re-summarize"), active()] {
            XCTAssertEqual(
                RetryAffordance.decide(processing: presentation),
                .inFlight(label: presentation.label),
                "the pane must not invent a second wording for the state the header already names"
            )
        }
    }

    /// A stalled job is still in flight, so the pane must not start offering Retry again the moment
    /// a heartbeat lapses; the header keeps showing it and UX28's Cancel is the control for it.
    func test_a_stalled_job_is_still_in_flight() {
        let stalled = ProcessingPresentation.active(
            ActiveProcessing(stem: "20260813-170019", stage: "summarize", elapsedSec: 900, stalled: true)
        )
        XCTAssertFalse(RetryAffordance.decide(processing: stalled).isOffered)
    }
}
