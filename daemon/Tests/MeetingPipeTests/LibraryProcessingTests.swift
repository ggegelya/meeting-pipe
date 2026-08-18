import XCTest
@testable import MeetingPipe

/// UX28: what the Library says a meeting is doing, and which control it offers.
///
/// The decision is tested rather than the views because both the list row and
/// the detail header render it, and the bug being fixed was precisely that they
/// disagreed: the row had a private busy flag its own context menu set, the
/// detail pane had nothing, and Cancel existed only under a stalled heartbeat.
final class LibraryProcessingTests: XCTestCase {

    private func active(
        stem: String = "m",
        stage: String = "summarize",
        elapsed: Int = 72,
        stalled: Bool = false,
        label: String? = nil
    ) -> ActiveProcessing {
        ActiveProcessing(
            stem: stem, stage: stage, elapsedSec: elapsed, stalled: stalled, label: label
        )
    }

    private func queued(stem: String = "m", label: String = "Re-summarize") -> QueuedJob {
        QueuedJob(id: UUID(), stem: stem, label: label)
    }

    // MARK: - Which meeting the state belongs to

    func test_no_work_for_this_meeting_is_idle() {
        let p = LibraryProcessing.presentation(
            stem: "m", active: active(stem: "other"), pending: [queued(stem: "other")]
        )
        XCTAssertEqual(p, .idle)
        XCTAssertFalse(p.isBusy)
        XCTAssertFalse(p.canCancel)
    }

    func test_the_active_job_wins_for_its_own_stem() {
        let running = active()
        let p = LibraryProcessing.presentation(stem: "m", active: running, pending: [])
        XCTAssertEqual(p, .active(running))
    }

    func test_a_queued_job_is_reported_for_its_stem() {
        let job = queued()
        let p = LibraryProcessing.presentation(stem: "m", active: active(stem: "other"), pending: [job])
        XCTAssertEqual(p, .queued(job))
    }

    func test_the_head_of_two_waiting_jobs_is_the_one_shown() {
        // A Re-summarize can legitimately be queued behind a Reprocess for one
        // meeting; the one that will happen next is the one to name and to drop.
        let first = queued(label: "Reprocess")
        let second = queued(label: "Re-summarize")
        let p = LibraryProcessing.presentation(stem: "m", active: nil, pending: [first, second])
        XCTAssertEqual(p.queuedJob?.id, first.id)
    }

    // MARK: - Cancel is offered for a healthy job too (leg a)

    func test_cancel_is_offered_for_a_healthy_active_job() {
        // The whole defect: a mistaken Reprocess could not be stopped for its
        // ~110 s run because the button was gated on the stall heartbeat.
        let p = LibraryProcessing.presentation(stem: "m", active: active(stalled: false), pending: [])
        XCTAssertTrue(p.canCancel)
        XCTAssertFalse(p.isStalled)
    }

    func test_cancel_is_still_offered_for_a_stalled_job() {
        let p = LibraryProcessing.presentation(stem: "m", active: active(stalled: true), pending: [])
        XCTAssertTrue(p.canCancel)
        XCTAssertTrue(p.isStalled, "the Stalled pill semantics are unchanged")
    }

    func test_a_queued_job_is_dropped_rather_than_cancelled() {
        // Nothing has been spawned, so there is no subprocess to signal.
        let p = LibraryProcessing.presentation(stem: "m", active: nil, pending: [queued()])
        XCTAssertFalse(p.canCancel)
        XCTAssertNotNil(p.queuedJob)
        XCTAssertTrue(p.isBusy, "waiting still blocks Export and Move to Trash")
    }

    // MARK: - The line the user reads

    func test_a_run_all_reads_its_progress_heartbeat() {
        let p = LibraryProcessing.presentation(
            stem: "m", active: active(stage: "summarize", elapsed: 72), pending: []
        )
        XCTAssertEqual(p.label, "Summarizing 1:12")
    }

    func test_a_library_re_run_carries_its_own_label_naming_the_engine() {
        // `mp summarize` emits no heartbeat, so there is no stage or elapsed to
        // render; the engine is in the label because "Summarizing" alone cannot
        // tell a local re-run from a cloud one.
        let p = LibraryProcessing.presentation(
            stem: "m",
            active: active(stage: "regenerate", elapsed: 0, label: "Summarizing with Anthropic"),
            pending: []
        )
        XCTAssertEqual(p.label, "Summarizing with Anthropic")
    }

    // MARK: - The phases before the first heartbeat (UX69)

    func test_the_transcription_pass_reads_as_transcribing_with_no_clock() {
        // Published at the start of the daemon's own pass, which has no heartbeat
        // to ride and so put nothing on the row at all until the pipeline was up
        // 58.6 s later. There is no elapsed time to render, and a clock frozen at
        // 0:00 for a minute reads as a stuck row rather than as a phase.
        let p = LibraryProcessing.presentation(
            stem: "m",
            active: active(stage: SinkDispatcher.transcribeStage, elapsed: 0),
            pending: []
        )
        XCTAssertEqual(p.label, "Transcribing")
        XCTAssertTrue(p.canCancel, "the pass is interruptible, which is why the row offers this")
    }

    func test_a_spawned_pipeline_reads_as_processing_until_it_beats() {
        let p = LibraryProcessing.presentation(
            stem: "m",
            active: active(stage: SinkDispatcher.spawnedStage, elapsed: 0),
            pending: []
        )
        // Deliberately not one of the pipeline's own stage names: it is up and has
        // not said what it is doing yet, and the daemon must not answer for it.
        XCTAssertEqual(p.label, "Processing")
        XCTAssertTrue(p.canCancel)
    }

    func test_a_queued_job_says_what_it_is_waiting_to_do() {
        let p = LibraryProcessing.presentation(stem: "m", active: nil, pending: [queued(label: "Reprocess")])
        XCTAssertEqual(p.label, "Queued: Reprocess")
    }

    // MARK: - The labels themselves

    func test_a_regenerate_label_names_each_engine() {
        XCTAssertEqual(
            LibraryRun(verb: .regenerate, stem: "m", backend: "anthropic").progressLabel,
            "Summarizing with Anthropic"
        )
        XCTAssertEqual(
            LibraryRun(verb: .regenerate, stem: "m", backend: "local").progressLabel,
            "Summarizing on-device"
        )
        XCTAssertEqual(
            LibraryRun(verb: .regenerate, stem: "m", backend: "apple_intelligence").progressLabel,
            "Summarizing on-device"
        )
        // No override: the workflow's own backend decides, and the daemon does
        // not resolve it, so the label must not claim one.
        XCTAssertEqual(
            LibraryRun(verb: .regenerate, stem: "m").progressLabel,
            "Summarizing"
        )
    }

    func test_a_republish_label_says_publishing() {
        XCTAssertEqual(LibraryRun(verb: .republish, stem: "m").progressLabel, "Publishing")
    }

    func test_every_job_kind_has_a_queued_label() {
        XCTAssertEqual(ProcessingJobKind.full.queuedLabel, "Reprocess")
        XCTAssertEqual(ProcessingJobKind.retranscribe.queuedLabel, "Re-transcribe")
        XCTAssertEqual(
            ProcessingJobKind.libraryRun(LibraryRun(verb: .regenerate, stem: "m")).queuedLabel,
            "Re-summarize"
        )
        XCTAssertEqual(
            ProcessingJobKind.libraryRun(LibraryRun(verb: .republish, stem: "m")).queuedLabel,
            "Publish"
        )
    }
}
