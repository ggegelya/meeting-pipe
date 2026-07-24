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
    /// FEAT10: an evidence chip was clicked; take the reader to that transcript
    /// time. Defaulted to a no-op so surfaces with no transcript behind them (the
    /// digest reader) render the same view without a dead affordance.
    var onCite: ((Double) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: MPSpace.s6) {
            if !summaryBullets.isEmpty {
                section(title: "Summary", systemImage: "doc.text") {
                    bulletList(summaryBullets, numbered: false, section: "summary")
                }
            }
            if !decisions.isEmpty {
                section(title: "Decisions", systemImage: "checkmark.seal") {
                    bulletList(decisions, numbered: true, section: "decisions")
                }
            }
            if !actionRuns.isEmpty {
                section(title: "Action items", systemImage: "checklist") {
                    // A digest can carry a few dozen actions across several groups
                    // (AI10 bounds it; before that it was the library's whole open
                    // set). LazyVStack (inside the enclosing ScrollView) realizes and
                    // markdown-parses only the visible rows, instead of building and
                    // laying out all of them up front, which froze scrolling.
                    LazyVStack(alignment: .leading, spacing: MPSpace.s2) {
                        ForEach(Array(actionRuns.enumerated()), id: \.offset) { _, run in
                            // AI10: a roll-up across meetings names each run's source
                            // (workflow, or the meeting when untagged). A meeting's own
                            // summary has one nameless run, so it renders flat as before.
                            if let group = run.group {
                                Text(group)
                                    .font(.mpTextXS.weight(.semibold))
                                    .tracking(0.08 * 10)
                                    .textCase(.uppercase)
                                    .foregroundStyle(Color(MPColors.fgMuted))
                                    .padding(.top, MPSpace.s2)
                            }
                            ForEach(Array(run.actions.enumerated()), id: \.offset) { _, a in
                                ActionItemRow(action: a, onCite: onCite)
                            }
                        }
                    }
                }
            }
            if !questions.isEmpty {
                section(title: "Open questions", systemImage: "questionmark.bubble") {
                    bulletList(questions, numbered: false, section: "questions")
                }
            }
            if !attendees.isEmpty {
                section(title: "Attendees", systemImage: "person.2") {
                    AttendeeChips(names: attendees)
                }
            }
            // WF7: workflow-defined extra sections, read-only, after the standard
            // ones. No `section:` key, so they never carry chips: FEAT10 anchors
            // only the four standard sections.
            ForEach(Array(extraSections.enumerated()), id: \.offset) { _, sec in
                section(title: sec.name, systemImage: "list.bullet.rectangle") {
                    bulletList(bullets(sec.content), numbered: false, section: nil)
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

    /// One rendered line, carrying the index it had in the *unfiltered* section.
    ///
    /// That index is load-bearing: `summary.evidence` is aligned with the stored
    /// array, and dropping empty entries for display would shift every anchor
    /// after the gap onto the wrong bullet. Display numbering still counts
    /// rendered position, so a dropped empty never leaves a hole in "1. 2. 3.".
    private struct Bullet: Identifiable {
        let id: Int
        let text: String
    }

    private func bullets(_ items: [String]) -> [Bullet] {
        items.enumerated().compactMap { i, t in t.isEmpty ? nil : Bullet(id: i, text: t) }
    }

    private var summaryBullets: [Bullet] { bullets(summary.summary) }
    private var decisions: [Bullet]      { bullets(summary.decisions) }
    private var questions: [Bullet]      { bullets(summary.questions) }
    private var attendees: [String]      { nonEmpty(summary.attendees) }
    /// WF7: sections with a name and at least one non-empty bullet, content trimmed.
    private var extraSections: [MeetingSummary.ExtraSection] {
        summary.extraSections.compactMap { sec in
            let content = nonEmpty(sec.content)
            guard !sec.name.isEmpty, !content.isEmpty else { return nil }
            return MeetingSummary.ExtraSection(name: sec.name, content: content)
        }
    }
    /// The action rows, split into AI10's named runs. A meeting summary yields at
    /// most one run with a nil group, which renders exactly as the flat list did.
    private var actionRuns: [(group: String?, actions: [ActionItemRow.Action])] {
        MeetingSummary.actionRuns(summary.actions).compactMap { run in
            let rows = run.actions
                .map { a in
                    ActionItemRow.Action(
                        task: a.task,
                        owner: a.owner ?? "",
                        due: a.due ?? "",
                        confidence: a.confidence,
                        evidence: a.evidence
                    )
                }
                .filter { !$0.task.isEmpty }
            guard !rows.isEmpty else { return nil }
            let name = run.group?.isEmpty == false ? run.group : nil
            return (group: name, actions: rows)
        }
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
    private func bulletList(_ items: [Bullet], numbered: Bool, section: String?) -> some View {
        VStack(alignment: .leading, spacing: MPSpace.s2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                HStack(alignment: .firstTextBaseline, spacing: MPSpace.s2) {
                    Text(numbered ? "\(idx + 1)." : "•")
                        .foregroundStyle(Color(MPColors.fgSubtle))
                        .font(.callout.monospacedDigit())
                        .frame(minWidth: 16, alignment: .trailing)
                    VStack(alignment: .leading, spacing: MPSpace.s1) {
                        Text(inlineMarkdown(item.text))
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                        // FEAT10: anchors sit on their own line under the point,
                        // the same shape the action rows already use for owner /
                        // due / confidence, rather than interrupting the prose.
                        EvidenceChips(anchors: anchors(section, item.id), onCite: onCite)
                    }
                }
            }
        }
    }

    /// The anchors for one rendered line, or none when the section cannot carry
    /// them (a WF7 extra section) or nothing cited it.
    private func anchors(_ section: String?, _ index: Int) -> [MeetingSummary.Evidence] {
        guard let section else { return [] }
        return summary.evidence(section: section, at: index)
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

/// FEAT10: the quiet `[mm:ss]` chips that take a summary point back to the
/// transcript row it came from.
///
/// Deliberately understated per PRODUCT.md: monospaced digits, muted tint, no
/// sparkle and no "AI" badge. A citation is a fact about the recording, not a
/// feature to advertise. Renders nothing at all when there are no anchors, which
/// is most points on most summaries and every point on the backends that emit
/// none.
struct EvidenceChips: View {
    let anchors: [MeetingSummary.Evidence]
    let onCite: ((Double) -> Void)?

    var body: some View {
        if !anchors.isEmpty, let onCite {
            HStack(spacing: MPSpace.s1) {
                ForEach(Array(anchors.enumerated()), id: \.offset) { _, anchor in
                    chip(anchor, onCite: onCite)
                }
            }
        }
    }

    private func chip(_ anchor: MeetingSummary.Evidence, onCite: @escaping (Double) -> Void) -> some View {
        let stamp = TranscriptDisplay.timestamp(anchor.t)
        return Button {
            onCite(anchor.t)
        } label: {
            Text(stamp)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color(MPColors.fgMuted))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(MPColors.fgMuted).opacity(0.10))
                )
                .contentShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        // The quote is hover detail, never note content (owner call 2026-07-22).
        .help(anchor.quote.isEmpty
              ? "Go to \(stamp) in the transcript"
              : "\u{201C}\(anchor.quote)\u{201D}\nGo to \(stamp) in the transcript")
        // Read as one phrase rather than a bare number, which is meaningless
        // out loud, and keep the chip reachable without a mouse.
        .accessibilityLabel(anchor.quote.isEmpty
                            ? "Source at \(stamp)"
                            : "Source at \(stamp): \(anchor.quote)")
        .accessibilityHint("Opens the transcript at this moment")
        .focusable()
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

private struct ActionItemRow: View {
    struct Action {
        var task: String
        var owner: String
        var due: String
        var confidence: String
        /// FEAT10: this item's verified anchors, rendered alongside the existing
        /// owner / due / confidence chips.
        var evidence: [MeetingSummary.Evidence] = []
    }

    let action: Action
    var onCite: ((Double) -> Void)? = nil

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
            if !chipRow.isEmpty || !action.evidence.isEmpty {
                HStack(spacing: 6) {
                    Spacer().frame(width: 16)
                    ForEach(chipRow, id: \.text) { chip in
                        Self.chip(chip)
                    }
                    // Same row as owner / due / confidence, so an action's
                    // metadata stays one band rather than two.
                    EvidenceChips(anchors: action.evidence, onCite: onCite)
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
