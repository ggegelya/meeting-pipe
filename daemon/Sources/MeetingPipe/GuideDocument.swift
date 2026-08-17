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
/// Three of its rules exist because one file serves two readers (DOC13). A
/// contributor reads it in a checkout, where a path is navigable; a user reads
/// it in this window, where a path is a dead end and a *link* to one is worse,
/// because it looks like a working cross-reference. So the parser drops
/// `repo-only` blocks, flattens any link it cannot follow, and lets a section
/// heading own its own break. Editorial discipline is the other half and lives
/// in the document's own repo-only preamble; these are the half that holds when
/// discipline slips.
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

    // MARK: - Repo-only content

    /// Opens a run of lines the window never sees. A markdown renderer hides the
    /// marker and shows what follows; this parser does the opposite, which is
    /// what lets one file carry a contents list, a pointer to a sibling
    /// document, and a note to its next editor without any of it reaching a
    /// reader who has no checkout to resolve them against (DOC13).
    static let repoOnlyOpen = "<!-- repo-only -->"
    /// Closes a `repoOnlyOpen` run.
    static let repoOnlyClose = "<!-- /repo-only -->"

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

            if line == Self.repoOnlyOpen {
                flushParagraph()
                i += 1
                while i < lines.count,
                      lines[i].trimmingCharacters(in: .whitespaces) != Self.repoOnlyClose {
                    i += 1
                }
                // Steps past the close, or past the end when the block was never
                // closed. An unclosed block therefore swallows the rest of the
                // document, which is the safe direction to fail (contributor
                // content stays out) and the loud one to catch: the balance is
                // fenced by `GuideDocumentTests`, so the authoring mistake is a
                // red suite rather than a leak.
                i += 1
                continue
            }

            // A close with no open is a no-op rather than a paragraph, so the
            // marker never renders as literal text in the window.
            if line == Self.repoOnlyClose {
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
        return collapsingSectionRules(blocks)
    }

    /// Drop a horizontal rule that sits immediately above a level-2 heading.
    ///
    /// In a file the `---` before each `## Section` is the break. On screen the
    /// heading already is one: it arrives with its own space above it and at a
    /// larger size, so the hairline lands as a second separator a few points
    /// away from the first, and ten of those down a document is most of what
    /// makes a rendered markdown file look like a rendered markdown file rather
    /// than an application. Whitespace does the separating instead, which is
    /// what `design/README.md` asks for ("the blank paper *is* the texture").
    ///
    /// Only that one adjacency. A rule between two paragraphs still renders,
    /// because there it is the only break there is.
    private static func collapsingSectionRules(_ blocks: [Block]) -> [Block] {
        blocks.enumerated().compactMap { index, block in
            guard case .rule = block, index + 1 < blocks.count else { return block }
            guard case .heading(let level, _) = blocks[index + 1], level == 2 else { return block }
            return nil
        }
    }

    /// The level-2 headings, in order, for the section rail.
    static func sections(of blocks: [Block]) -> [Section] {
        blocks.enumerated().compactMap { index, block in
            guard case .heading(let level, let text) = block, level == 2 else { return nil }
            return Section(title: text, blockIndex: index)
        }
    }

    /// Which section the rail marks as current, given each section heading's
    /// vertical offset from the top of the reading viewport (negative once it
    /// has scrolled off the top).
    ///
    /// The current section is the last one whose heading has reached the top
    /// band, which is how a reader thinks about it: you are in the section whose
    /// heading you most recently passed. Pure and explicitly-fed in the
    /// `MicGate.decide` idiom, because the alternative is scroll arithmetic
    /// buried in a view body where nothing can test it.
    ///
    /// Above the first heading, in the guide's opening paragraphs, this answers
    /// with the first section rather than with nothing. That is the one place it
    /// is deliberately not literal: a rail with no mark at all reads as broken
    /// on open, and a reader in the preamble is on their way into recipe 1.
    static func currentSection(
        offsets: [Int: CGFloat],
        sections: [Section],
        threshold: CGFloat = 28
    ) -> Int? {
        guard let first = sections.first else { return nil }
        let passed = sections.filter { section in
            guard let y = offsets[section.blockIndex] else { return false }
            return y <= threshold
        }
        return passed.last?.blockIndex ?? first.blockIndex
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

    /// Destinations this window can actually follow. Everything else is a dead
    /// link on screen, so `flatten` reduces it to its label.
    ///
    /// An allowlist rather than a list of shapes to reject, because the shapes
    /// that fail are open-ended (`#anchor`, `./SETUP.md`, `../README.md`,
    /// `docs/GUIDE.md`, a bare `assets/x.png`) while the ones that work are a
    /// closed set: something the system can open. Rejecting shapes is how DOC11
    /// caught the anchor case and missed the four repo paths beside it.
    private static let followableSchemes: Set<String> = ["http", "https", "mailto"]

    /// Whether a link target resolves to anything when the guide is read in a
    /// window rather than in a checkout.
    static func canFollow(_ target: String) -> Bool {
        guard let colon = target.firstIndex(of: ":") else { return false }
        return followableSchemes.contains(target[..<colon].lowercased())
    }

    /// Rewrite a link the window cannot follow (`[a recipe](#anchor)`,
    /// `[the readme](../README.md)`) down to its label.
    ///
    /// DOC11 did this for same-document anchors, for the recorded reason that
    /// "one in a window resolves to nothing". A repo-relative path has the
    /// identical property and fails worse: an anchor that does nothing is a
    /// disappointment, while a live-looking link to a document the reader has
    /// just been told is authoritative is a promise the app cannot keep. DOC13
    /// widened the rule to cover both rather than inventing a second one. Links
    /// to a real destination are left alone for the view's inline parser.
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
            out += canFollow(String(target)) ? rest[open...end] : label
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
    ///
    /// It keeps its two script names where DOC13 stripped every other repo path
    /// out of the guide, because this is the one state with no control behind
    /// it: re-running the installer is the whole fix, and a message in product
    /// register that named no command would leave the reader stuck. What went
    /// was the sentence about which file it ships as, which the reader cannot
    /// act on.
    static let missingCopy = """
        The guide is not in this copy of the app.

        That means this build was installed before the guide existed. \
        Re-running the installer (`./scripts/install.sh`, or \
        `./scripts/rebuild.sh`) picks it up.
        """
}
