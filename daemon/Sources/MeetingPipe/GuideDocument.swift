import Foundation

/// The in-app user guide's content, parsed out of `docs/GUIDE.md` (DOC11).
///
/// `docs/GUIDE.md` is the single copy: it is what you read on GitHub, and
/// `install.sh` / `rebuild.sh` drop the same file into the app bundle so the
/// menu bar's **Guide…** can render it. Nothing is duplicated into the Swift
/// sources, because a second copy of a document whose whole point is staying
/// true would drift from the first one within a week.
///
/// The parser handles the block kinds the guide actually uses and nothing more:
/// headings, paragraphs, bullets, numbered items, pipe tables, and horizontal
/// rules. It is deliberately not a markdown implementation. Anything it does
/// not recognise falls through as a paragraph, so an unhandled construct reads
/// as its own source rather than disappearing.
///
/// Pure, in the `MicGate.decide` / `StatusBarModel` idiom: text in, blocks out,
/// no I/O and no globals. `bundledMarkdown()` is the one read, kept beside it so
/// the view has somewhere to ask.
enum GuideDocument {

    /// One rendered block. Inline emphasis inside `text` is left as markdown for
    /// the view to parse per block, matching `SummaryRenderedView`.
    enum Block: Equatable {
        /// `level` is 1, 2, or 3. Level 2 is what the section rail lists.
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case numbered(index: Int, text: String)
        case table(headers: [String], rows: [[String]])
        case rule
    }

    /// A level-2 heading plus where it starts, for the section rail.
    struct Section: Equatable {
        let title: String
        /// Index into the parsed block array; the rail scrolls to it.
        let blockIndex: Int
    }

    // MARK: - Parsing

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(flatten(paragraph.joined(separator: " "))))
            paragraph = []
        }

        let lines = markdown.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            if line.hasPrefix("---") && line.allSatisfy({ $0 == "-" }) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            if let heading = heading(from: line) {
                flushParagraph()
                blocks.append(heading)
                i += 1
                continue
            }

            if line.hasPrefix("| ") || line == "|" {
                flushParagraph()
                var tableLines: [String] = []
                while i < lines.count {
                    let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix("|") else { break }
                    tableLines.append(candidate)
                    i += 1
                }
                if let table = table(from: tableLines) {
                    blocks.append(table)
                } else {
                    // Not a table after all: keep the source visible rather than
                    // swallowing it.
                    blocks.append(contentsOf: tableLines.map { .paragraph(flatten($0)) })
                }
                continue
            }

            if line.hasPrefix("- ") {
                flushParagraph()
                blocks.append(.bullet(flatten(String(line.dropFirst(2)))))
                i += 1
                continue
            }

            if let numbered = numbered(from: line) {
                flushParagraph()
                blocks.append(numbered)
                i += 1
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    /// The level-2 headings, in order, for the section rail.
    static func sections(of blocks: [Block]) -> [Section] {
        blocks.enumerated().compactMap { index, block in
            guard case .heading(let level, let text) = block, level == 2 else { return nil }
            return Section(title: text, blockIndex: index)
        }
    }

    // MARK: - Line kinds

    private static func heading(from line: String) -> Block? {
        for level in stride(from: 3, through: 1, by: -1) {
            let marker = String(repeating: "#", count: level) + " "
            if line.hasPrefix(marker) {
                return .heading(level: level, text: flatten(String(line.dropFirst(marker.count))))
            }
        }
        return nil
    }

    private static func numbered(from line: String) -> Block? {
        guard let dot = line.firstIndex(of: "."),
              dot != line.startIndex,
              line.index(after: dot) < line.endIndex,
              line[line.index(after: dot)] == " " else { return nil }
        let digits = line[line.startIndex..<dot]
        guard let index = Int(digits), digits.allSatisfy(\.isNumber) else { return nil }
        let text = line[line.index(dot, offsetBy: 2)...]
        return .numbered(index: index, text: flatten(String(text)))
    }

    /// A pipe table: a header row, a `| --- |` separator, then body rows. The
    /// separator is required, so a paragraph that happens to start with a pipe
    /// is not mistaken for one.
    private static func table(from lines: [String]) -> Block? {
        guard lines.count >= 2 else { return nil }
        let headers = cells(of: lines[0])
        let separator = cells(of: lines[1])
        guard !headers.isEmpty, separator.count == headers.count,
              separator.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 == "-" || $0 == ":" } })
        else { return nil }
        let rows = lines.dropFirst(2).map { cells(of: $0) }.filter { !$0.isEmpty }
        return .table(headers: headers, rows: rows)
    }

    private static func cells(of line: String) -> [String] {
        var body = line
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.components(separatedBy: "|").map {
            flatten($0.trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: - Inline

    /// Rewrite a same-document link (`[a recipe](#anchor)`) to its label. In a
    /// file those anchors work; in the window they resolve to nothing, and a
    /// link that silently does nothing is worse than plain text. Links to a real
    /// destination are left alone.
    static func flatten(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "[") {
            guard let close = rest[open...].firstIndex(of: "]"),
                  rest.index(after: close) < rest.endIndex,
                  rest[rest.index(after: close)] == "(",
                  let end = rest[close...].firstIndex(of: ")") else {
                out += rest[..<rest.index(after: open)]
                rest = rest[rest.index(after: open)...]
                continue
            }
            let target = rest[rest.index(close, offsetBy: 2)..<end]
            let label = rest[rest.index(after: open)..<close]
            out += rest[..<open]
            out += target.hasPrefix("#") ? label : rest[open...end]
            rest = rest[rest.index(after: end)...]
        }
        out += rest
        return out
    }

    // MARK: - Loading

    /// Resource name the install scripts write into `Contents/Resources`.
    static let resourceName = "GUIDE"

    /// The bundled copy of `docs/GUIDE.md`, or nil on a build that predates it.
    static func bundledMarkdown() -> String? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Shown in place of the guide when the bundle carries no copy, which means
    /// the app was installed before DOC11. Names the fix rather than the cause.
    static let missingCopy = """
        The guide is not in this copy of the app.

        It ships as `docs/GUIDE.md` in the meeting-pipe repository, and the \
        installer puts it into the app. Re-run `./scripts/install.sh` (or \
        `./scripts/rebuild.sh`) from the repository to pick it up.
        """
}
