import AppKit
import SwiftUI

/// Renders the parsed `docs/GUIDE.md` (DOC11): a rail of the guide's recipe
/// headings on the left, the document on the right at the same reading measure
/// every other reading surface uses. Read-only, no state worth keeping, no
/// network: it is a document in a window.
///
/// DOC13 took a visual pass over it against `design/README.md` and `PRODUCT.md`,
/// with the app's own surfaces as the comparison rather than taste, because the
/// owner's verdict on DOC11's version was that it read as a different and much
/// older application than the Library sitting beside it. Three things carried
/// most of that, and each has a sibling in this app to match:
///
/// - **The rail did not say where you were.** Every other rail here (the
///   Library's scopes, Preferences' panes) marks its current row with the teal
///   selection wash and groups under an uppercase eyebrow; this one was a plain
///   column of grey buttons with no selected state, no hover, and no header.
///   `GuideDocument.currentSection` supplies the mark; the tokens supply the
///   rest.
/// - **The type ramp was chrome-shaped on a content surface.** It used the fixed
///   `mpText*` sizes while the transcript and the summary, the two surfaces a
///   reader spends real time in, use Dynamic Type. `PRODUCT.md`'s a11y floor
///   names markdown rendering explicitly. The styles below were chosen so the
///   default sizes are unchanged (macOS `.title` is 22 like `MPType.textXL`,
///   `.title2` 17, `.title3` 15, `.body` 13, `.callout` 12): same picture at the
///   default setting, and it scales now.
/// - **Everything was one flat grey.** Body copy sat at `fgMuted`, the colour
///   this app uses for captions and secondary rows, so a whole document read as
///   secondary text; headings at every level got the same space above them, so
///   there was no hierarchy to see; and the ten `---` rules landed a hairline a
///   few points above each section heading. Body copy is `fg` now (what the
///   transcript and the summary use), the heading leads step, and the parser
///   lets a section heading own its own break.
struct GuideView: View {
    @State private var blocks: [GuideDocument.Block] = []
    @State private var sections: [GuideDocument.Section] = []

    /// Block index of the section the reader is currently inside, from
    /// `GuideDocument.currentSection` over the heading probes below.
    @State private var current: Int?
    /// The rail's jump target. Held here rather than in the rail so the two
    /// columns share one reader.
    @State private var jumpTarget: Int?
    @State private var hovered: Int?

