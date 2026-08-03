import Foundation

/// Everything the workflow inspector pane says about one workflow (UX33).
///
/// Pure, and on its own type, for the reason `daemon/CLAUDE.md` gives for
/// `StatusBarModel` and `LibraryProcessing`: "this is only presentation" is a
/// reason to extract, not a reason to skip. The pane it replaced derived its
/// rows inline and four of the six reported defects were derivation bugs rather
/// than layout ones. A permanent "Modes: -" for every workflow with NDA off, a
/// Trigger row printing raw bundle ids and `/regex/` strings, an Output row
/// truncating a Notion database id to eight characters, and nothing anywhere
/// saying how many meetings the workflow has actually seen. None of that was
/// reachable by a test while it lived inside a `View`.
///
/// The host hands in the facts (the workflow, its meetings newest-first, the
/// bundle-id and Notion-database display names it already knows, and the
/// clock); every string the pane renders is decided here.
struct WorkflowInspectorPresentation: Equatable {

    /// One label + value pair in the facts block. `detail` is the quiet second
    /// line: it carries the part that would make the value read like a config
    /// dump if it were inlined (the title rules behind a trigger, what a
    /// retention policy keeps), and is nil far more often than not.
    struct Row: Equatable, Identifiable {
        let label: String
        let value: String
        var detail: String? = nil
        /// Labels are unique within a pane, so the label is the identity.
        var id: String { label }
    }

    /// One clickable recent meeting. Carries the stem because that is what the
    /// selection is keyed by (`Meeting.id`), so the pane hands back an identity
    /// rather than an index into a list the host would have to rebuild.
    struct Recent: Equatable, Identifiable {
        let stem: String
        let title: String
        /// Pre-rendered, so the view holds no clock of its own.
        let dateLabel: String
        var id: String { stem }
    }

    /// The pane shows the newest few, not a second meeting list; the list rail
    /// beside it is where the whole set lives.
    static let recentLimit = 5

    let name: String
    let emoji: String?
    let colorHex: String
    let isDefault: Bool

    /// FEAT11's nudge copy when this workflow summarizes with no team context,
    /// nil when it has one. Mutually exclusive with `contextPrompt` being shown.
    let contextHint: String?
    /// The workflow's own context prompt, empty when it has none. Rendered
    /// behind a disclosure: it is prose, sometimes long, and it is not the
    /// answer to any question the pane is opened to ask.
    let contextPrompt: String

    /// "12 meetings · last one 3 days ago". The two cheap truths the pane was
    /// missing, and the only two: this is an inspector, not an analytics view.
    let activity: String

    let rows: [Row]
    let recents: [Recent]

    /// A row by its label. The pane renders `rows` in order; this is for the
    /// callers and tests that want one specific line.
    func row(_ label: String) -> Row? {
        rows.first { $0.label == label }
    }

    // MARK: - Derivation

    /// - Parameters:
    ///   - meetings: every meeting in this workflow's scope, newest first (the
    ///     order `MeetingStore` already publishes). Capping at `recentLimit`
    ///     happens here rather than at the call site so the cap is testable.
    ///   - sourceNames: bundle id to app display name, the same map the saved
    ///     smart-folder summary reads (`SavedSearchSummary`). An unresolved id
    ///     falls back to the raw bundle id, which is never wrong, only less
    ///     readable.
    ///   - notionNames: Notion database id to its title, from the picker cache
    ///     the workflow editor already populates. An unknown id renders as bare
    ///     "Notion" rather than a truncated id, since eight characters of a
    ///     UUID answer nothing.
    static func make(
        workflow: Workflow,
        meetings: [Meeting],
        sourceNames: [String: String] = [:],
        notionNames: [String: String] = [:],
        now: Date = Date()
    ) -> WorkflowInspectorPresentation {
        var rows: [Row] = [triggerRow(workflow, sourceNames: sourceNames)]
        if let modes = modesRow(workflow) { rows.append(modes) }
        rows.append(outputRow(workflow, notionNames: notionNames))
        rows.append(Row(label: "Backend", value: backendLine(for: workflow)))
        if let audio = audioRow(workflow) { rows.append(audio) }

        return WorkflowInspectorPresentation(
            name: workflow.name,
            emoji: workflow.emoji,
            colorHex: workflow.color,
            isDefault: workflow.isDefault,
            contextHint: WorkflowContextHint.needsContext(workflow)
                ? WorkflowContextHint.listMarkerHelp : nil,
            contextPrompt: workflow.contextPrompt,
            activity: activityLine(meetings: meetings, now: now),
            rows: rows,
            recents: meetings.prefix(recentLimit).map {
                Recent(
                    stem: $0.stem,
                    title: $0.displayTitle,
                    dateLabel: RelativeMeetingDateFormatter.string(from: $0.startedAt, now: now)
                )
            }
        )
    }

    /// UX31's vocabulary, read rather than restated. A workflow that pins
    /// nothing inherits, which is a routing fact rather than an engine, so it
    /// keeps its own line; NDA forces local whatever the pin says, and
    /// `effectiveBackend` is what reports the engine that will actually run.
    static func backendLine(for workflow: Workflow) -> String {
        workflow.effectiveBackend?.engine.qualified ?? "Global default"
    }

    // MARK: - Rows

