import XCTest
@testable import MeetingPipe

/// UX77: the aggregate surfaces called queued work "Processing".
///
/// The owner's screenshot had two red boxes on one screen: the Library toolbar pill read
/// `Processing 1` while that meeting's own row read `Queued: Re-transcribe`. One job, two nouns,
/// contradicting each other about whether anything had started. The number was never a count of
/// running work, it is `SinkDispatcher.processingJobs.count`, a queue depth that holds the active
/// job as its head only once one exists, so with nothing started `Processing 1` was describing
/// zero running jobs.
///
/// The row was already right (`ProcessingPresentation.label` splits running from waiting on
/// purpose), so these pin the aggregate surfaces having the same distinction and taking their word
/// from one place.
final class QueueActivityPresentationTests: XCTestCase {

    private typealias P = QueueActivityPresentation

    // MARK: - The reported defect

    /// The exact case from the screenshot. This is the assertion that fails against `main`, which
    /// returned "Processing 1" for a queue that had not started anything.
    func test_a_queue_that_has_not_started_does_not_claim_work_is_in_progress() {
        let waiting = QueueActivity(depth: 1, isRunning: false)
        XCTAssertEqual(P.pillLabel(waiting), "Queued 1")
        XCTAssertEqual(P.menuLabel(waiting), "Queued (1)")
        for label in [P.pillLabel(waiting), P.menuLabel(waiting)] {
            XCTAssertFalse(
                label!.contains("Processing"),
                "nothing has started, so no surface may say Processing"
            )
        }
    }

    /// And the word comes back the moment something is actually running, because "Processing" is
    /// correct then and is the vocabulary PRODUCT.md gives the menu bar.
    func test_a_running_head_is_called_processing_again() {
        let running = QueueActivity(depth: 1, isRunning: true)
        XCTAssertEqual(P.pillLabel(running), "Processing 1")
        XCTAssertEqual(P.menuLabel(running), "Processing (1)")
    }

    /// The number is the whole queue in both states, which is what it has always been. What changed
    /// is only the noun in front of it.
    func test_the_count_is_the_whole_queue_not_the_running_part() {
        XCTAssertEqual(P.pillLabel(QueueActivity(depth: 3, isRunning: true)), "Processing 3")
        XCTAssertEqual(P.pillLabel(QueueActivity(depth: 3, isRunning: false)), "Queued 3")
    }

    /// An empty queue says nothing at all, which is the pill's cue to render its idle shape and the
    /// menu bar's to leave the base state alone.
    func test_an_empty_queue_renders_nothing() {
        XCTAssertNil(P.pillLabel(.idle))
        XCTAssertNil(P.menuLabel(.idle))
        XCTAssertNil(P.pillLabel(QueueActivity(depth: 0, isRunning: true)), "depth wins over a stale flag")
    }

    // MARK: - One derivation, not three copies

    /// The defect was three surfaces each holding their own copy of the word. Every one of them now
    /// goes through `noun`, so a future edit cannot move two and leave the third behind.
    func test_every_aggregate_surface_takes_its_word_from_one_place() {
        for activity in [QueueActivity(depth: 2, isRunning: true), QueueActivity(depth: 2, isRunning: false)] {
            let word = P.noun(activity)
            XCTAssertTrue(P.pillLabel(activity)!.hasPrefix(word), "the toolbar pill drifted from noun()")
            XCTAssertTrue(P.menuLabel(activity)!.hasPrefix(word), "the menu-bar label drifted from noun()")
            XCTAssertTrue(
                StatusBarModel.title(.init(state: .idle, queue: activity)).contains(word),
                "the menu-bar title clause drifted from noun()"
            )
            XCTAssertTrue(
                StatusBarModel.headerLabel(.init(state: .idle, queue: activity)).contains(word),
                "the menu header drifted from noun()"
            )
        }
    }

    /// The vocabulary has to match the row's, since disagreeing with it on one screen is the whole
    /// bug. The row says `Queued:` for a pending job, so the aggregate says `Queued` too.
    func test_the_aggregate_word_matches_the_row_vocabulary() {
        let job = QueuedJob(id: UUID(), stem: "2026-08-04-standup", label: "Re-transcribe")
        let row = ProcessingPresentation.queued(job)
        XCTAssertEqual(row.label, "Queued: Re-transcribe")
        XCTAssertTrue(
            row.label.hasPrefix(P.noun(QueueActivity(depth: 1, isRunning: false))),
            "the row and the toolbar must use one word for a waiting job"
        )
    }

    // MARK: - DSN7: still one clause

    /// The menu-bar title carries exactly one clause and background work only takes the base
    /// state's place while idle. The new word must not have turned that into two things competing,
    /// which is why the richer `Processing 1 · 2 queued` split was not taken.
    func test_the_title_is_still_one_clause() {
        for activity in [QueueActivity(depth: 4, isRunning: true), QueueActivity(depth: 4, isRunning: false)] {
            let title = StatusBarModel.title(.init(state: .idle, queue: activity))
            XCTAssertFalse(title.contains("·"), "a second clause crept into the title: \(title)")
            XCTAssertEqual(title, " \(P.menuLabel(activity)!)")
        }
    }

    /// And it still yields to the base state rather than displacing it, which is the half of DSN7
    /// that is about priority rather than count.
    func test_background_work_still_never_displaces_recording() {
        let title = StatusBarModel.title(.init(
            state: .recording(
                file: URL(fileURLWithPath: "/tmp/20260819-000000.wav"),
                source: AppSource(bundleID: "us.zoom.xos", displayName: "Zoom"),
                summaryMode: .auto
            ),
            queue: QueueActivity(depth: 2, isRunning: false)
        ))
        XCTAssertEqual(title, " Recording")
    }

    // MARK: - The per-meeting row is untouched

    /// The row's split is the correct half and the model for this fix, so it is pinned here too:
    /// this task changed the aggregate surfaces and nothing else.
    func test_the_row_still_distinguishes_queued_from_active() {
        let queued = ProcessingPresentation.queued(
            QueuedJob(id: UUID(), stem: "s", label: "Re-summarize")
        )
        XCTAssertEqual(queued.label, "Queued: Re-summarize")

        let active = ProcessingPresentation.active(
            ActiveProcessing(stem: "s", stage: "transcribe", elapsedSec: 65, stalled: false)
        )
        XCTAssertEqual(active.label, "\(MeetingRow.stageLabel("transcribe")) 1:05")
        XCTAssertFalse(active.label.hasPrefix("Queued"), "a running job is not queued")
    }
}
