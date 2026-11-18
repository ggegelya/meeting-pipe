import XCTest
@testable import MeetingPipe

/// UX98: the detail pane's per-meeting state outlived the selection. A finished preview landed
/// beside the next meeting's summary, paste text carried over, and the tabs' stale-stem guards
/// compared a captured `meeting.stem` with itself, so a late load wrote the meeting just left
/// into the pane of the one now selected.
@MainActor
final class DetailStateUX98Tests: XCTestCase {

    // MARK: - The live token

    func test_a_load_for_the_meeting_just_left_is_refused() {
        let live = DetailLiveness()
        live.show("A")
        XCTAssertTrue(live.accepts("A", cancelled: false))
        live.show("B")
        XCTAssertFalse(live.accepts("A", cancelled: false),
                       "a transcript, waveform or corrections read for A must not land in B's pane")
        XCTAssertTrue(live.accepts("B", cancelled: false))
    }

    func test_a_cancelled_load_is_refused_even_for_the_same_meeting() {
        let live = DetailLiveness()
        live.show("A")
        XCTAssertFalse(live.accepts("A", cancelled: true),
                       "`Task.detached(...).value` does not throw on cancellation, so the guard has to ask")
    }

    func test_a_view_off_screen_accepts_nothing() {
        let live = DetailLiveness()
        live.show("A")
        live.hide()
        XCTAssertFalse(live.accepts("A", cancelled: false))
    }

    // MARK: - The preview

    /// Preview started for A, selection moved to B before it finished: nothing shows on B's pane,
    /// and A's candidate sidecar is discarded rather than left on disk.
    func test_a_preview_that_outlives_its_meeting_discards_its_candidate() {
        let live = DetailLiveness()
        live.show("A")
        live.show("B")
        XCTAssertEqual(SummaryPreviewLanding.decide(ranFor: "A", succeeded: true, liveness: live),
                       .discardOrphan(stem: "A"))
        XCTAssertEqual(SummaryPreviewLanding.decide(ranFor: "A", succeeded: false, liveness: live), .drop)
    }

    func test_a_preview_for_the_meeting_on_screen_lands() {
        let live = DetailLiveness()
        live.show("A")
        XCTAssertEqual(SummaryPreviewLanding.decide(ranFor: "A", succeeded: true, liveness: live), .land)
        XCTAssertEqual(SummaryPreviewLanding.decide(ranFor: "A", succeeded: false, liveness: live), .land)
    }

    // MARK: - The Audio tab's load

    func test_a_cancelled_audio_task_does_not_load_the_meeting_just_left() async {
        var loaded: [URL] = []
        await AudioTabLoad.run(
            audioURL: URL(fileURLWithPath: "/tmp/A.wav"),
            reloadWaveform: {},
            isCancelled: { true },
            load: { loaded.append($0) }
        )
        XCTAssertEqual(loaded, [])
    }

    func test_a_live_audio_task_loads_its_meeting() async {
        var loaded: [URL] = []
        await AudioTabLoad.run(
            audioURL: URL(fileURLWithPath: "/tmp/A.wav"),
            reloadWaveform: {},
            isCancelled: { false },
            load: { loaded.append($0) }
        )
        XCTAssertEqual(loaded, [URL(fileURLWithPath: "/tmp/A.wav")])
    }

    // MARK: - Wiring fences

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private let detailFiles = [
        "Sources/MeetingPipe/SummaryTab.swift",
        "Sources/MeetingPipe/TranscriptTab.swift",
        "Sources/MeetingPipe/AudioTab.swift",
        "Sources/MeetingPipe/CorrectionsTab.swift",
        "Sources/MeetingPipe/MeetingDetailView.swift",
    ]

    /// The tautology itself: `meeting` is a `let` on a value type, so a local captured from
    /// `meeting.stem` compared with `meeting.stem` after an await is always equal.
    func test_no_detail_guard_compares_meeting_stem_with_its_own_capture() throws {
        for file in detailFiles {
            let text = try source(file)
            // A bare `stem` local on either side; `jump.stem == meeting.stem` compares two values.
            for pattern in [#"meeting\.stem == stem\b"#, #"(?<![\w.])stem == meeting\.stem"#] {
                XCTAssertNil(text.range(of: pattern, options: .regularExpression),
                             "\(file) guards with `\(pattern)`, which is always true (UX98)")
            }
        }
    }

    func test_every_detail_view_tracks_its_live_stem() throws {
        for file in detailFiles {
            XCTAssertTrue(try source(file).contains(".tracksLiveStem(liveness, stem: meeting.stem)"),
                          "\(file) reads `liveness` after its awaits, so it has to keep it current")
        }
    }

    /// Part 1: the tab content is one identity per meeting, so paste text, an in-flight preview's
    /// flag and every other tab `@State` start fresh on a selection change. The player stays
    /// outside it (UX78).
    func test_the_tab_content_is_rebuilt_per_meeting_and_the_player_is_not() throws {
        let text = try source("Sources/MeetingPipe/MeetingDetailView.swift")
        XCTAssertTrue(text.contains("tabContent\n                .id(meeting.stem)"),
                      "without the identity, SummaryTab's paste text and preview carry over (UX98)")
        XCTAssertTrue(text.contains("@StateObject var playback = AudioPlaybackController()"),
                      "the player must stay on MeetingDetailView, outside the per-meeting identity (UX78)")
    }

    /// TECH-A16 still runs on navigation, from the hook that outlives the tab's identity.
    func test_navigation_still_discards_an_unkept_candidate() throws {
        let text = try source("Sources/MeetingPipe/MeetingDetailView.swift")
        guard let hook = text.range(of: ".onChange(of: meeting.stem) { _, _ in"),
              let end = text.range(of: ".onDisappear", range: hook.upperBound..<text.endIndex) else {
            return XCTFail("MeetingDetailView's stem-change hook no longer has this shape; re-point this fence")
        }
        XCTAssertTrue(text[hook.upperBound..<end.lowerBound].contains("libraryModel.discardCandidateSummary(stem: s)"))
    }

    /// Revert writes the loaded record's `original_summary` over this meeting's summary, so it
    /// must only ever use a record loaded for this meeting.
    func test_revert_uses_only_this_meetings_record() throws {
        let text = try source("Sources/MeetingPipe/CorrectionsTab.swift")
        XCTAssertTrue(text.contains("guard loadedForStem == meeting.stem, let rec = record,"))
    }
}