    /// What makes a meeting land in this workflow, in the words the owner would
    /// use. The app names lead; title rules are the quiet second line, because a
    /// regex is the user's own text and belongs where it can be read without
    /// competing with the answer.
    private static func triggerRow(_ workflow: Workflow, sourceNames: [String: String]) -> Row {
        let rules = workflow.matchingRules
        let apps = orderedUnique(rules.map(\.bundleID).filter { !$0.isEmpty })
            .map { sourceNames[$0] ?? $0 }
        let titles = orderedUnique(rules.map(\.titleRegex).filter { !$0.isEmpty })

        var value: String
        var detail: String?

        if apps.isEmpty && titles.isEmpty {
            if rules.isEmpty {
                if workflow.isDefault {
                    value = "Any meeting no other workflow claims"
                } else {
                    value = "Nothing matches this automatically"
                    detail = "Pick it by hand on the prompt panel when a meeting starts."
                }
            } else {
                // A rule with both fields blank is a real thing to author, and it
                // matches everything; saying "no matching rules" for it would lie.
                value = "Any meeting"
            }
        } else if apps.isEmpty {
            // Every rule leaves the bundle blank, which matches any app.
            value = "Any meeting app"
        } else {
            value = "Matches \(joined(apps, conjunction: "and"))"
        }

        if !titles.isEmpty {
            let quoted = titles.map { "\"\($0)\"" }
            // "must" is only honest when every rule carries a title rule; with a
            // mix, some meetings match on the app alone.
            if rules.allSatisfy({ !$0.titleRegex.isEmpty }) {
                detail = "Title must match \(joined(quoted, conjunction: "or"))"
            } else {
                detail = "Some rules also match the title: \(quoted.joined(separator: ", "))"
            }
        }

        return Row(label: "Trigger", value: value, detail: detail)
    }

    /// Nil when neither behavioural flag is on, which is most workflows. The row
    /// this replaced rendered a permanent "-" for them: a standing row whose
    /// value is a dash is noise that teaches the eye to skip the block.
    private static func modesRow(_ workflow: Workflow) -> Row? {
        var parts: [String] = []
        if workflow.flags.ndaMode {
            parts.append("NDA mode, so nothing leaves this Mac")
        }
        if workflow.flags.redactMutedSpans {
            parts.append("Muted spans are redacted from the notes")
        }
        guard !parts.isEmpty else { return nil }
        return Row(label: "Modes", value: parts.joined(separator: " · "))
    }

    /// Where the summary is published. Reads `effectiveSinks`, so an NDA
    /// workflow reports the local-only destination it will actually use rather
    /// than the sinks its editor still holds.
    private static func outputRow(_ workflow: Workflow, notionNames: [String: String]) -> Row {
        let sinks = workflow.effectiveSinks
        guard !sinks.isEmpty else { return Row(label: "Output", value: "No destination set") }
        let names = sinks.map { sink -> String in
            switch sink {
            case .notion(let id) where !id.isEmpty:
                if let title = notionNames[id], !title.isEmpty { return "Notion · \(title)" }
                return "Notion"
            case .notion:
                return "Notion · default database"
            case .obsidian:
                return "Obsidian"
            case .filesystem:
                return "Local folder"
            case .lan:
                return "LAN share"
            }
        }
        return Row(label: "Output", value: joined(orderedUnique(names), conjunction: "and"))
    }

    /// STOR1's retention policy, which had no surface outside the editor sheet.
    /// Hidden for `keep`, the default and the only one that does nothing: a row
    /// saying the audio stays forever is the "Modes: -" mistake again. Shown for
    /// the two that reach for a file later, because both are standing behaviour
    /// the owner should be able to see without opening the editor.
    private static func audioRow(_ workflow: Workflow) -> Row? {
        let days = max(0, workflow.retention.afterDays)
        let window = "\(days) \(days == 1 ? "day" : "days") after the meeting"
        switch workflow.retention.policy {
        case .keep:
            return nil
        case .compress:
            return Row(
                label: "Audio",
                value: "Compressed \(window)",
                detail: "Lossless, and still playable and re-processable."
            )
        case .drop:
            return Row(
                label: "Audio",
                value: "Deleted \(window)",
                detail: "The transcript and the summary stay."
            )
        }
    }

    // MARK: - Activity

    /// The count and the last date, both off the meeting list the pane is
    /// already handed. `max()` rather than `first` so a caller that hands them
    /// in another order still reports the real last meeting.
    private static func activityLine(meetings: [Meeting], now: Date) -> String {
        guard let last = meetings.map(\.startedAt).max() else { return "No meetings yet" }
        let count = meetings.count
        let elapsed = RelativeMeetingDateFormatter.elapsedString(from: last, now: now)
        return "\(count) \(count == 1 ? "meeting" : "meetings") · last one \(elapsed)"
    }

    // MARK: - Small helpers

    private static func orderedUnique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    /// "a", "a and b", "a, b and c". Sentence-shaped, because these land inside
    /// a sentence rather than in a comma-separated field.
    private static func joined(_ items: [String], conjunction: String) -> String {
        switch items.count {
        case 0:  return ""
        case 1:  return items[0]
        case 2:  return "\(items[0]) \(conjunction) \(items[1])"
        default: return "\(items.dropLast().joined(separator: ", ")) \(conjunction) \(items[items.count - 1])"
        }
    }
}
