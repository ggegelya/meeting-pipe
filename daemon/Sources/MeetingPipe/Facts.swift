import Foundation

/// The Facts projection's data layer (DV1 + AI7), lifted out of `FactsView` so the
/// grouping and aging rules are testable and so the rail badge can read the same
/// numbers the view renders without a second, divergent aggregation.
///
/// A derived index over files, not a database of record (ADR 0003): every fact is
/// loaded from the `<stem>.summary.json` sidecars the pipeline already wrote.

// MARK: - Facts

/// One open action item on one meeting.
struct OpenActionFact: Identifiable, Equatable {
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

    /// AI7: the key `mp actions --cluster` assignments are looked up by. Keyed on
    /// (stem, task) rather than the array index because the Swift and Python
    /// decoders skip a malformed action differently, so their indices can drift;
    /// the task text is what both agree on.
    var clusterKey: String { OpenActionFact.clusterKey(stem: stem, task: task) }

    static func clusterKey(stem: String, task: String) -> String { "\(stem)\u{1}\(task)" }
}

/// One decision on one meeting. Decisions are undated, so "recent" is by meeting date.
struct DecisionFact: Identifiable, Equatable {
    let stem: String
    let decisionIndex: Int
    let meetingTitle: String
    let meetingDate: Date
    let text: String

    var id: String { "\(stem)#d\(decisionIndex)" }
}

/// AI7: one commitment plus the restatements a recurring series made of it.
///
/// Recurring meetings restate the same promise, so without grouping the Facts
/// list accumulates near-duplicates and resolving one leaves its clones open. A
/// cluster renders as a single row and resolves as a single act.
struct ActionCluster: Identifiable, Equatable {
    /// Every instance, newest meeting first. Exactly one for an unrestated action.
    let instances: [OpenActionFact]

    /// The instance the row renders: the most recent restatement, i.e. the wording
    /// the series last used.
    var representative: OpenActionFact { instances[0] }
    var id: String { representative.id }
    var count: Int { instances.count }

    /// The commitment's deadline: the representative's own `due` when it has one,
    /// else the earliest deadline any instance carried. A series that dropped the
    /// date on its latest restatement has not dropped the commitment.
    var due: String? {
        if let due = representative.due, !due.isEmpty { return due }
        return instances.compactMap { d -> String? in
            guard let due = d.due, !due.isEmpty, FactsDate.day(from: due) != nil else { return nil }
            return due
        }.min()
    }

    var dueDate: Date? { FactsDate.day(from: due) }

    /// Day-granular aging off the ISO `due` date (AI1's rule). `overdue` is the
    /// attention cue (past due or due today); future dates read quiet.
    func agingLabel(now: Date) -> (text: String, overdue: Bool)? {
        guard let due = dueDate else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents(
            [.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: due)
        ).day ?? 0
        if days < 0 { return ("\(-days)d overdue", true) }
        if days == 0 { return ("due today", true) }
        return ("in \(days)d", false)
    }

    /// True when this commitment is what the rail badge counts. Deliberately the
    /// same cue the row paints amber (past due OR due today), so the badge and the
    /// amber rows can never disagree. Note this is a wider set than `mp actions
    /// --overdue`, which is strictly past-due.
    func isOverdue(now: Date) -> Bool { agingLabel(now: now)?.overdue == true }
}

/// What the Facts view renders and the rail badge counts, produced by one pass
/// over the library so the two can never drift.
struct FactsSnapshot: Equatable {
    var clusters: [ActionCluster] = []
    var decisions: [DecisionFact] = []
    /// Commitments wanting attention today (AI7's amber rail count). Counts
    /// clusters, not instances: a restated promise is one thing to do.
    var overdueCount: Int = 0
    /// False until the first load completes, so the view can show a spinner
    /// rather than an empty state it has not earned.
    var loaded: Bool = false

    static let empty = FactsSnapshot()
}

// MARK: - Loading

enum FactsLoader {
    /// How far back decisions are gathered. Actions have their own deadlines, so
    /// only the undated decisions need a window.
    static let decisionWindowDays = 30

    /// Read every meeting's summary sidecar and return the open actions and recent
    /// decisions. Blocking disk I/O over the whole library: call it off-main.
    static func load(meetings: [Meeting], now: Date = Date()) -> (actions: [OpenActionFact], decisions: [DecisionFact]) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -decisionWindowDays, to: now)
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
        decisions.sort { $0.meetingDate > $1.meetingDate }
        return (actions, decisions)
    }
}

// MARK: - Clustering

