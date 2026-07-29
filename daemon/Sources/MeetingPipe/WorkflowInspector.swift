import SwiftUI

/// Card geometry for the workflow inspector (UX33), the same shape
/// `SummaryLayout` gives the summary reader: the pane fills its column, the
/// content inside it does not.
enum WorkflowInspectorLayout {
    static let padding: CGFloat = MPSpace.s4

    /// Widest the card grows before it stops growing and centres instead.
    ///
    /// Derived rather than picked: the detail column's floor is
    /// `LibraryLayout.detailMinWidth` (450), so a card wider than
    /// `450 - 2 * padding` = 418 has no side margin left at the window minimum
    /// and reads as a full-bleed pane rather than a card at exactly the size the
    /// window is most cramped. 416 is that number on the 4pt grid, and it sits
    /// inside the 400-480 the task asked for. `WorkflowInspectorTests` pins the
    /// relation, so raising the column floor cannot silently widen the card.
    ///
    /// The visual half is still an eyeball: this fixes the *ceiling*, not
    /// whether 416 reads well on a 1600pt-wide window.
    static let cardMeasure: CGFloat = 416
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
                .frame(maxWidth: WorkflowInspectorLayout.cardMeasure, alignment: .leading)
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
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: onEdit) {
                Label("Edit workflow", systemImage: "pencil")
            }
            .buttonStyle(.mpGhost)
            .frame(maxWidth: WorkflowInspectorLayout.cardMeasure, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(WorkflowInspectorLayout.padding)
        }
        .background(Color(MPColors.bgRaised))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.label)
                .font(.mpTextXS.weight(.semibold))
                .tracking(0.08 * 10)
                .textCase(.uppercase)
                .foregroundStyle(Color(MPColors.fgMuted))
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
