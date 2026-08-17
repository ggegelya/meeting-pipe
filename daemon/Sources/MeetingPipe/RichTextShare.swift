import AppKit
import Foundation

/// FEAT16: the clipboard route out of a meeting, for when the destination is a
/// chat compose box somebody is looking at right now.
///
/// The four publish sinks all write a file or a page on the pipeline's own
/// schedule, to a destination configured in advance, so none of them helps there;
/// the route before this was to find the published `.md` and paste its source,
/// which arrives as literal `## Decisions` and `- point` text.
///
/// **Three flavors on one item, always.** A single `NSPasteboardItem` can carry
/// `.rtf`, `.html` and `.string` at the same time; the receiving app takes the
/// richest flavor it understands, and Paste and Match Style (Cmd+Shift+V in
/// Teams, Slack, Notes and the rest) reads the plain one. Writing all three is
/// what makes "keep the formatting" and "keep paste-without-formatting working"
/// the same feature rather than a tradeoff. Writing only HTML is the failure
/// mode: it looks right on the first paste and silently removes the owner's
/// plain-paste option everywhere. `daemon/docs/gotchas.md` carries the rest.
///
/// Deliberately not `NSSharingServicePicker`: a Teams or Meet compose box is not
/// a share-service target, and the clipboard is the transport the owner
/// described.
enum RichTextShare {

    /// One document in the two flavors that are *rendered*. `.rtf` is derived from
    /// `html` at write time (`rtf(html:)`), so HTML stays the single source and
    /// there is no hand-built RTF to keep in step with it.
    struct Document: Equatable, Sendable {
        let html: String
        let plain: String
    }

    // MARK: - Markdown in, both flavors out

    /// Build both flavors from one markdown document.
    ///
    /// This is the *summary's* path, and its input is markdown by construction:
    /// `AppleIntelligenceSummarizer.renderMarkdown` is the one summary renderer on
    /// this side and the CI3 `summary-md-golden.json` fixture pins it against
    /// Python's `render_summary_md`. The transcript deliberately does not come
    /// through here; see `MeetingShare.transcriptDocument`.
    static func document(markdown: String) -> Document {
        Document(html: page(bodyHTML(markdown: markdown)), plain: plain(markdown: markdown))
    }

    // MARK: - The pasteboard write

    /// Put `document` on `pasteboard` as **one** item carrying all three flavors.
    ///
    /// Takes the board as a parameter rather than reaching for `.general` inside,
    /// following AUTO4's `AutomationReference.copyTemplate`, so the tests pin real
    /// behaviour against a scratch board instead of stomping the owner's clipboard
    /// on every run.
    ///
    /// Call on the main thread: `rtf(html:)` below is main-thread-only.
    @discardableResult
    static func write(_ document: Document, to pasteboard: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        // Richest first. A receiver that asks `availableType(from:)` with its own
        // preference list gets the same answer whatever the order is, but one that
        // walks `types` takes the first flavor it understands.
        if let rtf = rtf(html: document.html) { item.setData(rtf, forType: .rtf) }
        item.setString(document.html, forType: .html)
        item.setString(document.plain, forType: .string)
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    /// RTF derived from the HTML, via `NSAttributedString`'s HTML reader.
    ///
    /// Derived rather than hand-built on purpose: an RTF writer of our own would be
    /// a second renderer to keep in step with this one, for a flavor only the
    /// oldest receivers ask for. Best-effort, so a conversion that fails costs the
    /// `.rtf` flavor and not the whole copy; `RichTextShareTests` pins that it does
    /// not in fact fail.
    ///
    /// **Main thread only.** `NSAttributedString`'s HTML reader is documented as
    /// such, so every caller of `write` is too.
    static func rtf(html: String) -> Data? {
        guard let data = html.data(using: .utf8) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let attributed = try? NSAttributedString(
            data: data, options: options, documentAttributes: nil
        ) else {
            return nil
        }
        return attributed.rtf(
            from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]
        )
    }

