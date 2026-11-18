import AppKit
import SwiftUI
import XCTest
@testable import MeetingPipe

/// HYG22: two UI lifetime shapes the rest of the app already removed, pinned so they stay gone.
final class UILifetimeFenceTests: XCTestCase {

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    private func spin(timeout: TimeInterval = 5, until ready: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !ready(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - F077: the onboarding window

    @MainActor
    func test_the_onboarding_window_is_not_released_on_close() {
        _ = NSApplication.shared
        let window = OnboardingWindowController.makeWindow(content: Text("x"))
        XCTAssertFalse(window.isReleasedWhenClosed)
        window.close()
    }

    /// `FailureLayoutTests.test_details_window_is_released_once_closed_and_dropped`'s pattern: a
    /// factory-built window that is closed and dropped goes away exactly once. With the flag at its
    /// default, AppKit's release on close lands on top of ARC's.
    @MainActor
    func test_a_closed_and_dropped_onboarding_window_is_released_once() {
        _ = NSApplication.shared
        weak var weakWindow: NSWindow?
        autoreleasepool {
            let window = OnboardingWindowController.makeWindow(content: Text("x"))
            weakWindow = window
            window.close()
        }
        spin { weakWindow == nil }
        XCTAssertNil(weakWindow, "the onboarding window outlived its last strong reference")
    }

    /// Every file that builds an `NSWindow(` sets `isReleasedWhenClosed = false`. `FailureNotice`
    /// is the one exception: its Details window orders out instead of closing (PERF27).
    func test_every_closing_window_turns_off_release_on_close() throws {
        let allowlisted: Set<String> = ["FailureNotice.swift"]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("NSWindow("), !allowlisted.contains(url.lastPathComponent) else { continue }
            if !text.contains("isReleasedWhenClosed = false") { offenders.append(url.lastPathComponent) }
        }
        XCTAssertEqual(offenders, [], "builds an NSWindow without isReleasedWhenClosed = false")
    }

    // MARK: - G017: the summary editor's rows

    func test_the_summary_editor_binds_rows_by_id_not_position() throws {
        let editor = try String(
            contentsOf: Self.sources.appendingPathComponent("MeetingPipe/CorrectionEditor.swift"), encoding: .utf8
        )
        XCTAssertFalse(editor.contains(".indices, id: \\.self"), "a positional row loop is back in the editor")
        XCTAssertFalse(editor.contains("text: items[i]"), "a positional row binding is back in the editor")
        XCTAssertTrue(editor.contains("Self.lineBinding(items, line.id)"))
    }

    /// The scenario the owner walks: three rows, a binding held for the third, the second removed
    /// by id; writing through the binding lands in what was the third row.
    func test_an_id_keyed_binding_survives_a_middle_row_being_removed() {
        let model = CorrectionViewModel(
            stem: "s", recordingsDir: URL(fileURLWithPath: NSTemporaryDirectory()), runMeta: [:],
            originalSummary: MeetingSummary(summary: ["first", "second", "third"])
        )
        let rows = Binding(get: { model.summaryLines }, set: { model.summaryLines = $0 })
        let thirdID = model.summaryLines[2].id
        let third = CorrectionEditorBody.lineBinding(rows, thirdID)
        let secondID = model.summaryLines[1].id
        model.summaryLines.removeAll { $0.id == secondID }
        third.wrappedValue = "third, edited"
        XCTAssertEqual(model.summary, ["first", "third, edited"])
        XCTAssertEqual(model.makeCorrectedSummary().summary, ["first", "third, edited"])
        model.summaryLines.removeAll { $0.id == thirdID }
        third.wrappedValue = "ignored"
        XCTAssertEqual(model.summary, ["first"], "a write through a removed row's binding does nothing")
    }

    /// A whole-list write keeps the identity of each row still at its position.
    func test_a_whole_list_write_keeps_row_identities() {
        let rows = EditableLine.rows(["a", "b"])
        let rewritten = EditableLine.rows(["a2", "b2", "c"], keeping: rows)
        XCTAssertEqual(rewritten.map(\.id).prefix(2), rows.map(\.id).prefix(2))
        XCTAssertEqual(rewritten.map(\.text), ["a2", "b2", "c"])
    }
}
