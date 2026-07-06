import AppKit
import SwiftUI

/// TECH-DSN8 / UX13: the shared reading-column measure (~70 characters at the
/// body size). The read view (`SummaryRenderedView`) and the inline editor
/// (`CorrectionEditorBody`) both cap to it, so the summary reads like paper and
/// the edit form lines up with the reader it replaces rather than drifting wider.
enum SummaryLayout {
    static let readingMeasure: CGFloat = 640
}

/// Renders a typed `MeetingSummary` as SwiftUI sections. Inline emphasis/code/links inside bullets use per-bullet `AttributedString` parsing.
struct SummaryRenderedView: View {
    let summary: MeetingSummary

    var body: some View {
        VStack(alignment: .leading, spacing: MPSpace.s6) {
            if !summaryBullets.isEmpty {
                section(title: "Summary", systemImage: "doc.text") {
                    bulletList(summaryBullets, numbered: false)
                }
            }
            if !decisions.isEmpty {
                section(title: "Decisions", systemImage: "checkmark.seal") {
                    bulletList(decisions, numbered: true)
                }
            }
            if !actions.isEmpty {
                section(title: "Action items", systemImage: "checklist") {
                    VStack(alignment: .leading, spacing: MPSpace.s2) {
                        ForEach(Array(actions.enumerated()), id: \.offset) { _, a in
                            ActionItemRow(action: a)
                        }
                    }
                }
            }
            if !questions.isEmpty {
                section(title: "Open questions", systemImage: "questionmark.bubble") {
                    bulletList(questions, numbered: false)
                }
            }
            if !attendees.isEmpty {
                section(title: "Attendees", systemImage: "person.2") {
                    AttendeeChips(names: attendees)
                }
            }
            // TECH-UI-4: the detected-language indicator moved to the detail header caption row.
        }
        .padding(MPSpace.s5)
        .frame(maxWidth: SummaryLayout.readingMeasure, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    // MARK: Field accessors

    private var summaryBullets: [String] { nonEmpty(summary.summary) }
    private var decisions: [String]      { nonEmpty(summary.decisions) }
    private var questions: [String]      { nonEmpty(summary.questions) }
    private var attendees: [String]      { nonEmpty(summary.attendees) }
    private var actions: [ActionItemRow.Action] {
        summary.actions.map { a in
            ActionItemRow.Action(
                task: a.task,
                owner: a.owner ?? "",
                due: a.due ?? "",
                confidence: a.confidence
            )
        }.filter { !$0.task.isEmpty }
    }

    private func nonEmpty(_ items: [String]) -> [String] {
        items.filter { !$0.isEmpty }
    }

    // MARK: Section + bullet helpers

    @ViewBuilder
    private func section<C: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: MPSpace.s3) {
            HStack(spacing: MPSpace.s2) {
                Image(systemName: systemImage)
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .font(.subheadline)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func bulletList(_ items: [String], numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: MPSpace.s2) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .firstTextBaseline, spacing: MPSpace.s2) {
                    Text(numbered ? "\(idx + 1)." : "•")
                        .foregroundStyle(Color(MPColors.fgSubtle))
                        .font(.callout.monospacedDigit())
                        .frame(minWidth: 16, alignment: .trailing)
                    Text(inlineMarkdown(item))
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Parse inline markdown per bullet (bold, italic, code, links only - each bullet is already one paragraph).
    private func inlineMarkdown(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnly,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }
}

private struct ActionItemRow: View {
    struct Action {
        var task: String
        var owner: String
        var due: String
        var confidence: String
    }

    let action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: MPSpace.s1) {
            HStack(alignment: .firstTextBaseline, spacing: MPSpace.s2) {
                Image(systemName: "circle")
                    .foregroundStyle(Color(MPColors.fgSubtle))
                    .font(.caption)
                Text(taskAttributed)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !chipRow.isEmpty {
                HStack(spacing: 6) {
                    Spacer().frame(width: 16)
                    ForEach(chipRow, id: \.text) { chip in
                        Self.chip(chip)
                    }
                }
            }
        }
        .padding(.vertical, MPSpace.s1)
    }

    private var taskAttributed: AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnly,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: action.task, options: opts))
            ?? AttributedString(action.task)
    }

    struct Chip: Hashable {
        let text: String
        let systemImage: String?
        let tint: Color
    }

    private var chipRow: [Chip] {
        var chips: [Chip] = []
        if !action.owner.isEmpty {
            chips.append(Chip(text: action.owner, systemImage: "person", tint: .mpSignal))
        }
        if !action.due.isEmpty {
            chips.append(Chip(text: action.due, systemImage: "calendar", tint: .mpWarning))
        }
        if !action.confidence.isEmpty, action.confidence != "medium" {
            chips.append(Chip(
                text: action.confidence,
                systemImage: "gauge",
                tint: action.confidence == "high" ? .mpSuccess : .secondary
            ))
        }
        return chips
    }

    @ViewBuilder
    static func chip(_ chip: Chip) -> some View {
        HStack(spacing: 3) {
            if let img = chip.systemImage {
                Image(systemName: img).font(.caption2)
            }
            Text(chip.text).font(.caption2)
        }
        .foregroundStyle(chip.tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(chip.tint.opacity(0.12))
        )
    }
}

private struct AttendeeChips: View {
    let names: [String]

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(names, id: \.self) { name in
                HStack(spacing: 4) {
                    Image(systemName: "person.fill")
                        .font(.caption2)
                        .foregroundStyle(Color(MPColors.fgMuted))
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .mpSurface(radius: 6) // DSN19: was controlBackgroundColor.opacity(0.6) + secondary stroke
            }
        }
    }
}
