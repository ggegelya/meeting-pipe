import AppKit
import SwiftUI

/// TECH-DSN8 / UX13: the shared reading-column measure (~70 characters at the
/// body size). The read view (`SummaryRenderedView`) and the inline editor
/// (`CorrectionEditorBody`) both cap to it, so the summary reads like paper and
/// the edit form lines up with the reader it replaces rather than drifting wider.
enum SummaryLayout {
    /// The text column itself, glyph edge to glyph edge. UX36 moved the gutter
    /// *outside* this cap, so the number is now the measure a typographer would
    /// name. It used to sit inside, which quietly made the real column
    /// 640 - 2 * 20 = 600pt: narrower than the 640-720 reading column
    /// `design/README.md` asks for, and the width the owner read as "cut off".
    ///
    /// Moved 640 to 680 on 2026-07-29, the nudge this task's spec pre-registered
    /// and reserved for the owner's eye. It sits inside the 640-720 reading
    /// column `design/README.md` asks for, and the extra 40pt lets the action
    /// metadata band (owner, due, confidence, anchors) hold one line more often
    /// before `ViewThatFits` drops it to two. Not taken further: at the body size
    /// 720 puts a prose line near 100 characters, past where the eye reliably
    /// finds the start of the next one, which is the whole reason a measure
    /// exists. The inspector's card is 720 because a label/value grid is not
    /// prose; matching the two numbers would be a consistency that isn't real.
    static let readingMeasure: CGFloat = 680

    /// The gutter between the reading column and the pane edge. Applied outside
    /// `readingMeasure`, so a surface's whole block is measure + 2 * this.
    static let contentPadding: CGFloat = MPSpace.s5

    /// The narrower measure for the centered state panels (the failed state's
    /// reason dump and its model-download notice). These were two loose `460`
    /// literals that shadowed the shared constant and would not have tracked any
    /// change to it. Deliberately tighter than `readingMeasure`: this text is
    /// centered rather than left-aligned, and centered prose reads worse long.
    static let noticeMeasure: CGFloat = 460
}

