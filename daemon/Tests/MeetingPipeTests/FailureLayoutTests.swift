import AppKit
import SwiftUI
import XCTest
@testable import MeetingPipe

final class FailureLayoutTests: XCTestCase {
    private static let longDiagnostic = String(repeating: "Synthetic traceback frame /Users/private sk-fake transcript-secret\n", count: 2000)

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    struct Element {
        let object: NSObject
        func value(_ key: String) -> Any? {
            guard object.responds(to: NSSelectorFromString(key)) else { return nil }
            return object.value(forKey: key)
        }
        func accessibilityLabel() -> String? { value("accessibilityLabel") as? String }
        func accessibilityValue() -> Any? { value("accessibilityValue") }
        func accessibilityRole() -> NSAccessibility.Role? {
            (value("accessibilityRole") as? String).map(NSAccessibility.Role.init)
        }
        func accessibilityTitle() -> String? { value("accessibilityTitle") as? String }
        func accessibilityFrame() -> NSRect { (value("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
        func press() { _ = object.perform(NSSelectorFromString("accessibilityPerformPress")) }
    }

    @MainActor
    private func elements(_ root: Any) -> [Element] {
        guard let object = root as? NSObject else { return [] }
        let element = Element(object: object)
        return [element] + ((element.value("accessibilityChildren") as? [Any]) ?? []).flatMap(elements)
    }

    @MainActor
    private func host<V: View>(_ view: V, size: NSSize) -> NSWindow {
        NSApplication.shared.setActivationPolicy(.regular)
        if NSApp.responds(to: NSSelectorFromString("setAccessibilityEnhancedUserInterface:")) {
            NSApp.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        }
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = host
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.layoutIfNeeded()
        host.view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        return window
    }

    @MainActor
    private func assertVisible(_ labels: [String], in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) throws {
        let view = try XCTUnwrap(window.contentView, file: file, line: line)
        let visible = window.convertToScreen(view.bounds).insetBy(dx: -1, dy: -1)
        let nodes = elements(window)
        for label in labels {
            let node = try XCTUnwrap(nodes.first { $0.accessibilityLabel() == label }, "Missing \(label)", file: file, line: line)
            XCTAssertTrue(visible.contains(node.accessibilityFrame()), "\(label) escaped \(visible): \(node.accessibilityFrame())", file: file, line: line)
            XCTAssertGreaterThan(node.accessibilityFrame().height, 12, label, file: file, line: line)
        }
        XCTAssertFalse(nodes.contains { ($0.accessibilityValue() as? String ?? "").contains("Synthetic traceback frame") }, file: file, line: line)
    }

    @MainActor
    private func snapshot(_ window: NSWindow, name: String) throws {
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/ux80-\(name).png"))
        if let directory = ProcessInfo.processInfo.environment["UX80_LAYOUT_IMAGES"] {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), directory + "/" + name + ".png"]
            try capture.run()
            capture.waitUntilExit()
        }
    }

    @MainActor
    func test_real_detail_keeps_tabs_and_actions_visible_with_long_diagnostics() throws {
        NSApplication.shared.setActivationPolicy(.regular)
        if NSApp.responds(to: NSSelectorFromString("setAccessibilityEnhancedUserInterface:")) {
            NSApp.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = LibraryWindowModel(recordingsDir: dir, savedSearchesURL: dir.appendingPathComponent("searches.json"))
        let stem = "20260908-163051"
        try "Synthetic finalized transcript".write(to: dir.appendingPathComponent(stem + ".md"), atomically: true, encoding: .utf8)
        try Data(#"{"finalized":true,"segments":[{"text":"Synthetic finalized transcript","start":0,"end":1}]}"#.utf8)
            .write(to: dir.appendingPathComponent(stem + ".json"))
        for lines in [51, 2000] {
            for size in [NSSize(width: 450, height: 480), NSSize(width: 900, height: 800)] {
                let diagnostic = String(repeating: "Synthetic traceback frame with a long private path\n", count: lines)
                    + "anthropic.BadRequestError: Your credit balance is too low to access the Anthropic API."
                let meeting = Meeting(stem: stem, startedAt: Date(), audioURL: nil, recordingsDir: dir,
                    summaryTitle: nil, meetingTitle: "Synthetic failure", sourceBundleID: nil,
                    sourceDisplayName: "Synthetic call", sourceKind: .native, workflowName: "Work", workflowColor: nil,
                    durationSec: 3600, backend: "anthropic", modelId: "synthetic-model", status: .failed,
                    failureReason: diagnostic, failureStage: "pipeline", searchableText: "", hasTranscriptMD: true, canReuseTranscript: true)
                let host = NSHostingController(rootView: MeetingDetailView(store: model.meetingStore, meeting: meeting).environmentObject(model))
                host.sizingOptions = []
                let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size),
                                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.contentViewController = host
                window.setContentSize(size)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                defer { window.orderOut(nil) }
                window.layoutIfNeeded()
                host.view.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                let nodes = elements(window)

                let visible = window.convertToScreen(host.view.bounds)
                for label in ["Summary", "Transcript", "Audio", "More actions", "Open billing", "Retry summary", "Failure details"] {
                    let node = try XCTUnwrap(nodes.first { $0.accessibilityLabel() == label }, "Missing \(label)")
                    let frame = node.accessibilityFrame()
                    XCTAssertGreaterThan(frame.height, 12, label)
                    XCTAssertTrue(visible.insetBy(dx: -1, dy: -1).contains(frame), "\(label): \(frame), viewport \(visible)")
                }
                XCTAssertGreaterThan(try XCTUnwrap(nodes.first { $0.accessibilityRole() == .scrollArea }).accessibilityFrame().height, 100)
                if lines == 51 && size.width == 450 { try snapshot(window, name: "library-min") }
                try XCTUnwrap(nodes.first { $0.accessibilityLabel() == "Failure details" }).press()
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                let sheet = try XCTUnwrap(window.sheets.first)
                let details = elements(sheet)
                XCTAssertNotNil(details.first { $0.accessibilityLabel() == "Close" })
                XCTAssertNotNil(details.first { $0.accessibilityLabel() == "Copy report" })
                let text = try XCTUnwrap(descendants(sheet.contentView!).compactMap { $0 as? NSTextView }.first { $0.string == diagnostic })
                XCTAssertFalse(text.isEditable)
                XCTAssertTrue(text.isSelectable)
                text.scrollToEndOfDocument(nil)
                XCTAssertGreaterThan(text.visibleRect.maxY, text.bounds.height - 20)
                if lines == 51 && size.width == 450 { try snapshot(sheet, name: "details") }
                let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
                sheet.sendEvent(escape)
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                XCTAssertTrue(window.sheets.isEmpty, "Escape must close Details")
                XCTAssertFalse(nodes.contains { ($0.accessibilityValue() as? String ?? "").contains("Synthetic traceback frame") })
                for tab in ["Transcript", "Audio", "Summary"] {
                    try XCTUnwrap(elements(window).first { $0.accessibilityLabel() == tab }).press()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                    try assertVisible(["Summary", "Transcript", "Audio", "Failure details"], in: window)
                }
            }
        }
    }

    @MainActor
    func test_details_copies_the_exact_visible_report_to_an_isolated_clipboard() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let failure = FailurePresentation(diagnostics: Self.longDiagnostic, operation: .ask,
                                          timestamp: "2026-09-08T13:30:51Z")
        let window = host(FailureDetailsView(failure: failure, copyReport: { FailureReport.copy($0, to: board) }, close: {}),
                          size: NSSize(width: 620, height: 500))
        defer { window.orderOut(nil) }
        let preview = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSTextView }
            .first { $0.string.hasPrefix("MeetingPipe failure report") })
        try XCTUnwrap(elements(window).first { $0.accessibilityLabel() == "Copy report" }).press()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(board.string(forType: .string), preview.string)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unavailable"
        XCTAssertEqual(preview.string, """
        MeetingPipe failure report
        App version: \(version)
        Timestamp: 2026-09-08T13:30:51Z
        Operation: ask
        Cause: unknown
        """)
    }

    @MainActor
    private final class FailingAsk: AskRunning {
        var calls = 0
        func askMeetings(question: String) async -> Result<AskAnswer, Error> {
            calls += 1
            return .failure(PipelineLauncher.LaunchError.nonZeroExit(1, FailureLayoutTests.longDiagnostic))
        }
        func cancelAsk() {}
    }

    @MainActor
    func test_hosted_digest_people_ask_and_dialog_errors_keep_controls_reachable() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = LibraryWindowModel(recordingsDir: dir, savedSearchesURL: dir.appendingPathComponent("searches.json"))
        let digest = DigestListModel()
        digest.failure = FailurePresentation(diagnostics: Self.longDiagnostic, operation: .digest)
        let runner = FailingAsk()
        let ask = AskModel(runner: runner)
        XCTAssertTrue(ask.ask("Synthetic question"))
        while ask.isAsking { await Task.yield() }
        let surfaces: [(String, AnyView, NSSize)] = [
            ("digest", AnyView(DigestsView(model: digest, libraryModel: model)), NSSize(width: 320, height: 480)),
            ("people", AnyView(PeopleView(store: model.meetingStore, commitments: [], onOpenMeeting: { _ in },
                errorText: FailurePresentation(diagnostics: Self.longDiagnostic, operation: .renameVoice))), NSSize(width: 320, height: 480)),
            ("ask", AnyView(AskView(model: model, askModel: ask, onOpenMeeting: { _ in })), NSSize(width: 660, height: 640)),
            ("narrow", AnyView(FailureNotice(failure: FailurePresentation(diagnostics: "", operation: .summary,
                metadata: FailureMetadata(cause: .credits, operation: .summary, provider: "anthropic")),
                retryLabel: "Retry summary", retry: {}).padding()), NSSize(width: 260, height: 300))
        ]
        for (name, view, size) in surfaces {
            let window = host(view, size: size)
            defer { window.orderOut(nil) }
            try assertVisible(["Failure details"], in: window)
            let detail = try XCTUnwrap(elements(window).first { $0.accessibilityLabel() == "Failure details" })
            if name != "narrow" {
                XCTAssertGreaterThan(detail.accessibilityFrame().minY - window.frame.minY, name == "ask" ? 40 : 90)
            } else { try assertVisible(["Open billing", "Retry summary"], in: window) }
            try snapshot(window, name: name)
        }
        XCTAssertEqual(runner.calls, 1, "Rendering failures and Details must not retry")
        let alert = FailureDialog.alert(for: FailurePresentation(diagnostics: Self.longDiagnostic, operation: .renameVoice))
        alert.layout()
        XCTAssertLessThan(alert.window.frame.height, 360)
        XCTAssertEqual(alert.buttons.map(\.title), ["OK", "Details…"])
        XCTAssertFalse(alert.informativeText.contains("Synthetic traceback"))
    }

    private final class FailingNotionProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse,
                userInfo: [NSLocalizedDescriptionKey: FailureLayoutTests.longDiagnostic]))
        }
        override func stopLoading() {}
    }

    @MainActor
    func test_missing_search_model_keeps_its_own_download_remedy() throws {
        let diagnostic = "Embedding model 'synthetic/search-model' is not in the local HuggingFace cache, and this is a regulated/NDA run, so it cannot be downloaded now. Fetch it outside a zero-egress meeting first:\n    mp prefetch-model synthetic/search-model"
        let failure = FailurePresentation(diagnostics: diagnostic, operation: .ask)
        var downloads = 0
        let window = host(FailureNotice(failure: failure, downloadModel: { downloads += 1 }).padding(),
                          size: NSSize(width: 400, height: 260))
        defer { window.orderOut(nil) }
        XCTAssertEqual(failure.title, "The search model is missing")
        XCTAssertTrue(failure.explanation.contains("Details"))
        XCTAssertEqual(failure.diagnostics, diagnostic)
        XCTAssertNil(failure.settingsLabel)
        XCTAssertFalse(elements(window).contains { $0.accessibilityLabel() == "Download model" },
                       "The summary-model download cannot install Ask's search model")
        try assertVisible(["Failure details"], in: window)
        XCTAssertEqual(downloads, 0)
    }

    @MainActor
    func test_preferences_integration_error_keeps_picker_and_details_visible() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingNotionProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let oldToken = getenv("NOTION_TOKEN").map { String(cString: $0) }
        setenv("NOTION_TOKEN", "synthetic-token", 1)
        defer {
            if let oldToken { setenv("NOTION_TOKEN", oldToken, 1) } else { unsetenv("NOTION_TOKEN") }
        }
        let list = NotionDatabaseList(cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                     session: session, isRegulated: { false })
        list.refresh()
        while list.state == .loading { await Task.yield() }
        guard case .failed(let diagnostic) = list.state else { return XCTFail("Expected the synthetic failure") }
        XCTAssertGreaterThan(diagnostic.count, 4096)
        let window = host(NotionDatabasePicker(databaseID: .constant(""), list: list).padding(), size: NSSize(width: 520, height: 300))
        defer { window.orderOut(nil) }
        try assertVisible(["Failure details", "Fetch databases"], in: window)
        try snapshot(window, name: "preferences")
    }
}