enum ActionClusterBuilder {
    /// Group open actions into commitments using the pipeline's cluster assignment
    /// (`mp actions --cluster`, keyed by `OpenActionFact.clusterKey`).
    ///
    /// An action with no assignment is its own cluster, which is also the whole
    /// behaviour before the first clustering run returns and whenever clustering
    /// is unavailable, so the view degrades to DV1's flat list rather than to an
    /// error. Output order is DV1's: dated commitments first, soonest deadline at
    /// the top, undated last by meeting recency.
    static func group(_ actions: [OpenActionFact], assignments: [String: Int] = [:]) -> [ActionCluster] {
        var buckets: [String: [OpenActionFact]] = [:]
        var order: [String] = []
        for action in actions {
            // Unassigned actions bucket under their own unique id, so they can
            // never collide with a pipeline cluster id.
            let key = assignments[action.clusterKey].map { "c\($0)" } ?? "u\(action.id)"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(action)
        }
        var clusters = order.compactMap { key -> ActionCluster? in
            guard let instances = buckets[key], !instances.isEmpty else { return nil }
            // Newest first, so the representative is the latest restatement. The
            // stem tiebreak keeps the order stable for same-timestamp meetings.
            let sorted = instances.sorted {
                $0.meetingDate == $1.meetingDate ? $0.stem > $1.stem : $0.meetingDate > $1.meetingDate
            }
            return ActionCluster(instances: sorted)
        }
        clusters.sort { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (l?, r?):
                return l == r ? lhs.representative.meetingDate > rhs.representative.meetingDate : l < r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.representative.meetingDate > rhs.representative.meetingDate
            }
        }
        return clusters
    }

    /// Commitments wanting attention now, for the rail badge. Clusters, not
    /// instances: a promise restated five times is one thing that is late.
    static func overdueCount(_ clusters: [ActionCluster], now: Date = Date()) -> Int {
        clusters.reduce(0) { $0 + ($1.isOverdue(now: now) ? 1 : 0) }
    }

    /// Cluster assignments from a `mp actions --cluster` payload, keyed the way
    /// `OpenActionFact.clusterKey` looks them up. Rows the pipeline left unclustered
    /// are dropped, so they fall through to the singleton path.
    static func assignments(from rows: [ActionClusterAssignment]) -> [String: Int] {
        var map: [String: Int] = [:]
        for row in rows {
            guard let cluster = row.cluster else { continue }
            let task = row.task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { continue }
            map[OpenActionFact.clusterKey(stem: row.stem, task: task)] = cluster
        }
        return map
    }
}

// MARK: - Resolving

enum FactsResolver {
    /// Flip `resolved` on every instance of a commitment (AI7's resolve-the-cluster
    /// semantics), writing straight into each meeting's `<stem>.summary.json` so the
    /// state round-trips through a later republish as AI1's upsert.
    ///
    /// Blocking disk I/O: call it off-main. Reuses `MeetingSummary.jsonObject()` (the
    /// SummaryTab edit-write template, atomic); no correction record, because this is
    /// a state flip and not a text correction. Returns how many instances were written,
    /// so the caller can log what the one click actually resolved.
    @discardableResult
    static func resolve(_ cluster: ActionCluster) -> Int {
        // One instance per meeting file at a time, so two instances that happen to
        // live in the same summary both land instead of the second overwriting the first.
        var byFile: [URL: [OpenActionFact]] = [:]
        for instance in cluster.instances { byFile[instance.summaryURL, default: []].append(instance) }
        var written = 0
        for (url, instances) in byFile {
            guard var summary = MeetingSummary.load(from: url) else { continue }
            var touched = false
            for instance in instances {
                // Prefer the captured index; fall back to a task-text match if the
                // summary changed since aggregation, so we never resolve the wrong row.
                let idx: Int?
                if instance.actionIndex < summary.actions.count,
                   summary.actions[instance.actionIndex].task == instance.task {
                    idx = instance.actionIndex
                } else {
                    idx = summary.actions.firstIndex { $0.task == instance.task && !$0.resolved }
                }
                guard let i = idx, !summary.actions[i].resolved else { continue }
                summary.actions[i].resolved = true
                touched = true
                written += 1
            }
            guard touched else { continue }
            let dict = summary.jsonObject()
            guard JSONSerialization.isValidJSONObject(dict),
                  let data = try? JSONSerialization.data(
                      withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]
                  ) else { continue }
            try? data.write(to: url, options: .atomic)
        }
        return written
    }
}

// MARK: - Date helpers

enum FactsDate {
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
