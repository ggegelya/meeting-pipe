import SwiftUI

/// DV1: the cross-meeting facts projection. A read-only aggregate of open
/// actions (with AI1's resolved flag + aging) and recent decisions across the
/// whole library, each row linking back to its source meeting, plus a mark-done
/// control that writes the resolved flag straight into `<stem>.summary.json` (so
/// it round-trips through a later republish as AI1's upsert). A derived index
/// over files, not a database of record (ADR 0003): every fact is loaded from
/// the summary sidecars the pipeline already wrote. Rendered in the Library's
/// center column when the `.facts` rail scope is active.
struct FactsView: View {
    @ObservedObject var store: MeetingStore
    /// Navigate to a fact's source meeting (set by the host: All Meetings + selected row).
    let onOpenMeeting: (String) -> Void

    @State private var openActions: [OpenActionFact] = []
    @State private var decisions: [DecisionFact] = []
    @State private var loading = true

    init(store: MeetingStore, onOpenMeeting: @escaping (String) -> Void) {
        self.store = store
        self.onOpenMeeting = onOpenMeeting
    }

    var body: some View {
        let now = Date()
        Group {
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if openActions.isEmpty && decisions.isEmpty {
                emptyState
            } else {
                List {
                    if !openActions.isEmpty {
                        Section {
                            ForEach(openActions) { fact in
                                OpenActionRow(
                                    fact: fact,
                                    now: now,
                                    onDone: { markDone(fact) },
                                    onOpen: { onOpenMeeting(fact.stem) }
                                )
                            }
                        } header: { sectionHeader("Open actions", openActions.count) }
                    }
                    if !decisions.isEmpty {
                        Section {
                            ForEach(decisions) { fact in
                                DecisionRow(fact: fact, onOpen: { onOpenMeeting(fact.stem) })
                            }
                        } header: { sectionHeader("Recent decisions", decisions.count) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear(perform: reaggregate)
        .onChange(of: store.revision) { _, _ in reaggregate() }
    }

    private func sectionHeader(_ title: String, _ count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(count.formatted(.number))
                .monospacedDigit()
        }
        .font(.mpTextXS.weight(.semibold))
        .tracking(0.08 * 10)
        .textCase(.uppercase)
        .foregroundStyle(Color(MPColors.fgMuted))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(Color(MPColors.fgSubtle))
            Text("No open actions or recent decisions.")
                .foregroundStyle(Color(MPColors.fgMuted))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Aggregation

    /// Reload every summary off-main and rebuild the two fact lists. Triggered on
    /// appear and on each `MeetingStore.revision` bump (a mark-done write lands here).
    private func reaggregate() {
        let meetings = store.meetings        // value snapshot
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())
        Task.detached(priority: .userInitiated) {
            var actions: [OpenActionFact] = []
            var decisions: [DecisionFact] = []
            for m in meetings where m.hasSummaryJSON {
                let url = m.recordingsDir.appendingPathComponent("\(m.stem).summary.json")
                guard let summary = MeetingSummary.load(from: url) else { continue }
                for (i, a) in summary.actions.enumerated() where !a.resolved {
                    let task = a.task.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !task.isEmpty else { continue }
                    actions.append(OpenActionFact(
                        stem: m.stem, summaryURL: url, meetingTitle: m.displayTitle,
                        meetingDate: m.startedAt, actionIndex: i,
                        task: task, owner: a.owner, due: a.due
                    ))
                }
                // Decisions are undated, so "recent" is by the meeting's date.
                if let cutoff, m.startedAt >= cutoff {
                    for (i, d) in summary.decisions.enumerated() {
                        let text = d.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        decisions.append(DecisionFact(
                            stem: m.stem, decisionIndex: i, meetingTitle: m.displayTitle,
                            meetingDate: m.startedAt, text: text
                        ))
                    }
                }
            }
            // Dated open actions first (soonest/most-overdue at the top), undated last.
            actions.sort { lhs, rhs in
                switch (lhs.dueDate, rhs.dueDate) {
                case let (l?, r?): return l < r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return lhs.meetingDate > rhs.meetingDate
                }
            }
            decisions.sort { $0.meetingDate > $1.meetingDate }
            let a = actions, d = decisions
            await MainActor.run {
                self.openActions = a
                self.decisions = d
                self.loading = false
            }
        }
    }

    // MARK: - Mark done

    /// Flip `resolved` on one action in its `<stem>.summary.json`. Optimistic: the
    /// row leaves the list now; the atomic write + the watcher's revision bump
    /// confirm it. Reuses `MeetingSummary.jsonObject()` (the SummaryTab edit path),
    /// no correction record (this is a state flip, not a text correction).
    private func markDone(_ fact: OpenActionFact) {
        openActions.removeAll { $0.id == fact.id }
        Task.detached(priority: .userInitiated) {
            guard var summary = MeetingSummary.load(from: fact.summaryURL) else { return }
            // Prefer the captured index; fall back to a task-text match if the
            // summary changed since aggregation, so we never resolve the wrong row.
            let idx: Int?
            if fact.actionIndex < summary.actions.count,
               summary.actions[fact.actionIndex].task == fact.task {
                idx = fact.actionIndex
            } else {
                idx = summary.actions.firstIndex { $0.task == fact.task && !$0.resolved }
            }
            guard let i = idx else { return }
            summary.actions[i].resolved = true
            let dict = summary.jsonObject()
            guard JSONSerialization.isValidJSONObject(dict),
                  let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
            try? data.write(to: fact.summaryURL, options: .atomic)
            await MainActor.run {
                Log.event(category: "library", action: "action_resolved", attributes: ["stem": fact.stem])
            }
        }
    }
}

// MARK: - Fact models

private struct OpenActionFact: Identifiable {
    let stem: String
    let summaryURL: URL
    let meetingTitle: String
    let meetingDate: Date
    let actionIndex: Int
    let task: String
    let owner: String?
    let due: String?

    var id: String { "\(stem)#a\(actionIndex)" }
    var dueDate: Date? { FactsDate.day(from: due) }

    /// Day-granular aging off the ISO `due` date. `overdue` is the attention cue
    /// (overdue or due today); future dates read quiet.
    func agingLabel(now: Date) -> (text: String, overdue: Bool)? {
        guard let due = dueDate else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: due)).day ?? 0
        if days < 0 { return ("\(-days)d overdue", true) }
        if days == 0 { return ("due today", true) }
        return ("in \(days)d", false)
    }
}

private struct DecisionFact: Identifiable {
    let stem: String
    let decisionIndex: Int
    let meetingTitle: String
    let meetingDate: Date
    let text: String

    var id: String { "\(stem)#d\(decisionIndex)" }
}

// MARK: - Rows

private struct OpenActionRow: View {
    let fact: OpenActionFact
    let now: Date
    let onDone: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: onDone) {
                Image(systemName: "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(MPColors.fgSubtle))
            }
            .buttonStyle(.plain)
            .help("Mark done")
            .accessibilityLabel("Mark action done")

            VStack(alignment: .leading, spacing: 2) {
                Text(fact.task)
                    .foregroundStyle(Color(MPColors.fg))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let owner = fact.owner, !owner.isEmpty {
                        Text(owner)
                    }
                    if let aging = fact.agingLabel(now: now) {
                        if fact.owner?.isEmpty == false { Text("·") }
                        Text(aging.text)
                            .foregroundStyle(aging.overdue ? Color.mpWarning : Color(MPColors.fgSubtle))
                    }
                    Spacer(minLength: 8)
                    meetingLink(fact.meetingTitle, onOpen: onOpen)
                }
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgSubtle))
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DecisionRow: View {
    let fact: DecisionFact
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(fact.text)
                .foregroundStyle(Color(MPColors.fg))
                .fixedSize(horizontal: false, vertical: true)
            meetingLink("\(fact.meetingTitle) · \(FactsDate.short(fact.meetingDate))", onOpen: onOpen)
                .font(.mpTextXS)
        }
        .padding(.vertical, 2)
    }
}

/// Quiet text-button link back to a meeting (signal-teal, no underline chrome).
private func meetingLink(_ label: String, onOpen: @escaping () -> Void) -> some View {
    Button(action: onOpen) {
        Text(label)
            .lineLimit(1)
            .foregroundStyle(Color.mpSignal)
    }
    .buttonStyle(.plain)
    .help("Open meeting")
    .accessibilityLabel("Open meeting \(label)")
}

// MARK: - Date helpers

private enum FactsDate {
    static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    /// Parse the leading `yyyy-MM-dd` of an ISO `due` value (which may carry a time).
    static func day(from s: String?) -> Date? {
        guard let s, s.count >= 10 else { return nil }
        return dayParser.date(from: String(s.prefix(10)))
    }

    static func short(_ date: Date) -> String { shortDate.string(from: date) }
}
