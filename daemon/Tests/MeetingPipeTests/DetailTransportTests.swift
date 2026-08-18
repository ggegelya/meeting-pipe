import Foundation
import XCTest
@testable import MeetingPipe

/// UX78: audio kept playing after leaving the Transcript or Audio tab, with nothing on Summary to
/// stop it.
///
/// The player is a `@StateObject` on `MeetingDetailView` and outlives a tab switch on purpose, but
/// every transport control lived inside the two audio-bearing tabs, so selecting Summary removed
/// the whole surface while the audio continued. The owner's report names both halves: "it would be
/// nice to have the possibility to stop playback, but I have no controls, and playback still
/// running."
///
/// The codebase already knew playback must yield when attention moves (`TranscriptTab` pauses for
/// an open sheet and for a right-click) and handled two narrow cases inside one tab while the tab
/// switch itself went unhandled.
final class DetailTransportTests: XCTestCase {

    private let audio = URL(fileURLWithPath: "/tmp/meetings/20260804-101500.wav")
    private let otherAudio = URL(fileURLWithPath: "/tmp/meetings/20260804-140000.wav")

    private func decide(
        loaded: URL? = nil,
        meeting: URL? = nil,
        isPlaying: Bool = false,
        currentTime: TimeInterval = 0,
        duration: TimeInterval = 2538
    ) -> DetailTransport? {
        DetailTransport.decide(
            loadedURL: loaded, meetingAudioURL: meeting,
            isPlaying: isPlaying, currentTime: currentTime, duration: duration
        )
    }

    // MARK: - The reported defect

    /// The whole task. The header is tab-independent, so a transport here is reachable from Summary
    /// exactly as it is from Transcript. Against `main` there was no transport at any width: every
    /// control lived inside `AudioTab` and `TranscriptTab`.
    func test_playing_always_leaves_a_reachable_transport() {
        let transport = decide(loaded: audio, meeting: audio, isPlaying: true, currentTime: 65)
        XCTAssertNotNil(transport, "playing with no way to stop it must be unreachable")
        XCTAssertEqual(transport?.actionLabel, "Pause")
        XCTAssertEqual(transport?.systemImage, "pause.fill")
        XCTAssertEqual(transport?.position, "1:05 / 42:18")
    }

    /// Pausing from the header must not remove the header's control, or the press that stopped the
    /// audio is also the press that hides the way to resume it. This is why the rule is not a bare
    /// `isPlaying`.
    func test_pausing_from_the_header_does_not_hide_the_transport() {
        let paused = decide(loaded: audio, meeting: audio, isPlaying: false, currentTime: 65)
        XCTAssertNotNil(paused, "a parked play head still needs its control")
        XCTAssertEqual(paused?.actionLabel, "Play")
        XCTAssertEqual(paused?.systemImage, "play.fill")
    }

    // MARK: - The header does not grow permanently

    /// Nothing started, nothing shown. The band already carries the title, captions, provenance and
    /// the processing row; a transport for a player nobody has touched would be permanent chrome.
    func test_absent_when_nothing_has_played() {
        XCTAssertNil(decide(loaded: audio, meeting: audio, isPlaying: false, currentTime: 0))
    }

    func test_absent_when_no_audio_is_loaded() {
        XCTAssertNil(decide(loaded: nil, meeting: audio, isPlaying: true, currentTime: 65))
    }

    /// A meeting with no audio on disk can never show one.
    func test_absent_when_the_meeting_has_no_audio() {
        XCTAssertNil(decide(loaded: audio, meeting: nil, isPlaying: true, currentTime: 65))
    }

    // MARK: - Switching meetings

    /// The same defect one level up, and the reason the rule checks the URL rather than trusting
    /// the player. `MeetingDetailView` has no `.id(meeting.stem)`, so SwiftUI reuses it and the
    /// player keeps the previous meeting's file; only `TranscriptTab` and `AudioTab` call `load`,
    /// so switching meetings from Summary replaces nothing. A transport shown then would drive the
    /// wrong audio under the right title.
    func test_a_stale_file_from_the_previous_meeting_shows_no_transport() {
        XCTAssertNil(
            decide(loaded: otherAudio, meeting: audio, isPlaying: true, currentTime: 65),
            "the header must not offer a transport over the meeting the user just left"
        )
    }