    // MARK: - HTML

    /// Wrap rendered body markup as a document. The charset is what keeps a
    /// Cyrillic transcript from arriving as mojibake in a receiver that guesses.
    static func page(_ bodyHTML: String) -> String {
        "<html><head><meta charset=\"utf-8\"></head><body>\n\(bodyHTML)\n</body></html>"
    }

    /// The block level: headings, paragraphs, and the two kinds of list.
    ///
    /// Deliberately not a general markdown engine and deliberately not a
    /// dependency: it covers the subset these documents actually emit, which is
    /// what `renderMarkdown` writes and nothing else.
    static func bodyHTML(markdown: String) -> String {
        var out: [String] = []
        var openList: ListKind? = nil

        func close() {
            if let kind = openList {
                out.append(kind.closeTag)
                openList = nil
            }
        }
        func open(_ kind: ListKind) {
            if openList != kind {
                close()
                out.append(kind.openTag)
                openList = kind
            }
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                close()
                continue
            }
            if let heading = Self.heading(line) {
                close()
                out.append("<h\(heading.level)>\(inlineHTML(heading.text))</h\(heading.level)>")
            } else if let text = Self.bullet(line) {
                open(.unordered)
                out.append("<li>\(inlineHTML(text))</li>")
            } else if let text = Self.numbered(line) {
                open(.ordered)
                out.append("<li>\(inlineHTML(text))</li>")
            } else {
                close()
                out.append("<p>\(inlineHTML(line))</p>")
            }
        }
        close()
        return out.joined(separator: "\n")
    }

    private enum ListKind {
        case unordered, ordered
        var openTag: String { self == .unordered ? "<ul>" : "<ol>" }
        var closeTag: String { self == .unordered ? "</ul>" : "</ol>" }
    }

    /// The inline level over one already-block-classified line: bold, italic,
    /// inline code and proper `[text](url)` links, on HTML-escaped text.
    ///
    /// Escaping runs first, so a `<` in the prose can never open a tag and the
    /// markers below are untouched by it (none of `*`, `_`, backtick, `[` is an
    /// entity). The `&` pass also leaves a query-string `&` correct inside an
    /// `href`.
    static func inlineHTML(_ s: String) -> String {
        var text = escape(s)
        // Code first, so a marker inside a code span is not also emphasis bait.
        text = replace(text, #"`([^`]+)`"#, with: "<code>$1</code>")
        // Bold before italic: `**` has to be consumed before a single `*` rule sees it.
        text = replace(text, #"\*\*(.+?)\*\*"#, with: "<strong>$1</strong>")
        text = replace(text, #"\*([^*]+)\*"#, with: "<em>$1</em>")
        // Underscore emphasis needs word boundaries or `some_file_name` becomes italic.
        text = replace(text, #"(?<![A-Za-z0-9_])_([^_]+)_(?![A-Za-z0-9_])"#, with: "<em>$1</em>")
        text = replace(text, #"\[([^\]]*)\]\(([^)\s]+)\)"#, with: "<a href=\"$2\">$1</a>")
        return text
    }

    /// HTML-escape body text and attribute values in one pass. `&` first, or the
    /// entities the later rules introduce get escaped again.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Plain text

    /// The readable plain rendering, which is the half of the ask that a rich-only
    /// implementation silently breaks.
    ///
    /// Heading markers go (a chat has no `##`), list markers stay (`- ` and `1. `
    /// read as lists in any plain-text field), and the inline markers are dropped
    /// down to the words they were decorating. A link keeps its destination in
    /// parentheses rather than losing it, since the text alone would be a dead
    /// reference.
    static func plain(markdown: String) -> String {
        var out: [String] = []
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                out.append("")
            } else if let heading = Self.heading(line) {
                out.append(inlinePlain(heading.text))
            } else {
                out.append(inlinePlain(line))
            }
        }
        // One trailing newline, the shape `renderMarkdown` itself ends on.
        return out.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    /// Strip the inline markers from one line, keeping the words.
    static func inlinePlain(_ s: String) -> String {
        var text = s
        text = replace(text, #"`([^`]+)`"#, with: "$1")
        text = replace(text, #"\*\*(.+?)\*\*"#, with: "$1")
        text = replace(text, #"\*([^*]+)\*"#, with: "$1")
        text = replace(text, #"(?<![A-Za-z0-9_])_([^_]+)_(?![A-Za-z0-9_])"#, with: "$1")
        text = replace(text, #"\[([^\]]*)\]\(([^)\s]+)\)"#, with: "$1 ($2)")
        return text
    }

    // MARK: - Block classification

    /// `# `, `## `, `### ` and nothing deeper: these documents emit no `####`.
    static func heading(_ line: String) -> (level: Int, text: String)? {
        for level in [3, 2, 1] {
            let marker = String(repeating: "#", count: level) + " "
            if line.hasPrefix(marker) {
                return (level, String(line.dropFirst(marker.count)))
            }
        }
        return nil
    }

    /// `- item`. A `---` rule is not a bullet, and neither is a bare `-`.
    static func bullet(_ line: String) -> String? {
        guard line.hasPrefix("- ") else { return nil }
        return String(line.dropFirst(2))
    }

    /// `1. item`, the shape `renderMarkdown` numbers decisions with.
    static func numbered(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return String(line.dropFirst(digits.count + 2))
    }

    // MARK: - Regex helper

    /// One `NSRegularExpression` pass. A pattern that fails to compile leaves the
    /// text alone rather than trapping: these patterns are literals, so a failure
    /// here would be a programming error, and losing the copy would be a worse way
    /// to report it than losing the emphasis.
    private static func replace(_ s: String, _ pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        return regex.stringByReplacingMatches(
            in: s,
            range: NSRange(s.startIndex..., in: s),
            withTemplate: template
        )
    }
}

// MARK: - What a meeting's two documents are

/// FEAT16: the two documents a meeting can be copied out as, built from what the
/// reader is looking at rather than from the raw files.
///
/// **What is on disk is not what the reader sees**, and that is the whole reason
/// this type exists rather than a `path -> String` helper. Speaker renames live in
/// `SpeakerLabelStore` and text edits in `TranscriptCorrectionStore`, both
/// reversible overlays applied at read time rather than written back into
/// `<stem>.json`, and `TranscriptDisplay.displayName` maps `speaker_0` to
/// `Speaker 1` and `THEM-A` to `Unknown A`. A share implemented as "read the file,
/// render it" copies raw internal ids and un-corrected text, and it looks correct
/// in every test that does not specifically check for it.
///
/// So the resolution here is the tabs' own: `TranscriptLoader.load` (which applies
/// the corrections) then `MeetingCast.rowSpeaker`, which `daemon/CLAUDE.md` names
/// as the one read for a row's speaker. Nothing is re-derived.
enum MeetingShare {

    /// Which of a meeting's two documents. The raw value is the `item` its
    /// `detail` / `toolbar_action` event carries, so the menu and the log cannot
    /// disagree about what was copied.
    enum Surface: String, CaseIterable, Sendable {
        case summary = "copy_summary_rich"
        case transcript = "copy_transcript_rich"

        /// The menu item's words. Copy names the mechanism, not the metaphor: this
        /// puts formatted text on the clipboard, so the label says copy rather than
        /// implying a share sheet that would offer mail and AirDrop.
        var menuLabel: String {
            switch self {
            case .summary:    return "Copy summary (formatted)"
            case .transcript: return "Copy transcript (formatted)"
            }
        }

        /// What is missing, in the words the "nothing to copy yet" report uses.
        var noun: String {
            switch self {
            case .summary:    return "summary"
            case .transcript: return "transcript"
            }
        }
    }

    /// One transcript line as the reader has it: the name the row shows, and the
    /// text after any correction overlay.
    struct Line: Equatable, Sendable {
        let start: TimeInterval
        let speaker: String
        let text: String
    }

    /// Resolve loaded segments into the lines the transcript tab renders.
    ///
    /// The speaker comes from `MeetingCast.rowSpeaker`, never `segment.speakerID`,
    /// which is what makes a per-line reassignment and a cluster rename both show
    /// up here. The text is already overlaid, because `TranscriptLoader.load`
    /// applies `TranscriptCorrectionStore` before it returns.
    static func lines(
        segments: [TranscriptSegment],
        overlay: SpeakerLabelStore.Overlay,
        voiceprintLabels: Set<String>
    ) -> [Line] {
        segments.map { segment in
            let speaker = MeetingCast.rowSpeaker(
                for: segment, overlay: overlay, voiceprintLabels: voiceprintLabels
            )
            return Line(start: segment.start, speaker: speaker.displayName, text: segment.text)
        }
    }

    /// The summary, through the one summary renderer this side has.
    ///
    /// `deeplinkStem` is deliberately left off, so an evidence anchor renders as
    /// readable ` [12:34]` text rather than as a `meetingpipe://` link. The
    /// destination here is somebody else's chat window, where a link into this Mac's
    /// copy of the app resolves to nothing.
    static func summaryDocument(_ summary: MeetingSummary) -> RichTextShare.Document {
        RichTextShare.document(markdown: AppleIntelligenceSummarizer.renderMarkdown(summary))
    }

    /// The transcript, rendered here rather than routed through the markdown path.
    ///
    /// That split is on purpose. `TranscriptRow` renders the spoken text as
    /// `Text(segment.text)`, a plain `String` with no markdown parsing, so a line
    /// reading `we need *some* buy-in` shows its asterisks in the app. Sending that
    /// line through a markdown renderer on the way to the clipboard would silently
    /// turn one word italic and drop two characters the reader can see, which is
    /// the same class of divergence as reading the raw file. So the timestamp and
    /// the speaker name are marked up, and the words are escaped and otherwise
    /// left exactly as they are.
    static func transcriptDocument(title: String, lines: [Line]) -> RichTextShare.Document {
        var body: [String] = ["<h1>\(RichTextShare.escape(title))</h1>"]
        var plain: [String] = [title, ""]
        for line in lines {
            let stamp = TranscriptDisplay.timestamp(line.start)
            body.append(
                "<p><strong>\(RichTextShare.escape(line.speaker))</strong>"
                + " (\(stamp)): \(RichTextShare.escape(line.text))</p>"
            )
            plain.append("\(line.speaker) (\(stamp)): \(line.text)")
        }
        return RichTextShare.Document(
            html: RichTextShare.page(body.joined(separator: "\n")),
            plain: plain.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
        )
    }

    /// The document for one surface, off the same files and through the same two
    /// resolutions the tabs render with. `nil` is "there is nothing there yet",
    /// which the caller reports rather than silently leaving the last copy on the
    /// clipboard.
    ///
    /// Reads disk, so call it off the main thread; an 80-minute transcript is a real
    /// parse.
    static func document(
        _ surface: Surface,
        stem: String,
        title: String,
        in directory: URL
    ) -> RichTextShare.Document? {
        switch surface {
        case .summary:
            // The same file `SummaryTab` renders, which is the truth for the summary:
            // UX26's action checkboxes write back into it, so the reader and this
            // cannot disagree.
            let url = directory.appendingPathComponent("\(stem).summary.json")
            guard let summary = MeetingSummary.load(from: url) else { return nil }
            return summaryDocument(summary)
        case .transcript:
            guard let loaded = TranscriptLoader.load(stem: stem, in: directory) else { return nil }
            let rows = lines(
                segments: loaded.segments,
                overlay: loaded.speakerOverlay,
                voiceprintLabels: loaded.voiceprintLabels
            )
            guard !rows.isEmpty else { return nil }
            return transcriptDocument(title: title, lines: rows)
        }
    }
}