/// Renders a typed `MeetingSummary` as SwiftUI sections. Inline emphasis/code/links inside bullets use per-bullet `AttributedString` parsing.
struct SummaryRenderedView: View {
    let summary: MeetingSummary
    /// FEAT10: an evidence chip was clicked; take the reader to that transcript
    /// time. Defaulted to a no-op so surfaces with no transcript behind them (the
    /// digest reader) render the same view without a dead affordance.
    var onCite: ((Double) -> Void)? = nil
    /// UX26: called with an action's index into `summary.actions` and the state the
    /// click asks for, when the reader sits over a live `<stem>.summary.json` that
    /// can be written back. Nil is the default and keeps the static render: the
    /// digest reader, the A16 candidate / compare panes, and any other surface with
    /// no writable summary behind the rows show the glyph without a control.
    var onToggleAction: ((Int, Bool) -> Void)? = nil

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
                                ActionItemRow(
                                    action: a,
                                    onCite: onCite,
                                    onToggle: onToggleAction.map { toggle in
                                        { resolved in toggle(a.index, resolved) }
                                    }
                                )
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
        // UX36: the cap sits on the text, the gutter outside it, so the constant
        // is the real measure rather than the measure minus two paddings.
        .frame(maxWidth: SummaryLayout.readingMeasure, alignment: .leading)
        .padding(SummaryLayout.contentPadding)
        // Left-aligned, deliberately, and this flipped twice before settling.
        // Parked left under an uncapped detail column (the original shape), every
        // pt past the measure was dead space on the right, so the second pass
        // centered the block; centered, the summary started 200+ pt right of the
        // header and transcript, so the content axis jumped on every tab change,
        // which the owner rejected on sight. The fix that holds is in
        // `LibraryLayout.detailMaxWidth`: the column itself is capped, so the
        // slack goes to the meeting list and left alignment costs nothing. All
        // three readers of this pane (header, transcript, summary) now share one
        // left edge; do not re-center this without also uncapping the column.
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
    ///
    /// Each row carries its index into `summary.actions`, which is what UX26's
    /// toggle writes back through: the runs partition the array in order, so a
    /// cursor over them recovers the original position even though empty-task rows
    /// are dropped from the render. Internal rather than private so a test can pin
    /// that mapping; a row that pointed one place and wrote another would resolve
    /// the wrong commitment.
    var actionRuns: [(group: String?, actions: [ActionItemRow.Action])] {
        var cursor = 0
        return MeetingSummary.actionRuns(summary.actions).compactMap { run in
            let base = cursor
            cursor += run.actions.count
            let rows = run.actions.enumerated()
                .map { offset, a in
                    ActionItemRow.Action(
                        index: base + offset,
                        task: a.task,
                        owner: a.owner ?? "",
                        due: a.due ?? "",
                        confidence: a.confidence,
                        resolved: a.resolved,
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

/// One action item. Internal (not private) so UX26's presentation rules are
/// testable without rasterising the view (the T2 no-snapshots rule).
struct ActionItemRow: View {
    struct Action {
        /// Position in the owning summary's `actions`, which is what a toggle
        /// writes back through. Carried even on the static surfaces so the row
        /// value has one shape everywhere.
        var index: Int
        var task: String
        var owner: String
        var due: String
        var confidence: String
        /// AI1 lifecycle state. UX26 renders it: before that the reader dropped
        /// the flag and showed a finished commitment exactly like an open one.
        var resolved: Bool = false
        /// FEAT10: this item's verified anchors, rendered alongside the existing
        /// owner / due / confidence chips.
        var evidence: [MeetingSummary.Evidence] = []
    }

    let action: Action
    var onCite: ((Double) -> Void)? = nil
    /// UX26: nil renders the glyph as a static mark (no control), which is what
    /// every surface without a writable summary behind it gets.
    var onToggle: ((Bool) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: MPSpace.s1) {
            HStack(alignment: .firstTextBaseline, spacing: MPSpace.s2) {
                if let onToggle {
                    Button { onToggle(!action.resolved) } label: { glyph }
                        .buttonStyle(.plain)
                        .help(action.resolved ? "Reopen" : "Mark done")
                        .accessibilityLabel(toggleLabel)
                } else {
                    glyph
                }
                Text(taskAttributed)
                    .font(.body)
                    .strikethrough(action.resolved)
                    .foregroundStyle(Color(action.resolved ? MPColors.fgMuted : MPColors.fg))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hasMetadataBand {
                metadataBand
                    // A resolved row recedes rather than leaving: the chips stay
                    // readable but stop competing with the open commitments above.
                    .opacity(action.resolved ? 0.7 : 1)
            }
        }
        .padding(.vertical, MPSpace.s1)
    }

    /// Circle when open, filled checkmark when resolved. Same SF Symbol family, so
    /// the two states occupy the same box and the row never shifts on a click.
    /// Filled is the sanctioned "selected in a toggle" case in the design system's
    /// no-filled-icons rule; the tint only dims, so the state never rides on colour
    /// alone (the strikethrough and the glyph shape both carry it).
    var glyphName: String { action.resolved ? "checkmark.circle.fill" : "circle" }

    /// Whether this row got a writable summary behind it.
    var isInteractive: Bool { onToggle != nil }

    private var glyph: some View {
        Image(systemName: glyphName)
            .foregroundStyle(Color(action.resolved ? MPColors.fgMuted : MPColors.fgSubtle))
            .font(.caption)
    }

    /// VoiceOver names the act and the commitment it applies to, since a reader
    /// arriving on the button has no other way to tell the rows apart.
    var toggleLabel: String {
        action.resolved ? "Reopen: \(action.task)" : "Mark done: \(action.task)"
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

    // MARK: The metadata band (UX36)

    /// Indents the band under the task text, past the glyph column (the caption
    /// glyph plus `MPSpace.s2`). Was an inline `Spacer().frame(width: 16)`; a
    /// leading pad states the same thing once for both wrap variants.
    private static let metadataIndent: CGFloat = 16

    /// The anchors this row can actually show. `EvidenceChips` draws nothing
    /// without a jump handler, so a static surface (the digest reader, the A16
    /// compare pane) has none whatever the summary carries, and the band must not
    /// reserve a line, or a whole band, for chips that will not appear.
    var shownEvidence: [MeetingSummary.Evidence] {
        onCite == nil ? [] : action.evidence
    }

    /// Whether this row has a metadata band at all.
    var hasMetadataBand: Bool { !chipRow.isEmpty || !shownEvidence.isEmpty }

    /// Owner / due / confidence plus FEAT10's anchors: one line while the column
    /// is wide enough, wrapped to two when it is not. Before UX36 this was a
    /// single non-wrapping `HStack`, so a long owner name plus a few anchors
    /// squeezed every chip's text at the narrow end of the detail column.
    ///
    /// The pick was `ViewThatFits` over the trailing-truncation policy the spec
    /// also offered. Truncation has to choose something to sacrifice and both
    /// candidates here are bad: the owner is the most load-bearing fact on an
    /// action item (who owes it) and a clipped "Alex Nov..." can name two people,
    /// while the anchors are the row's only route back to the recording. In a pane
    /// that already scrolls vertically a second line costs nothing, so paying
    /// width with height is the cheaper trade. It also converges on the shape the
    /// bullet rows already use, where anchors sit on their own line under the
    /// point rather than interrupting it.
    ///
    /// `MeetingRow` deliberately dropped `ViewThatFits`, but that was a `List`
    /// problem: NSTableView caches row heights, so the branch picked at first
    /// measure outlived the width that picked it. These rows sit in a `LazyVStack`
    /// inside a `ScrollView`, which caches no height and re-measures on a width
    /// change like any other view.
    ///
    /// Both variants read the same `chipRow` / `shownEvidence`, so the wrap cannot
    /// drop content the flat line showed.
    private var metadataBand: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                chipViews
                if !shownEvidence.isEmpty { evidenceView }
            }
            VStack(alignment: .leading, spacing: MPSpace.s1) {
                if !chipRow.isEmpty {
                    HStack(spacing: 6) { chipViews }
                }
                if !shownEvidence.isEmpty { evidenceView }
            }
        }
        .padding(.leading, ActionItemRow.metadataIndent)
    }

    @ViewBuilder
    private var chipViews: some View {
        ForEach(chipRow, id: \.text) { chip in
            Self.chip(chip)
        }
    }

    private var evidenceView: some View {
        EvidenceChips(anchors: shownEvidence, onCite: onCite)
    }

    /// The owner / due / confidence chips, in reading order. Internal rather than
    /// private for the same reason `glyphName` and `toggleLabel` are: it is the
    /// seam a test can pin without rasterising the row (the T2 no-snapshots rule).
    var chipRow: [Chip] {
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
