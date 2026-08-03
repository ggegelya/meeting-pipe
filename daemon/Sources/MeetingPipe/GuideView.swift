import AppKit
import SwiftUI

/// Renders the parsed `docs/GUIDE.md` (DOC11): a rail of the guide's ten recipe
/// headings on the left, the document on the right at the same reading measure
/// every other reading surface uses. Read-only, no state worth keeping, no
/// network: it is a document in a window.
struct GuideView: View {
    @State private var blocks: [GuideDocument.Block] = []
    @State private var sections: [GuideDocument.Section] = []

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
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    Button {
                        jump(to: section)
                    } label: {
                        Text(section.title)
                            .font(.mpTextSM)
                            .foregroundStyle(Color(MPColors.fgMuted))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, MPSpace.s1)
                            .padding(.horizontal, MPSpace.s2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, MPSpace.s3)
            .padding(.horizontal, MPSpace.s2)
        }
        .frame(width: 208)
        .background(Color(MPColors.bgSunk))
    }

    /// The rail's jump target. Held here rather than in the rail so the two
    /// columns share one reader.
    @State private var jumpTarget: Int?

    private func jump(to section: GuideDocument.Section) {
        jumpTarget = section.blockIndex
    }

    // MARK: - Document

    private var document: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        view(for: block).id(index)
                    }
                }
                .frame(maxWidth: SummaryLayout.readingMeasure, alignment: .leading)
                .padding(.horizontal, MPSpace.s6)
                .padding(.vertical, MPSpace.s6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: jumpTarget) { _, target in
                guard let target else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    proxy.scrollTo(target, anchor: .top)
                }
                jumpTarget = nil
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
                .padding(.top, level == 1 ? 0 : MPSpace.s6)
                .padding(.bottom, MPSpace.s2)
                .textSelection(.enabled)

        case .paragraph(let text):
            Text(inline(text))
                .font(.mpTextBase)
                .foregroundStyle(Color(MPColors.fgMuted))
                .lineSpacing(4)
                .padding(.bottom, MPSpace.s3)
                .textSelection(.enabled)

        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: MPSpace.s2) {
                Text("·").foregroundStyle(Color(MPColors.fgSubtle))
                Text(inline(text))
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.mpTextBase)
            .padding(.bottom, MPSpace.s2)
            .textSelection(.enabled)

        case .numbered(let index, let text):
            HStack(alignment: .firstTextBaseline, spacing: MPSpace.s2) {
                Text("\(index).")
                    .foregroundStyle(Color(MPColors.fgSubtle))
                    .monospacedDigit()
                Text(inline(text))
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.mpTextBase)
            .padding(.bottom, MPSpace.s2)
            .textSelection(.enabled)

        case .table(let headers, let rows):
            VStack(alignment: .leading, spacing: 0) {
                tableRow(headers, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider().overlay(Color(MPColors.borderFaint))
                    tableRow(row, isHeader: false)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: MPRadius.md)
                    .stroke(Color(MPColors.border), lineWidth: 1)
            )
            .padding(.bottom, MPSpace.s4)

        case .rule:
            Divider()
                .overlay(Color(MPColors.border))
                .padding(.vertical, MPSpace.s4)
        }
    }

    private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: MPSpace.s3) {
            ForEach(Array(cells.enumerated()), id: \.offset) { position, cell in
                Text(inline(cell))
                    .font(.mpTextSM)
                    .foregroundStyle(Color(isHeader ? MPColors.fg : MPColors.fgMuted))
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

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:  return .mpTextXL.weight(.semibold)
        case 2:  return .mpTextLG.weight(.semibold)
        default: return .mpTextMD.weight(.semibold)
        }
    }

    /// Per-block inline parsing (bold, italic, code, real links), the same
    /// treatment `SummaryRenderedView` gives a summary bullet. Same-document
    /// anchors were already flattened to their label by the parser, since one in
    /// a window resolves to nothing.
    private func inline(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }

    private func load() {
        let markdown = GuideDocument.bundledMarkdown() ?? GuideDocument.missingCopy
        let parsed = GuideDocument.parse(markdown)
        blocks = parsed
        sections = GuideDocument.sections(of: parsed)
    }
}