    /// And once the new meeting's audio is actually loaded, the transport belongs to it.
    func test_the_transport_returns_for_the_newly_loaded_meeting() {
        XCTAssertNotNil(decide(loaded: audio, meeting: audio, isPlaying: true, currentTime: 3))
    }

    // MARK: - Position

    /// One clock for the whole Library: the same helper the rows and the processing label use.
    func test_position_reads_as_elapsed_over_total() {
        XCTAssertNil(
            decide(loaded: audio, meeting: audio, isPlaying: false, currentTime: 0, duration: 61),
            "zero with nothing playing is still at rest"
        )
        // Playing from the very start is not at rest, so it does get its control.
        XCTAssertNotNil(decide(loaded: audio, meeting: audio, isPlaying: true, currentTime: 0, duration: 61))

        let playing = decide(loaded: audio, meeting: audio, isPlaying: true, currentTime: 5, duration: 61)
        XCTAssertEqual(playing?.position, "\(MeetingRow.formatDuration(5)) / \(MeetingRow.formatDuration(61))")
    }
}

/// UX78's wiring, as source fences. The two facts below are SwiftUI plumbing with no runtime read:
/// a modifier's presence and a closure's statement order are not observable from a constructed
/// view, and `SummaryLayoutTests`, `PreferencesSurfaceTests` and `TutorialFenceTests` all take this
/// route for the same reason.
final class DetailTransportWiringTests: XCTestCase {

    private func repoFile(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
            .deletingLastPathComponent()   // repo root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Acceptance: switching to a different meeting must not leave the previous one's audio
    /// playing. The player survives the switch by design, so something has to stop it, and the only
    /// place that sees the change is the detail view's `onChange(of: meeting.stem)`.
    func test_changing_meeting_pauses_the_player() throws {
        let source = try repoFile("daemon/Sources/MeetingPipe/MeetingDetailView.swift")
        let marker = "onChange(of: meeting.stem)"
        let start = try XCTUnwrap(source.range(of: marker), "the stem-change hook is gone")
        let body = String(source[start.upperBound...].prefix(600))
        XCTAssertTrue(
            body.contains("playback.pause()"),
            "a meeting switch must stop the previous meeting's audio"
        )
    }

    /// Acceptance: the summary-citation jump still works with playback active. The order is
    /// load-bearing, since the Transcript tab reads the pending seek in its `onAppear`, so raising
    /// it after the tab switch would miss the read. This fence exists because UX78 touched the same
    /// `onChange` block that hook lives beside.
    func test_the_citation_jump_still_raises_the_seek_before_switching_tabs() throws {
        let source = try repoFile("daemon/Sources/MeetingPipe/MeetingDetailView.swift")
        let jump = try XCTUnwrap(
            source.range(of: "private func consumeTranscriptJump()"),
            "the citation jump is gone"
        )
        let body = String(source[jump.upperBound...].prefix(400))
        let seek = try XCTUnwrap(body.range(of: "pendingTranscriptSeek = jump.seek"))
        let switchTab = try XCTUnwrap(body.range(of: "selectedTab = Tab.transcript.rawValue"))
        XCTAssertLessThan(
            seek.lowerBound, switchTab.lowerBound,
            "the seek must be raised before the tab switch, or the Transcript tab's onAppear misses it"
        )
        XCTAssertFalse(
            body.contains("playback.pause()"),
            "the citation jump must not stop playback; carrying the play head across tabs is why the controller is shared"
        )
    }

    /// The transport is play/pause and position only. The waveform, rate, channel and skip-silence
    /// controls are explicitly out of scope and stay in `AudioTab`.
    func test_the_header_transport_stays_minimal() throws {
        let header = try repoFile("daemon/Sources/MeetingPipe/MeetingDetailView+Header.swift")
        let start = try XCTUnwrap(header.range(of: "var transportRow: some View"))
        let body = String(header[start.upperBound...].prefix(1200))
        for control in ["playbackRate", "channelMode", "skipSilence", "Waveform"] {
            XCTAssertFalse(body.contains(control), "\(control) belongs to AudioTab, not the header")
        }
    }
}
