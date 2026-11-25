import XCTest
@testable import MeetingPipe

/// ARCH20: the one status ladder, as a table over `MeetingStatus.decide` with an injected `now`.
final class MeetingStatusTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var t0: Date { now.addingTimeInterval(-86_400) }
    private let threshold = Meeting.staleProcessingThresholdSec

    private func evidence(_ stage: PipelineFailureSidecar.Stage, structured: Bool, at: Date) -> MeetingStatus.ErrorSidecar {
        .evidence(.init(stage: stage, structured: structured, modified: at))
    }

    private func summarized(error: MeetingStatus.ErrorSidecar? = nil) -> MeetingStatus.Facts {
        MeetingStatus.Facts(audio: .finalRecording, hasSummary: true, summaryModified: t0, error: error, startedAt: t0)
    }

    private func assert(
        _ facts: MeetingStatus.Facts, _ status: Meeting.Status?, cacheable: Bool? = nil, keepsFailure: Bool? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let verdict = MeetingStatus.decide(facts, now: now)
        XCTAssertEqual(verdict?.status, status, file: file, line: line)
        if let cacheable { XCTAssertEqual(verdict?.cacheable, cacheable, "cacheable", file: file, line: line) }
        if let keepsFailure { XCTAssertEqual(verdict?.keepsFailure, keepsFailure, "keepsFailure", file: file, line: line) }
    }

    func test_summary_only_is_done_and_cacheable() {
        assert(summarized(), .done, cacheable: true, keepsFailure: false)
    }

    func test_publish_stage_failure_beside_a_summary_is_failed_and_cacheable() {
        assert(summarized(error: evidence(.publish, structured: false, at: t0.addingTimeInterval(-60))),
               .failed, cacheable: true, keepsFailure: true)
    }

    func test_an_older_metadata_less_transcribe_failure_beside_a_summary_is_done() {
        assert(summarized(error: evidence(.transcribe, structured: false, at: t0.addingTimeInterval(-60))),
               .done, cacheable: true, keepsFailure: false)
    }

    func test_a_structured_failure_newer_than_the_summary_is_failed_older_is_done() {
        assert(summarized(error: evidence(.pipeline, structured: true, at: t0.addingTimeInterval(60))), .failed, keepsFailure: true)
        assert(summarized(error: evidence(.pipeline, structured: true, at: t0.addingTimeInterval(-60))), .done, keepsFailure: false)
    }

    func test_paste_ready_and_empty_marker_are_terminal_and_cacheable() {
        let fresh = now.addingTimeInterval(-60)
        assert(.init(audio: .finalRecording, hasPasteReady: true, startedAt: fresh), .manualPasteReady, cacheable: true)
        assert(.init(audio: .finalRecording, hasEmptyMarker: true, startedAt: fresh), .empty, cacheable: true)
    }

    func test_audio_only_is_processing_before_the_threshold_and_failed_after() {
        assert(.init(audio: .finalRecording, startedAt: now.addingTimeInterval(-threshold + 1)),
               .processing, cacheable: false, keepsFailure: false)
        // PERF22: past the window a final recording's row is cacheable (the spec predates PERF22).
        assert(.init(audio: .finalRecording, startedAt: now.addingTimeInterval(-threshold - 1)),
               .failed, cacheable: true, keepsFailure: false)
        // A capture intermediate exists only while fresh, so its row is never cached (TECH-A17).
        assert(.init(audio: .captureIntermediate, startedAt: now.addingTimeInterval(-threshold + 1)),
               .processing, cacheable: false)
        assert(.init(audio: .captureIntermediate, startedAt: now.addingTimeInterval(-threshold - 1)),
               .failed, cacheable: false)
    }

    func test_an_owned_stem_is_processing_whatever_its_age() {
        assert(.init(audio: .captureIntermediate, startedAt: now.addingTimeInterval(-threshold * 3), owned: true),
               .processing, cacheable: false)
    }

    func test_no_audio_and_no_terminal_sidecar_is_no_row() {
        assert(.init(startedAt: t0), nil)
    }

    func test_no_audio_with_a_summary_is_done() {
        // A `drop` retention policy reclaimed the recording; transcript and summary remain.
        assert(.init(hasSummary: true, summaryModified: t0, startedAt: t0), .done, cacheable: true)
    }

    func test_an_unopened_error_is_current_only_without_a_summary() {
        assert(.init(audio: .finalRecording, error: .unopened, startedAt: t0), .failed, keepsFailure: true)
        assert(summarized(error: .unopened), .done, keepsFailure: false)
    }

    func test_an_undecodable_error_is_no_failure_but_keeps_a_row() {
        assert(.init(error: .undecodable, startedAt: now.addingTimeInterval(-60)), .processing, keepsFailure: false)
        assert(.init(error: .undecodable, startedAt: t0), .failed, keepsFailure: false)
    }

    func test_an_unparsed_stem_never_ages_into_failed() {
        assert(.init(audio: .finalRecording), .processing, cacheable: false)
    }

    /// The acceptance's badge agreement: for each table row with a final recording and no publish
    /// record, the menu count holds the stem exactly when `decide` answers `.failed`. The publish
    /// rows are UX90's (`test_buildMeeting_and_the_menu_count_agree_UX90`).
    func test_the_menu_count_agrees_with_decide_on_every_final_recording_row() {
        typealias Row = (stem: String, facts: MeetingStatus.Facts)
        let fresh = now.addingTimeInterval(-60), stale = now.addingTimeInterval(-threshold - 1)
        func stemString(_ d: Date) -> String { MeetingFormatters.stem.string(from: d) }
        // Distinct stems at the age each row needs; a summary row's age does not matter.
        let rows: [Row] = [
            (stemString(t0), summarized()),
            (stemString(t0.addingTimeInterval(1)), summarized(error: evidence(.publish, structured: false, at: t0))),
            (stemString(t0.addingTimeInterval(2)), summarized(error: evidence(.transcribe, structured: false, at: t0.addingTimeInterval(-60)))),
            (stemString(t0.addingTimeInterval(3)), summarized(error: evidence(.pipeline, structured: true, at: t0.addingTimeInterval(60)))),
            (stemString(t0.addingTimeInterval(4)), summarized(error: evidence(.pipeline, structured: true, at: t0.addingTimeInterval(-60)))),
            (stemString(fresh), .init(audio: .finalRecording, hasPasteReady: true, startedAt: fresh)),
            (stemString(fresh.addingTimeInterval(1)), .init(audio: .finalRecording, hasEmptyMarker: true, startedAt: fresh)),
            (stemString(fresh.addingTimeInterval(2)), .init(audio: .finalRecording, startedAt: fresh)),
            (stemString(stale), .init(audio: .finalRecording, startedAt: stale)),
            (stemString(stale.addingTimeInterval(-1)), .init(audio: .finalRecording, error: .unopened, startedAt: stale)),
        ]
        var names: [String] = []
        var errors: [String: MeetingStore.ErrorEvidence] = [:]
        var summaries: [String: Date] = [:]
        for (stem, f) in rows {
            names.append("\(stem).wav")
            if f.hasSummary { names.append("\(stem).summary.json"); summaries[stem] = f.summaryModified }
            if f.hasPasteReady { names.append("\(stem).READY_FOR_MANUAL.md") }
            if f.hasEmptyMarker { names.append("\(stem)\(EmptyMarker.suffix)") }
            switch f.error {
            case .evidence(let e)?: names.append("\(stem).error.json"); errors[stem] = e
            case .unopened?, .undecodable?: names.append("\(stem).error.json")
            case nil: break
            }
        }
        let readers = MeetingStore.FailureContentReaders(
            errorEvidence: { errors[$0] }, summaryModified: { summaries[$0] }, publishState: { _ in nil }
        )
        let menu = Set(MeetingStore.unrecoveredFailureStems(fileNames: names, now: now, readers: readers))
        for (stem, f) in rows {
            var started = f
            started.startedAt = MeetingStore.parseStem(stem)
            XCTAssertEqual(menu.contains(stem), MeetingStatus.decide(started, now: now)?.status == .failed, stem)
        }
        XCTAssertEqual(menu.count, 4, "publish-stage, newer structured, stale audio, error without summary")
    }
}
