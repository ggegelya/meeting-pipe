import SwiftUI

/// Card geometry for the workflow inspector (UX33), the same shape
/// `SummaryLayout` gives the summary reader: the pane fills its column, the
/// content inside it does not.
enum WorkflowInspectorLayout {
    static let padding: CGFloat = MPSpace.s4

    /// Widest the card grows before it stops growing and centres instead.
    ///
    /// This was 416, derived as `LibraryLayout.detailMinWidth (450) - 2 * padding`
    /// so the card would still carry a side margin at the window's narrowest.
    /// That derivation was sound and answered the wrong question: it sizes the
    /// card for the **narrowest window the app allows** and then freezes it at
    /// every width, so on a 1230pt pane 812pt was background. This task was filed
    /// to kill "a 320pt ribbon in an unbounded pane" and shipped a 416pt ribbon
    /// in an unbounded pane; the spec's own "widen to fill the detail column with
    /// a centered max around 400-480pt" asked for two things that cannot both be
    /// true at that width. Owner picked 720 on 2026-07-29 after a mocked review.
    ///
    /// 720 is a *ceiling*, not a width: the cap sits inside the padding, so at
    /// the 450pt floor the card is still `450 - 2 * padding` and shrinks with the
    /// window exactly as before. It matches the top of the 640-720 reading column
    /// `design/README.md` asks for. The summary's prose measure is 680 rather
    /// than 720 on purpose (see `SummaryLayout.readingMeasure`): a label/value
    /// grid is not prose, so the two numbers differ because the content does.
    static let cardMaxWidth: CGFloat = 720
}

/// Inspector pane for a workflow rail scope. A header (identity, how many
/// meetings it has seen and when the last one was, its context prompt behind a
/// disclosure), the facts that earn a row, the newest meetings as buttons, and a
/// footer that pins Edit outside the scroll.
///
/// Every string it renders is decided by `WorkflowInspectorPresentation`; this
/// is a renderer, the way `FactsView` is over `Facts.swift`. The `Spacer` that
/// used to sit above the Edit button lived inside a `ScrollView`, where a
/// `Spacer` is inert (the scroll view sizes to its content), so a short workflow
/// showed a small card and a large dead region under it. A footer is a footer.
struct WorkflowInspector: View {
    let presentation: WorkflowInspectorPresentation
    let onEdit: () -> Void
    /// UX33: a recent meeting was clicked. The list selection lives on
    /// `LibraryRootView`, so the tap is handed up rather than resolved here.
    let onSelectMeeting: (String) -> Void

    @State private var showsContext = false