    /// Named so a heading's probe can report its offset inside the reading
    /// viewport rather than in an ancestor that scrolls with it.
    private static let scrollSpace = "guide-document"

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider().overlay(Color(MPColors.border))
            document
        }
        .background(Color(MPColors.bg))
        .onAppear(perform: load)
    }

    // MARK: - Rail

    private var rail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MPSpace.s1) {
                // The eyebrow every other rail in the app wears (`LibrarySidebar`
                // over each of its four groups). Without it the column reads as
                // loose text beside the document rather than as navigation.
                Text("Contents")
                    .font(.mpTextXS.weight(.semibold))
                    .tracking(MPType.trackingCaps * MPType.textXS)
                    .textCase(.uppercase)
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .padding(.horizontal, MPSpace.s2)
                    .padding(.bottom, MPSpace.s1)

                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    railRow(section)
                }
            }
            .padding(.vertical, MPSpace.s3)
            .padding(.horizontal, MPSpace.s2)
        }
        // The Library's rail width, so the two windows line up side by side
        // rather than being 12pt apart for no reason anybody could name.
        .frame(width: LibraryLayout.sidebarIdealWidth)
        .background(Color(MPColors.bgSunk))
    }

    private func railRow(_ section: GuideDocument.Section) -> some View {
        let isCurrent = current == section.blockIndex
        return Button {
            jumpTarget = section.blockIndex
        } label: {
            Text(section.title)
                .font(.mpTextSM)
                // A rail is chrome, so it keeps the fixed mac-native size while
                // the document beside it scales (PRODUCT.md's a11y section draws
                // that line: content surfaces take Dynamic Type, chrome does not).
                .foregroundStyle(Color(isCurrent ? MPColors.fg : MPColors.fgMuted))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, MPSpace.s1)
                .padding(.horizontal, MPSpace.s2)
                .background(
                    RoundedRectangle(cornerRadius: MPRadius.sm)
                        .fill(rowFill(isCurrent: isCurrent, isHovered: hovered == section.blockIndex))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = section.blockIndex }
            else if hovered == section.blockIndex { hovered = nil }
        }
        // The mark is a wash, so it is a colour-only state on its own; the trait
        // is what carries it to VoiceOver (PRODUCT.md: no colour-only state).
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    /// Teal wash for the section being read, the app's ink/white hover wash under
    /// the pointer, nothing at rest. Both are tokens (`No-System-Blue` for the
    /// first, DSN19 for the second, which exists because a white-on-white hover
    /// fill vanishes on the paper canvas).
    private func rowFill(isCurrent: Bool, isHovered: Bool) -> Color {
        if isCurrent { return .mpSelectionWash }
        return isHovered ? .mpOverlayHover : .clear
    }

    // MARK: - Document

    private var document: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        view(for: block)
                            .id(index)
                            .background(headingProbe(at: index))
                    }
                }
                // UX36's shape: the cap sits on the text and the gutter outside
                // it, so the constant is the real measure. `contentPadding` is
                // the same gutter the summary and the transcript use.
                .frame(maxWidth: SummaryLayout.readingMeasure, alignment: .leading)
                .padding(.horizontal, SummaryLayout.contentPadding)
                .padding(.vertical, MPSpace.s6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .coordinateSpace(name: Self.scrollSpace)
            .onPreferenceChange(GuideHeadingOffsets.self) { offsets in
                updateCurrent(from: offsets)
            }
            .onChange(of: jumpTarget) { _, target in
                guard let target else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: MPMotion.durBase)) {
                    proxy.scrollTo(target, anchor: .top)
                }
                jumpTarget = nil
            }
        }
    }

    /// A zero-cost reporter behind each level-2 heading, and only those: the
    /// guide parses to several hundred blocks and the rail only ever names its
    /// ten-or-so sections, so probing every block would be two orders of
    /// magnitude of geometry for the same answer.
    @ViewBuilder
    private func headingProbe(at index: Int) -> some View {
        if sections.contains(where: { $0.blockIndex == index }) {
            GeometryReader { geo in
                Color.clear.preference(
                    key: GuideHeadingOffsets.self,
                    value: [index: geo.frame(in: .named(Self.scrollSpace)).minY]
                )
            }
        }
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    @ViewBuilder
    private func view(for block: GuideDocument.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(headingFont(level))
                .foregroundStyle(Color(MPColors.fg))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, headingLead(level))
                .padding(.bottom, level == 1 ? MPSpace.s4 : MPSpace.s2)
                .textSelection(.enabled)

        case .paragraph(let text):
            Text(inline(text))
                .font(.body)
                .foregroundStyle(Color(MPColors.fg))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, MPSpace.s3)
                .textSelection(.enabled)

        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: MPSpace.s2) {
                marker(Text("•"))
                Text(inline(text))
                    .foregroundStyle(Color(MPColors.fg))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.body)
            .padding(.bottom, MPSpace.s2)
            .textSelection(.enabled)

        case .numbered(let index, let text):
            HStack(alignment: .firstTextBaseline, spacing: MPSpace.s2) {
                marker(Text("\(index).").monospacedDigit())
                Text(inline(text))
                    .foregroundStyle(Color(MPColors.fg))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.body)
            .padding(.bottom, MPSpace.s2)
            .textSelection(.enabled)

        case .table(let headers, let rows):
            VStack(alignment: .leading, spacing: 0) {
                tableRow(headers, isHeader: true)
                    .background(Color(MPColors.bgSunk))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider().overlay(Color(MPColors.borderFaint))
                    tableRow(row, isHeader: false)
                }
            }
            // Clipped before the stroke, or the header's sunk fill squares off
            // the two corners the border rounds.
            .clipShape(RoundedRectangle(cornerRadius: MPRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: MPRadius.md)
                    .stroke(Color(MPColors.border), lineWidth: 1)
            )
            .padding(.top, MPSpace.s1)
            .padding(.bottom, MPSpace.s4)

        case .rule:
            // What survives `collapsingSectionRules`: a break between two
            // paragraphs, where it is the only separator there is. Faint rather
            // than the full border weight, per the hairlines-not-rules motif.
            Divider()
                .overlay(Color(MPColors.borderFaint))
                .padding(.vertical, MPSpace.s5)
        }
    }

    /// The bullet or the number in a list's gutter. Same glyph, colour, and
    /// 16pt right-aligned gutter as `SummaryRenderedView`, which is the other
    /// place in this app that renders a list of prose.
    private func marker(_ text: Text) -> some View {
        text
            .foregroundStyle(Color(MPColors.fgSubtle))
            .frame(minWidth: 16, alignment: .trailing)
    }

    private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: MPSpace.s3) {
            ForEach(Array(cells.enumerated()), id: \.offset) { position, cell in
                Group {
                    if isHeader {
                        Text(inline(cell))
                            .font(.caption.weight(.semibold))
                            .tracking(MPType.trackingCaps * MPType.textXS)
                            .textCase(.uppercase)
                            .foregroundStyle(Color(MPColors.fgMuted))
                    } else {
                        Text(inline(cell))
                            .font(.callout)
                            .foregroundStyle(Color(MPColors.fg))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The first column of a two-column table is the key or the
                // policy: it wants to stay narrow so the explanation gets
                // the room (the UX43 rule about a greedy info column).
                .layoutPriority(position == 0 && cells.count > 1 ? 0 : 1)
            }
        }
        .padding(.horizontal, MPSpace.s3)
        .padding(.vertical, MPSpace.s2)
        .textSelection(.enabled)
    }

    /// Dynamic Type, sized so the default setting is pixel-identical to the
    /// fixed ramp this used to hardcode: macOS resolves `.title` to 22 like
    /// `MPType.textXL`, `.title2` to 17 like `textLG`, `.title3` to 15 like
    /// `textMD`. DSN3's guard allows exactly this ("or a Dynamic-Type font where
    /// scaling matters"), and on a document it does.
    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:  return .title.weight(.semibold)
        case 2:  return .title2.weight(.semibold)
        default: return .title3.weight(.semibold)
        }
    }

    /// Space above a heading, stepped by level so the hierarchy is legible
    /// without a rule drawing it. Flat `s6` above every level was most of why
    /// the document read as one undifferentiated column: a recipe and a
    /// subsection inside it arrived with identical separation.
    private func headingLead(_ level: Int) -> CGFloat {
        switch level {
        case 1:  return 0
        case 2:  return MPSpace.s8
        default: return MPSpace.s5
        }
    }

    /// Per-block inline parsing (bold, italic, code, real links), the same
    /// treatment `SummaryRenderedView` gives a summary bullet. Links the window
    /// cannot follow were already flattened to their label by the parser, since
    /// one in a window resolves to nothing (DOC11 for `#anchor`s, DOC13 for
    /// every other unresolvable shape).
    private func inline(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }

    private func updateCurrent(from offsets: [Int: CGFloat]) {
        let resolved = GuideDocument.currentSection(offsets: offsets, sections: sections)
        if resolved != current { current = resolved }
    }

    private func load() {
        let markdown = GuideDocument.bundledMarkdown() ?? GuideDocument.missingCopy
        let parsed = GuideDocument.parse(markdown)
        blocks = parsed
        sections = GuideDocument.sections(of: parsed)
        current = sections.first?.blockIndex
    }
}

/// Where each section heading sits relative to the top of the reading viewport,
/// collected from the probes in `GuideView.headingProbe` and answered by
/// `GuideDocument.currentSection`. A dictionary rather than one value per
/// heading so the rail's mark is decided from the whole picture in one pass
/// instead of from whichever probe reported last.
private struct GuideHeadingOffsets: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
