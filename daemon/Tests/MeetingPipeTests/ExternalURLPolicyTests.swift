import XCTest
@testable import MeetingPipe

/// SEC30: which URLs the app hands to the system.
final class ExternalURLPolicyTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: - Model-written text

    func test_model_text_allows_only_http_https_and_mailto() {
        for ok in ["https://example.com/a?b=c", "http://example.com", "mailto:a@b.c", "HTTPS://EXAMPLE.COM"] {
            XCTAssertTrue(ExternalURLPolicy.canOpenFromModelText(url(ok)), ok)
        }
        for bad in ["meetingpipe://stop", "meetingpipe://record", "MeetingPipe://ask?q=x", "file:///Applications/X.app",
                    "smb://h/s", "javascript:x", "x-apple.systempreferences:com.apple.preference", "ftp://h/f",
                    "obsidian://open?vault=v", "tel:123"] {
            XCTAssertFalse(ExternalURLPolicy.canOpenFromModelText(url(bad)), bad)
        }
    }

    func test_http_links_ask_first_and_mailto_does_not() {
        XCTAssertEqual(ExternalURLPolicy.modelTextDecision(url("https://x.test/?d=excerpt")), .confirm)
        XCTAssertEqual(ExternalURLPolicy.modelTextDecision(url("mailto:a@b.c")), .open)
        XCTAssertEqual(ExternalURLPolicy.modelTextDecision(url("meetingpipe://stop")), .refuse)
    }

    func test_the_guide_reads_the_same_allowlist() {
        for target in ["https://x", "mailto:a@b.c", "meetingpipe://stop", "#anchor", "../README.md", "file:///x"] {
            XCTAssertEqual(GuideDocument.canFollow(target), ExternalURLPolicy.canFollow(target), target)
        }
    }

    // MARK: - Publish targets

    private let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sec30-root-\(UUID().uuidString)", isDirectory: true)

    private func note(_ name: String = "Meeting.md", under dir: URL? = nil) throws -> URL {
        let base = dir ?? root
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent(name)
        try Data().write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return file
    }

    func test_notion_opens_https_only() {
        XCTAssertTrue(ExternalURLPolicy.canOpenPublishTarget(url("https://www.notion.so/p-1"), sink: .notion, roots: []))
        for bad in ["http://www.notion.so/p", "file:///x.md", "meetingpipe://stop", "javascript:x", "smb://h/s"] {
            XCTAssertFalse(ExternalURLPolicy.canOpenPublishTarget(url(bad), sink: .notion, roots: []), bad)
        }
    }

    func test_a_note_file_under_the_sink_root_opens() throws {
        let file = try note()
        for sink in [PublishSink.filesystem, .lan, .obsidian] {
            XCTAssertTrue(ExternalURLPolicy.canOpenPublishTarget(file, sink: sink, roots: [root]), sink.rawValue)
        }
        XCTAssertFalse(ExternalURLPolicy.canOpenPublishTarget(file, sink: .notion, roots: [root]))
    }

    func test_a_file_outside_the_root_or_not_markdown_is_refused() throws {
        let inside = try note()
        let other = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sec30-other-\(UUID().uuidString)", isDirectory: true)
        let outside = try note("Outside.md", under: other)
        XCTAssertFalse(ExternalURLPolicy.canOpenPublishTarget(outside, sink: .filesystem, roots: [root]))
        let command = try note("run.command")
        XCTAssertFalse(ExternalURLPolicy.canOpenPublishTarget(command, sink: .filesystem, roots: [root]))
        let app = url("file:///Applications/Safari.app")
        XCTAssertFalse(ExternalURLPolicy.canOpenPublishTarget(app, sink: .filesystem, roots: [root]))
        // A traversal out of the root does not pass the prefix test.
        let sneaky = URL(fileURLWithPath: root.path + "/../" + other.lastPathComponent + "/Outside.md")
        XCTAssertFalse(ExternalURLPolicy.canOpenPublishTarget(sneaky, sink: .filesystem, roots: [root]))
        _ = inside
    }

    func test_a_symlink_inside_the_root_to_outside_is_refused() throws {
        let other = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sec30-link-\(UUID().uuidString)", isDirectory: true)
        let target = try note("Secret.md", under: other)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        addTeardownBlock { try? FileManager.default.removeItem(at: self.root) }
        XCTAssertFalse(ExternalURLPolicy.canOpenPublishTarget(link, sink: .filesystem, roots: [root]))
    }

    func test_the_obsidian_deep_link_opens_for_obsidian_only() {
        let deep = url("obsidian://open?vault=V&file=a.md")
        XCTAssertTrue(ExternalURLPolicy.canOpenPublishTarget(deep, sink: .obsidian, roots: []))
        XCTAssertFalse(ExternalURLPolicy.canOpenPublishTarget(deep, sink: .filesystem, roots: []))
        XCTAssertFalse(ExternalURLPolicy.canOpenPublishTarget(url("obsidian://other"), sink: .obsidian, roots: []))
    }

    func test_openPublishTarget_opens_what_is_allowed_and_nothing_else() throws {
        var opened: [URL] = []
        XCTAssertTrue(ExternalURLPolicy.openPublishTarget(url("https://www.notion.so/p"), sink: .notion, roots: [], open: { opened.append($0) }))
        XCTAssertFalse(ExternalURLPolicy.openPublishTarget(url("meetingpipe://stop"), sink: nil, roots: [], open: { opened.append($0) }))
        XCTAssertFalse(ExternalURLPolicy.openPublishTarget(url("file:///Applications/X.app"), sink: .filesystem, roots: [root], open: { opened.append($0) }))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://www.notion.so/p"])
    }

    // MARK: - Rendering

    func test_a_refused_link_renders_as_plain_text_and_an_allowed_one_stays_a_link() {
        let attributed = SummaryMarkdown.inline("see [the deck](meetingpipe://stop) and [docs](https://example.com/x) and [mail](smb://h/s)")
        let links = attributed.runs.compactMap { $0.link?.absoluteString }
        XCTAssertEqual(links, ["https://example.com/x"])
        XCTAssertTrue(String(attributed.characters).contains("the deck"), "the label survives")
    }

    func test_rich_text_keeps_an_allowed_href_and_drops_a_refused_one() {
        XCTAssertFalse(RichTextShare.inlineHTML("[a](meetingpipe://stop)").contains("href"))
        XCTAssertEqual(RichTextShare.inlineHTML("[a](meetingpipe://stop)"), "a")
        XCTAssertTrue(RichTextShare.inlineHTML("[a](https://x.test/?p=1&q=2)").contains("href=\"https://x.test/?p=1&amp;q=2\""))
        for bad in ["file:///x.app", "smb://h/s", "javascript:alert(1)"] {
            XCTAssertFalse(RichTextShare.inlineHTML("[a](\(bad))").contains("href"), bad)
        }
    }

    // MARK: - Fences

    private func sourceFiles() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe")
        let urls = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(urls.count, 100)
        return try urls.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// Every view that renders model-written prose sits under the policy's `OpenURLAction`.
    func test_every_surface_rendering_model_text_installs_the_open_url_action() throws {
        for (name, text) in try sourceFiles()
        where text.contains("SummaryMarkdown.inline(") && name != "SummaryRenderedView.swift" {
            XCTAssertTrue(text.contains("ExternalURLPolicy.modelTextAction"), "\(name) renders model text without the SEC30 OpenURLAction")
        }
        let summary = try XCTUnwrap(try sourceFiles().first { $0.name == "SummaryRenderedView.swift" }?.text)
        XCTAssertGreaterThanOrEqual(summary.components(separatedBy: "ExternalURLPolicy.modelTextAction").count - 1, 2,
                                    "SummaryRenderedView and ActionItemRow both install it")
        // Nothing else parses markdown into a link-carrying string behind the policy's back.
        for (name, text) in try sourceFiles() where text.contains("AttributedString(markdown:") {
            XCTAssertTrue(["SummaryRenderedView.swift", "GuideDocument.swift"].contains(name), "\(name) parses markdown outside SummaryMarkdown.inline")
        }
    }

    /// The publish sidecar's URL is opened only through the policy.
    func test_publish_target_open_sites_go_through_the_policy() throws {
        let files = try sourceFiles()
        let header = try XCTUnwrap(files.first { $0.name == "MeetingDetailView+Header.swift" }?.text)
        XCTAssertFalse(header.contains("NSWorkspace.shared.open(url)"))
        XCTAssertFalse(header.contains("NSWorkspace.shared.open(local.url)"))
        XCTAssertGreaterThanOrEqual(header.components(separatedBy: "ExternalURLPolicy.openPublishTarget").count - 1, 3)
        let delegates = try XCTUnwrap(files.first { $0.name == "Coordinator+Delegates.swift" }?.text)
        XCTAssertTrue(delegates.contains("ExternalURLPolicy.openPublishTarget(url)"))
    }
}