    /// The seam behind a recent row: a row hands back its own stem, never an
    /// index into a list the host would have to rebuild. Internal so the
    /// callback contract is unit-testable without driving a click.
    func selectRecent(_ recent: WorkflowInspectorPresentation.Recent) {
        onSelectMeeting(recent.stem)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: MPSpace.s5) {
                    header
                    rows
                    if !presentation.recents.isEmpty {
                        recentSection
                    }
                }
                .frame(maxWidth: WorkflowInspectorLayout.cardMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(WorkflowInspectorLayout.padding)
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(MPColors.bg))
    }

    // MARK: pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: MPSpace.s2) {
            HStack(spacing: MPSpace.s2) {
                if let emoji = presentation.emoji, !emoji.isEmpty {
                    Text(emoji).font(.mpTextMD)
                } else {
                    Circle()
                        .fill(swiftUIColor(forHex: presentation.colorHex))
                        .frame(width: 12, height: 12)
                }
                Text(presentation.name)
                    .font(.mpTextMD.weight(.semibold))
                if presentation.isDefault {
                    Text("Default")
                        .font(.mpTextXS.weight(.semibold))
                        .tracking(0.06 * 10)
                        .textCase(.uppercase)
                        .foregroundStyle(Color(MPColors.fgMuted))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: MPRadius.xs)
                                .stroke(Color(MPColors.borderFaint), lineWidth: 0.5)
                        )
                }
            }
            Text(presentation.activity)
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgMuted))
            if let hint = presentation.contextHint {
                // FEAT11: the absent case used to render nothing at all, so the
                // pane read the same whether the workflow had context or not.
                Text(hint)
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgSubtle))
                    .fixedSize(horizontal: false, vertical: true)
            } else if !presentation.contextPrompt.isEmpty {
                contextDisclosure
            }
        }
    }

    /// The context prompt is prose and sometimes long. It used to be dumped
    /// three lines deep above every fact in the pane, which pushed the answers
    /// down; it is one click away instead.
    private var contextDisclosure: some View {
        DisclosureGroup(isExpanded: $showsContext) {
            Text(presentation.contextPrompt)
                .font(.mpTextSM)
                .foregroundStyle(Color(MPColors.fgMuted))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, MPSpace.s1)
        } label: {
            sectionLabel("Context prompt")
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: MPSpace.s3) {
            ForEach(presentation.rows) { row in
                InspectorRow(row: row)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: MPSpace.s2) {
            sectionLabel("Recent")
            VStack(alignment: .leading, spacing: MPSpace.s1) {
                ForEach(presentation.recents) { recent in
                    Button { selectRecent(recent) } label: {
                        HStack(spacing: MPSpace.s2) {
                            Text(recent.title)
                                .font(.mpTextSM)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: MPSpace.s2)
                            Text(recent.dateLabel)
                                .font(.mpTextXS)
                                .foregroundStyle(Color(MPColors.fgMuted))
                                .layoutPriority(1)
                        }
                        .padding(.horizontal, MPSpace.s2)
                        .padding(.vertical, MPSpace.s1 + 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: MPRadius.xs)
                                .fill(Color.mpOverlayFaint)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: MPRadius.xs))
                    }
                    .buttonStyle(.plain)
                    .help(recent.title)
                    .accessibilityHint("Opens this meeting")
                }
            }
        }
    }

    /// Outside the `ScrollView`, so the one action in the pane sits where it
    /// says it does whether the content is two rows or twenty.
    ///
    /// The footer belongs to the **card**, not to the pane. It used to be a
    /// full-pane `bgRaised` plinth: a filled band running the whole 1230pt to
    /// hold one ~140pt control, three times wider than the card above it, which
    /// is why it read as a different surface rather than as this card's footer
    /// (the owner's words were "something from another world"). Now it is the
    /// card's width, carries a hairline instead of a fill, and puts Edit at the
    /// card's trailing edge, so content-left and action-right bound the card.
    /// `design/README.md` is explicit that resting surfaces get a hairline and no
    /// fill; the capsule and `.mpGhost` were never the problem and are unchanged.
    private var footer: some View {
        Button(action: onEdit) {
            Label("Edit workflow", systemImage: "pencil")
        }
        .buttonStyle(.mpGhost)
        .frame(maxWidth: WorkflowInspectorLayout.cardMaxWidth, alignment: .trailing)
        .frame(maxWidth: .infinity)
        .padding(WorkflowInspectorLayout.padding)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(MPColors.border))
                .frame(height: 1)
                .frame(maxWidth: WorkflowInspectorLayout.cardMaxWidth)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.mpTextXS.weight(.semibold))
            .tracking(0.08 * 10)
            .textCase(.uppercase)
            .foregroundStyle(Color(MPColors.fgMuted))
    }
}

private struct InspectorRow: View {
    let row: WorkflowInspectorPresentation.Row

    /// Width of the label column in the grid form. Sized for the longest label
    /// the presentation can emit ("Retention") at the uppercase tracked size,
    /// with room to spare; the value column takes the rest.
    static let labelWidth: CGFloat = 132

    /// Below this the label column stops earning its keep and the row stacks, so
    /// a narrow detail pane does not squeeze values into two-word ribbons. The
    /// floor is `LibraryLayout.detailMinWidth`, where the card is ~418 wide.
    static let gridFloor: CGFloat = 520

    var body: some View {
        // A stacked eyebrow-over-value column is what made widening the card
        // pointless on its own: extra width bought whitespace, not information.
        // As a label/value grid the width is used, which is the difference
        // between a card that fills its column and a ribbon that merely sits in
        // a wider one (UX33, second pass).
        ViewThatFits(in: .horizontal) {
            grid
            stacked
        }
    }

    private var grid: some View {
        HStack(alignment: .firstTextBaseline, spacing: MPSpace.s4) {
            label
                .frame(width: InspectorRow.labelWidth, alignment: .leading)
            value
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: InspectorRow.gridFloor, alignment: .leading)
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 3) {
            label
            value
        }
    }

    private var label: some View {
        Text(row.label)
            .font(.mpTextXS.weight(.semibold))
            .tracking(0.08 * 10)
            .textCase(.uppercase)
            .foregroundStyle(Color(MPColors.fgMuted))
    }

    private var value: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.value)
                .font(.mpTextSM)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = row.detail {
                Text(detail)
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgSubtle))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private func swiftUIColor(forHex hex: String) -> Color {
    if let ns = HexColor.parse(hex) { return Color(ns) }
    return Color.secondary
}
