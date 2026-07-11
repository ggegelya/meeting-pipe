import XCTest
@testable import MeetingPipe

final class MeetingMergeEligibilityTests: XCTestCase {

    private func meeting(
        _ stem: String,
        at date: Date,
        workflowID: String? = "wf-1",
        status: Meeting.Status = .done,
        hasAudio: Bool = true,
        nda: Bool = false,
        regulated: Bool = false
    ) -> Meeting {
        var m = Meeting(
            stem: stem,
            startedAt: date,
            audioURL: hasAudio ? URL(fileURLWithPath: "/tmp/\(stem).wav") : nil,
            recordingsDir: URL(fileURLWithPath: "/tmp"),
            summaryTitle: nil, meetingTitle: nil,
            sourceBundleID: nil, sourceDisplayName: nil, sourceKind: nil,
            workflowName: nil, workflowColor: nil,
            durationSec: nil, backend: nil, modelId: nil,
            status: status,
            failureReason: nil, failureStage: nil,
            searchableText: ""
        )
        m.workflowID = workflowID
        m.workflowNDAMode = nda
        m.regulatedMode = regulated
        return m
    }

    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    func test_two_compatible_fragments_are_eligible_primary_is_earliest() {
        let later = meeting("b", at: t0.addingTimeInterval(1800))
        let earlier = meeting("a", at: t0)
        guard case .success(let plan) = MeetingMergeEligibility.decide([later, earlier]) else {
            return XCTFail("expected eligible")
        }
        XCTAssertEqual(plan.primary.stem, "a")
        XCTAssertEqual(plan.fragments.map(\.stem), ["b"])
    }

    func test_fragments_are_ordered_chronologically() {
        let m = [
            meeting("c", at: t0.addingTimeInterval(3600)),
            meeting("a", at: t0),
            meeting("b", at: t0.addingTimeInterval(1800)),
        ]
        guard case .success(let plan) = MeetingMergeEligibility.decide(m) else {
            return XCTFail("expected eligible")
        }
        XCTAssertEqual(plan.primary.stem, "a")
        XCTAssertEqual(plan.fragments.map(\.stem), ["b", "c"])
    }

    func test_single_selection_is_too_few() {
        XCTAssertEqual(MeetingMergeEligibility.decide([meeting("a", at: t0)]),
                       .failure(.tooFew))
    }

    func test_unfinished_meeting_blocks_merge() {
        let m = [meeting("a", at: t0), meeting("b", at: t0.addingTimeInterval(60), status: .processing)]
        XCTAssertEqual(MeetingMergeEligibility.decide(m), .failure(.notAllDone))
    }

    func test_missing_audio_blocks_merge() {
        let m = [meeting("a", at: t0), meeting("b", at: t0.addingTimeInterval(60), hasAudio: false)]
        XCTAssertEqual(MeetingMergeEligibility.decide(m), .failure(.missingAudio))
    }

    func test_different_workflows_block_merge() {
        let m = [meeting("a", at: t0, workflowID: "wf-1"),
                 meeting("b", at: t0.addingTimeInterval(60), workflowID: "wf-2")]
        XCTAssertEqual(MeetingMergeEligibility.decide(m), .failure(.mixedWorkflows))
    }

    func test_mixed_privacy_posture_blocks_merge() {
        // Same workflow, but one recorded zero-egress and one not: never blur the boundary.
        let m = [meeting("a", at: t0, nda: false),
                 meeting("b", at: t0.addingTimeInterval(60), nda: true)]
        XCTAssertEqual(MeetingMergeEligibility.decide(m), .failure(.mixedPrivacy))
    }

    func test_two_manual_recordings_share_the_no_workflow_group() {
        let m = [meeting("a", at: t0, workflowID: nil),
                 meeting("b", at: t0.addingTimeInterval(60), workflowID: nil)]
        guard case .success = MeetingMergeEligibility.decide(m) else {
            return XCTFail("two workflow-less recordings should be mergeable")
        }
    }
}
