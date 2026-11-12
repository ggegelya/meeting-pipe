import Foundation
import XCTest
@testable import MeetingPipe

/// PERF26: the Library's status indicators draw on a capped schedule, and a row that is waiting on
/// the owner does not move.
///
/// `TimelineView(.animation)` with no `minimumInterval` re-evaluates its closure and commits a frame
/// on every display refresh while the view is on screen, which is 120 a second on a ProMotion panel
/// for a 7 pt ring whose motion needs 20. Paste pending used to reuse that ring, and it is a terminal
/// status, so a BYO row spun until someone pasted a summary.
/// T7 source fence (deliberate): test_no_uncapped_animation_timeline_under_daemon_sources bans `TimelineView(.animation)` without `minimumInterval:` across every file under daemon/Sources. Missing seam: none; SwiftUI offers no runtime read of a TimelineView's schedule, and the claim is about the source text itself.
final class IndicatorCadenceTests: XCTestCase {

    // MARK: - The fence

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
            .deletingLastPathComponent()   // repo root
    }

    /// Every Swift file under `daemon/Sources` (both targets), by repo-relative path.
    private func daemonSources() throws -> [String: String] {
        let root = repoRoot().appendingPathComponent("daemon/Sources")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            XCTFail("cannot walk daemon/Sources")
            return [:]
        }
        var out: [String: String] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            let name = url.path.replacingOccurrences(of: repoRoot().path + "/", with: "")
            out[name] = try String(contentsOf: url, encoding: .utf8)
        }
        XCTAssertGreaterThan(out.count, 100, "the walk found almost nothing; re-point this fence")
        return out
    }

    /// The argument list of every `TimelineView(` call in `code`, from just after the opening
    /// parenthesis to its balanced close. Comments and string literals are already blanked.
    static func timelineArguments(in code: [Character]) -> [String] {
        let needle = Array("TimelineView(")
        var out: [String] = []
        var i = 0
        while i + needle.count <= code.count {
            guard Array(code[i ..< i + needle.count]) == needle else { i += 1; continue }
            var depth = 1
            var j = i + needle.count
            while j < code.count, depth > 0 {
                if code[j] == "(" { depth += 1 }
                if code[j] == ")" { depth -= 1 }
                j += 1
            }
            out.append(String(code[(i + needle.count) ..< max(i + needle.count, j - 1)]))
            i = j
        }
        return out
    }

    /// An `.animation` schedule that sets no `minimumInterval:` runs at the display's refresh rate.
    static func isUncapped(_ arguments: String) -> Bool {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix(".animation") && !trimmed.contains("minimumInterval:")
    }

    func test_the_fence_reads_the_shapes_it_has_to_tell_apart() {
        let uncapped = SwiftSourceScan.codeOnly("TimelineView(.animation) { ctx in Text(\"x\") }")
        let paused = SwiftSourceScan.codeOnly("TimelineView(.animation(paused: hidden)) { _ in }")
        let capped = SwiftSourceScan.codeOnly("TimelineView(.animation(minimumInterval: Self.frameInterval)) { _ in }")
        let periodic = SwiftSourceScan.codeOnly("TimelineView(.periodic(from: .now, by: 1)) { _ in }")
        let commented = SwiftSourceScan.codeOnly("/// Uses `TimelineView(.animation)` on purpose.\nlet x = 1")

        XCTAssertEqual(Self.timelineArguments(in: uncapped).map(Self.isUncapped), [true])
        XCTAssertEqual(Self.timelineArguments(in: paused).map(Self.isUncapped), [true])
        XCTAssertEqual(Self.timelineArguments(in: capped).map(Self.isUncapped), [false])
        XCTAssertEqual(Self.timelineArguments(in: periodic).map(Self.isUncapped), [false])
        XCTAssertEqual(Self.timelineArguments(in: commented), [], "a doc comment naming the API is not a call")
    }

    func test_no_uncapped_animation_timeline_under_daemon_sources() throws {
        var offenders: [String] = []
        var seen = 0
        for (path, text) in try daemonSources() where text.contains("TimelineView(") {
            for args in Self.timelineArguments(in: SwiftSourceScan.codeOnly(text)) {
                seen += 1
                if Self.isUncapped(args) { offenders.append("\(path): TimelineView(\(args))") }
            }
        }
        XCTAssertGreaterThanOrEqual(seen, 3, "the three PERF26 indicators were not found; re-point this fence")
        XCTAssertEqual(
            offenders, [],
            "TimelineView(.animation) with no minimumInterval: redraws at the display rate (up to 120 Hz) "
                + "for as long as the view is visible (PERF26). Pass .animation(minimumInterval:) with a named constant."
        )
    }

    // MARK: - The row's status pill

    private func pill(
        _ status: Meeting.Status,
        nda: Bool = false,
        publishState: String? = nil,
        emptyReason: EmptyReason? = nil,
        failureReason: String? = nil
    ) -> MeetingStatusPill {
        MeetingStatusPill.decide(
            status: status, isNDA: nda, publishState: publishState,
            emptyReason: emptyReason, failureReason: failureReason
        )
    }

    /// Owner's decision 2026-11-12, option (a): the kit's look, warning tint and a static alert glyph.
    func test_paste_pending_is_static_and_never_the_processing_spinner() {
        let p = pill(.manualPasteReady)
        XCTAssertEqual(p.kind, .pastePending)
        XCTAssertNotEqual(p.kind, .processing)
        XCTAssertEqual(p.label, "Paste pending")
        XCTAssertEqual(p.kind.indicator, .symbol("exclamationmark.circle"), "the kit's `alert` glyph")
        XCTAssertFalse(p.kind.isAnimated)
    }

    func test_only_live_states_animate() {
        XCTAssertTrue(MPStatusPill.Kind.processing.isAnimated)
        XCTAssertTrue(MPStatusPill.Kind.recording.isAnimated)
        for kind: MPStatusPill.Kind in [.ready, .failed, .nda, .neutral, .warning, .pastePending] {
            XCTAssertFalse(kind.isAnimated, "\(kind) is a resting state and must not move")
        }
    }

    func test_processing_and_recording_keep_their_kinds_and_labels() {
        XCTAssertEqual(pill(.processing), MeetingStatusPill(kind: .processing, label: "Processing", help: nil))
        XCTAssertEqual(pill(.recording), MeetingStatusPill(kind: .recording, label: "Recording", help: nil))
    }

    func test_nda_still_reads_kept_local_whatever_the_status() {
        for status: Meeting.Status in [.done, .processing, .recording, .manualPasteReady, .failed, .empty, .unknown] {
            let p = pill(status, nda: true)
            XCTAssertEqual(p.kind, .nda, "\(status)")
            XCTAssertEqual(p.label, "Kept local", "\(status)")
            XCTAssertEqual(p.help, "On this Mac by design (NDA workflow).")
        }
    }

    func test_the_other_statuses_map_as_they_did_before_the_lift() {
        XCTAssertEqual(pill(.failed, failureReason: "summarize timed out"),
                       MeetingStatusPill(kind: .failed, label: "Failed", help: "summarize timed out"))
        XCTAssertEqual(pill(.failed).help, "The pipeline did not finish for this meeting.")
        XCTAssertEqual(pill(.failed, failureReason: "").help, "The pipeline did not finish for this meeting.")

        let partial = DonePublishBadge.decide(publishState: "partial")
        XCTAssertEqual(pill(.done, publishState: "partial"),
                       MeetingStatusPill(kind: partial.kind, label: partial.label, help: partial.help))
        XCTAssertEqual(pill(.done), MeetingStatusPill(kind: .ready, label: "Ready", help: nil))

        XCTAssertEqual(pill(.empty, emptyReason: .noSpeech),
                       MeetingStatusPill(kind: .neutral, label: EmptyReason.noSpeech.pillLabel,
                                         help: EmptyReason.noSpeech.detail))
        XCTAssertEqual(pill(.empty), pill(.empty, emptyReason: .noSpeech), "a missing reason reads as no speech")
        XCTAssertEqual(pill(.unknown), MeetingStatusPill(kind: .neutral, label: "-", help: nil))
    }
}
