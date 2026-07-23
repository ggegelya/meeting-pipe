import Foundation

/// CAL2: the "Last time" prep card. What the previous meeting in this workflow
/// covered, and what it left open, so the context a recurring call needs is on
/// the prompt instead of behind a hunt through the Library.
///
/// A projection over two sidecars that already exist (`<stem>.meta.json` for the
/// workflow a meeting was recorded under, `<stem>.summary.json` for the content),
/// not a new file. `mp prep <workflow>` renders the same card in the shell from
/// the same two files; the two are independent readers of one on-disk shape, the
/// way `FactsView` and `mp actions` already are.
///
/// Deliberately bounded to the last meeting. Carrying every older open action
/// forward is a different feature with a different failure mode (AI10 owns the
/// unbounded-action-list problem); "Last time" means last time.
struct PrepCard: Equatable, Sendable {

    /// One open action, flattened to what the card shows. `MeetingSummary.ActionItem`
    /// carries more (confidence, the resolved flag); a glance card does not.
    struct Action: Equatable, Sendable {
        let task: String
        let owner: String?
        let due: String?
    }

    let workflowName: String
    let stem: String
    let startedAt: Date
    let title: String
    let points: [String]
    let actions: [Action]
    /// Open actions past `maxActions`, so the card can say it is truncating
    /// rather than silently dropping them.
    let moreActions: Int

    /// Small on purpose: this is a glance before a call, not a re-read.
    static let maxPoints = 3
    static let maxActions = 3

    /// Project one summary into a card. Pure.
    ///
    /// Returns nil when there is nothing to say (no points and no open actions),
    /// which is what keeps the affordance quiet: a card with nothing in it is
    /// never offered rather than shown empty.
    ///
    /// Points come from `summary`, falling back to `decisions` when a run put its
    /// content there and left the recap empty (a local model does this often
    /// enough to matter).
    static func make(
        workflowName: String,
        stem: String,
        startedAt: Date,
        summary: MeetingSummary,
        maxPoints: Int = PrepCard.maxPoints,
        maxActions: Int = PrepCard.maxActions
    ) -> PrepCard? {
        var points = clean(summary.summary, limit: maxPoints)
        if points.isEmpty {
            points = clean(summary.decisions, limit: maxPoints)
        }

        let open: [Action] = summary.actions.compactMap { item in
            guard !item.resolved else { return nil }
            let task = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { return nil }
            return Action(
                task: task,
                owner: nonEmpty(item.owner),
                due: nonEmpty(item.due)
            )
        }

        guard !points.isEmpty || !open.isEmpty else { return nil }

        let title = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = Array(open.prefix(maxActions))
        return PrepCard(
            workflowName: workflowName,
            stem: stem,
            startedAt: startedAt,
            title: title.isEmpty ? stem : title,
            points: points,
            actions: shown,
            moreActions: open.count - shown.count
        )
    }

    /// "today" / "yesterday" / "3 days ago" / "5 weeks ago". Day-granular: the
    /// time of day is noise on a card answering "when did we last talk".
    /// `mp.prep.relative_day` mirrors the same buckets in English.
    func relativeDay(now: Date) -> String {
        RelativeMeetingDateFormatter.elapsedString(from: startedAt, now: now)
    }

    private static func clean(_ values: [String], limit: Int) -> [String] {
        var out: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            out.append(trimmed)
            if out.count == limit { break }
        }
        return out
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// The seam the prompt panel sees. Kept narrow so the panel never learns where
/// recordings live; `PrepCardStore` is the only thing that touches the disk.
protocol PrepCardProviding: AnyObject {
    /// Look up the card for `workflow`, or nil when there is nothing to show.
    /// The scan runs off-main; `completion` is called on the main queue, once.
    func prepCard(for workflow: Workflow?, completion: @escaping (PrepCard?) -> Void)
}

/// Disk-backed `PrepCardProviding`: newest-first walk over the recordings
/// directory for the last meeting recorded under a workflow.
///
/// The scan reads `<stem>.meta.json` only for stems that already have a summary,
/// and stops at the first meeting that yields a card, so the usual cost is a
/// directory listing plus one or two small JSON reads. It runs off-main anyway:
/// a workflow with no meetings walks the whole library, and the prompt panel is
/// raised on the main queue at meeting-detection time.
final class PrepCardStore: PrepCardProviding {
    private let recordingsDir: URL

    init(recordingsDir: URL) {
        self.recordingsDir = recordingsDir
    }

    func prepCard(for workflow: Workflow?, completion: @escaping (PrepCard?) -> Void) {
        guard let workflow = workflow else {
            completion(nil)
            return
        }
        let dir = recordingsDir
        let id = workflow.id.uuidString
        let name = workflow.name
        DispatchQueue.global(qos: .userInitiated).async {
            let card = PrepCardStore.scan(recordingsDir: dir, workflowID: id, workflowName: name)
            DispatchQueue.main.async { completion(card) }
        }
    }

    /// Newest summarized meeting recorded under this workflow, projected into a
    /// card. Blocking; call it off the main queue.
    ///
    /// Matching prefers the sidecar's stable `workflow_id` and falls back to
    /// `workflow_name`, so a renamed workflow still finds its own history while a
    /// pre-`workflow_id` sidecar still matches by name. (`mp prep` is name-keyed
    /// because a name is what a shell caller can type.)
    static func scan(recordingsDir: URL, workflowID: String, workflowName: String) -> PrepCard? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: recordingsDir.path) else { return nil }

        // Only stems that already have a summary can produce a card, so the meta
        // reads below are bounded by what the pipeline finished.
        var summarized = Set<String>()
        for name in names where name.hasSuffix(".summary.json") {
            summarized.insert(String(name.dropLast(".summary.json".count)))
        }
        guard !summarized.isEmpty else { return nil }

        // Stems are `YYYYMMDD-HHMMSS`, so lexical descending is newest first.
        for stem in summarized.sorted(by: >) {
            guard let startedAt = MeetingStore.parseStem(stem) else { continue }
            guard let meta = readObject(recordingsDir.appendingPathComponent("\(stem).meta.json"))
            else { continue }
            guard matches(meta: meta, workflowID: workflowID, workflowName: workflowName)
            else { continue }
            guard let summary = MeetingSummary.load(
                from: recordingsDir.appendingPathComponent("\(stem).summary.json")
            ) else { continue }
            if let card = PrepCard.make(
                workflowName: workflowName, stem: stem, startedAt: startedAt, summary: summary
            ) {
                return card
            }
            // A last meeting with an empty summary (no speech, a failed run that
            // still wrote a shell) has nothing to recap; the one before it usually
            // does, so fall through rather than report an empty "last time".
        }
        return nil
    }

    /// Pure: does this meta sidecar belong to the workflow we are asking about?
    static func matches(meta: [String: Any], workflowID: String, workflowName: String) -> Bool {
        if let id = meta["workflow_id"] as? String, !id.isEmpty {
            return id.caseInsensitiveCompare(workflowID) == .orderedSame
        }
        guard let name = meta["workflow_name"] as? String else { return false }
        return name == workflowName
    }

    private static func readObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }
}
