import XCTest
@testable import MeetingPipe

/// STOR1's policy engine. Every test here exists because the alternative to
/// getting it right is silently deleting a recording that cannot be recreated.
final class AudioRetentionTests: XCTestCase {

    private let workflowA = UUID()
    private let workflowB = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(
        stem: String = "20260101-120000",
        ext: String = "wav",
        daysAgo: Double,
        workflow: UUID?,
        status: Meeting.Status = .done,
        publishState: String? = "full"
    ) -> AudioRetention.Candidate {
        AudioRetention.Candidate(
            stem: stem,
            audioURL: URL(fileURLWithPath: "/tmp/raw/\(stem).\(ext)"),
            startedAt: now.addingTimeInterval(-daysAgo * 24 * 60 * 60),
            workflowID: workflow,
            status: status,
            publishState: publishState
        )
    }

    private func decide(
        _ candidates: [AudioRetention.Candidate],
        _ policies: [UUID: WorkflowRetention],
        liveStem: String? = nil
    ) -> [AudioRetention.Action] {
        AudioRetention.decide(candidates: candidates, policies: policies, now: now, liveStem: liveStem)
    }

    // MARK: Defaults

    func test_keep_is_the_default_and_reaps_nothing() {
        let actions = decide(
            [candidate(daysAgo: 3650, workflow: workflowA)],
            [workflowA: WorkflowRetention()]
        )
        XCTAssertEqual(actions, [], "a workflow that never opted in keeps its audio forever")
    }

    func test_workflow_absent_from_the_policy_map_keeps_its_audio() {
        // A workflow the owner deleted, or one this build has not loaded. An
        // unknown workflow must never be read as "drop it".
        let actions = decide([candidate(daysAgo: 400, workflow: workflowB)], [workflowA: .init(policy: .drop)])
        XCTAssertEqual(actions, [])
    }

    func test_meeting_with_no_workflow_keeps_its_audio() {
        let actions = decide([candidate(daysAgo: 400, workflow: nil)], [workflowA: .init(policy: .drop)])
        XCTAssertEqual(actions, [])
    }

    // MARK: The window

    func test_compress_fires_only_past_the_window() {
        let policies = [workflowA: WorkflowRetention(policy: .compress, afterDays: 30)]
        XCTAssertEqual(decide([candidate(daysAgo: 29, workflow: workflowA)], policies), [])

        let actions = decide([candidate(daysAgo: 31, workflow: workflowA)], policies)
        XCTAssertEqual(actions, [.compress(URL(fileURLWithPath: "/tmp/raw/20260101-120000.wav"))])
    }

    func test_drop_fires_past_the_window() {
        let policies = [workflowA: WorkflowRetention(policy: .drop, afterDays: 7)]
        let actions = decide([candidate(daysAgo: 8, workflow: workflowA)], policies)
        XCTAssertEqual(actions, [.drop(URL(fileURLWithPath: "/tmp/raw/20260101-120000.wav"))])
    }

    func test_compress_skips_a_recording_already_in_flac() {
        // The policy has run before. Re-encoding would churn the mtime, invalidate
        // the waveform cache, and reclaim nothing.
        let policies = [workflowA: WorkflowRetention(policy: .compress, afterDays: 30)]
        XCTAssertEqual(decide([candidate(ext: "flac", daysAgo: 400, workflow: workflowA)], policies), [])
    }

    func test_drop_still_fires_on_a_compressed_recording() {
        let policies = [workflowA: WorkflowRetention(policy: .drop, afterDays: 30)]
        let actions = decide([candidate(ext: "flac", daysAgo: 400, workflow: workflowA)], policies)
        XCTAssertEqual(actions, [.drop(URL(fileURLWithPath: "/tmp/raw/20260101-120000.flac"))])
    }

    // MARK: Exemptions

    func test_non_terminal_meetings_are_exempt() {
        let policies = [workflowA: WorkflowRetention(policy: .drop, afterDays: 1)]
        for status: Meeting.Status in [.recording, .processing, .unknown] {
            let actions = decide([candidate(daysAgo: 400, workflow: workflowA, status: status)], policies)
            XCTAssertEqual(actions, [], "\(status) is not settled")
        }
    }

    func test_needs_you_members_are_exempt() {
        let policies = [workflowA: WorkflowRetention(policy: .drop, afterDays: 1)]
        // Every row the Library's `Needs you` scope claims: a failed run, a paste
        // bundle, a no-speech result, and a publish that failed or half-landed.
        let exempt: [(Meeting.Status, String?)] = [
            (.failed, nil),
            (.manualPasteReady, nil),
            (.empty, nil),
            (.done, "none"),
            (.done, "partial"),
        ]
        for (status, publishState) in exempt {
            let actions = decide(
                [candidate(daysAgo: 400, workflow: workflowA, status: status, publishState: publishState)],
                policies
            )
            XCTAssertEqual(actions, [], "\(status)/\(publishState ?? "nil") is Needs you")
        }
    }

    func test_never_published_zero_egress_meeting_is_settled() {
        // An NDA or local-only meeting never publishes, so `publishState` is nil.
        // `LibraryScope.needsYou` deliberately leaves those out, and so must this.
        let policies = [workflowA: WorkflowRetention(policy: .drop, afterDays: 30)]
        let actions = decide(
            [candidate(daysAgo: 400, workflow: workflowA, publishState: nil)],
            policies
        )
        XCTAssertEqual(actions.count, 1)
    }

    func test_the_live_recording_is_never_touched() {
        let policies = [workflowA: WorkflowRetention(policy: .drop, afterDays: 1)]
        let actions = decide(
            [candidate(stem: "20260101-120000", daysAgo: 400, workflow: workflowA)],
            policies,
            liveStem: "20260101-120000"
        )
        XCTAssertEqual(actions, [])
    }

    // MARK: isSettled agrees with LibraryScope.needsYou

    func test_isSettled_is_the_exact_complement_of_needsYou_for_terminal_rows() {
        let cases: [(Meeting.Status, String?)] = [
            (.done, "full"), (.done, nil), (.done, "none"), (.done, "partial"),
            (.failed, nil), (.manualPasteReady, nil), (.empty, nil),
            (.processing, nil), (.recording, nil),
        ]
        for (status, publishState) in cases {
            var meeting = Meeting(
                stem: "20260101-120000",
                startedAt: Date(),
                audioURL: nil,
                recordingsDir: URL(fileURLWithPath: "/tmp/raw"),
                summaryTitle: nil, meetingTitle: nil,
                sourceBundleID: nil, sourceDisplayName: nil, sourceKind: nil,
                workflowName: nil, workflowColor: nil,
                durationSec: nil, backend: nil, modelId: nil,
                status: status, failureReason: nil, failureStage: nil,
                searchableText: ""
            )
            meeting.publishState = publishState
            let needsYou = LibraryScope.needsYou.includes(meeting, workflows: [], now: Date())
            let settled = AudioRetention.isSettled(status: status, publishState: publishState)
            if status == .done {
                XCTAssertEqual(settled, !needsYou, "\(status)/\(publishState ?? "nil")")
            } else {
                XCTAssertFalse(settled, "\(status) is never settled")
            }
        }
    }
}
