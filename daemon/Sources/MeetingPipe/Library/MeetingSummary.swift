import Foundation

/// Typed mirror of the pipeline's summary schema (`pipeline/src/mp/schemas.py`).
/// The Python pydantic model is the source of truth for field names and on-disk
/// shape; this Decodable mirrors it so the Library views read typed fields instead
/// of `[String: Any]` subscripts, where a mistyped section key silently rendered an
/// empty section.
///
/// Decode is deliberately tolerant: a missing or wrong-typed key yields the empty
/// default rather than throwing, so a partial / legacy `<stem>.summary.json` or a
/// hand-pasted BYO summary still renders whatever it has.
///
/// `detectedLanguage` is optional here while the Python schema makes it required with
/// a "en" default. See docs/decisions/0014-typed-summary-model.md: Python stays the
/// source (it always writes the key); Swift tolerates its absence on read.
struct MeetingSummary: Decodable, Equatable {
    var title: String
    var summary: [String]
    var decisions: [String]
    var actions: [ActionItem]
    var questions: [String]
    var attendees: [String]
    var detectedLanguage: String?
    /// WF7: workflow-defined extra sections. Read-only in the editor, but carried
    /// through every read/write so an edit never drops them.
    var extraSections: [ExtraSection]

    struct ExtraSection: Decodable, Equatable {
        var name: String
        var content: [String]

        enum CodingKeys: String, CodingKey { case name, content }

        init(name: String = "", content: [String] = []) {
            self.name = name
            self.content = content
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? c.decode(String.self, forKey: .name)) ?? ""
            content = (try? c.decode([String].self, forKey: .content)) ?? []
        }
    }

    struct ActionItem: Decodable, Equatable {
        var task: String
        var owner: String?
        var due: String?
        var confidence: String
        /// AI1 lifecycle: false (open) until explicitly resolved. Absent on
        /// legacy summaries, so it defaults to open; the older `done` spelling
        /// is also accepted on read (mirrors the pydantic alias in schemas.py).
        var resolved: Bool
        /// AI10: the grouping key of a roll-up that gathers actions from many
        /// meetings (the weekly digest): the source meeting's workflow, or its
        /// title when untagged. Nil on every meeting summary, where all the
        /// actions share one source, so the reader renders those flat as before.
        var group: String?

        enum CodingKeys: String, CodingKey {
            case task, owner, due, confidence, resolved, done, group
        }

        init(task: String, owner: String? = nil, due: String? = nil, confidence: String = "medium",
             resolved: Bool = false, group: String? = nil) {
            self.task = task
            self.owner = owner
            self.due = due
            self.confidence = confidence
            self.resolved = resolved
            self.group = group
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            task = (try? c.decode(String.self, forKey: .task)) ?? ""
            owner = (try? c.decodeIfPresent(String.self, forKey: .owner)) ?? nil
            due = (try? c.decodeIfPresent(String.self, forKey: .due)) ?? nil
            confidence = (try? c.decode(String.self, forKey: .confidence)) ?? "medium"
            let resolvedFlag = (try? c.decodeIfPresent(Bool.self, forKey: .resolved)) ?? nil
            let doneFlag = (try? c.decodeIfPresent(Bool.self, forKey: .done)) ?? nil
            resolved = resolvedFlag ?? doneFlag ?? false
            group = (try? c.decodeIfPresent(String.self, forKey: .group)) ?? nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case title, summary, decisions, actions, questions, attendees
        case detectedLanguage = "detected_language"
        case extraSections = "extra_sections"
    }

    init(
        title: String = "",
        summary: [String] = [],
        decisions: [String] = [],
        actions: [ActionItem] = [],
        questions: [String] = [],
        attendees: [String] = [],
        detectedLanguage: String? = nil,
        extraSections: [ExtraSection] = []
    ) {
        self.title = title
        self.summary = summary
        self.decisions = decisions
        self.actions = actions
        self.questions = questions
        self.attendees = attendees
        self.detectedLanguage = detectedLanguage
        self.extraSections = extraSections
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        summary = (try? c.decode([String].self, forKey: .summary)) ?? []
        decisions = (try? c.decode([String].self, forKey: .decisions)) ?? []
        actions = (try? c.decode([ActionItem].self, forKey: .actions)) ?? []
        questions = (try? c.decode([String].self, forKey: .questions)) ?? []
        attendees = (try? c.decode([String].self, forKey: .attendees)) ?? []
        let lang = (try? c.decodeIfPresent(String.self, forKey: .detectedLanguage)) ?? nil
        detectedLanguage = (lang?.isEmpty == true) ? nil : lang
        extraSections = (try? c.decode([ExtraSection].self, forKey: .extraSections)) ?? []
    }

    // MARK: - Action grouping (AI10)

    /// One run of consecutive actions sharing an `ActionItem.group`.
    struct ActionRun {
        let group: String?
        let actions: [ActionItem]
    }

    /// Consecutive runs of actions sharing a `group`, mirroring
    /// `markdown._action_runs` on the Python side (pinned by the CI3
    /// `summary-md-golden.json` fixture, case `action_groups_ai10`).
    ///
    /// Runs, not buckets: the writer decides the order and a renderer never
    /// reorders it. Untagged actions fold into one nil run, which is every
    /// meeting summary, so an ungrouped list renders exactly as it always did.
    /// The contract is that a writer tags all of its actions or none.
    static func actionRuns(_ actions: [ActionItem]) -> [ActionRun] {
        var runs: [ActionRun] = []
        for a in actions {
            if let last = runs.last, last.group == a.group {
                runs[runs.count - 1] = ActionRun(group: last.group, actions: last.actions + [a])
            } else {
                runs.append(ActionRun(group: a.group, actions: [a]))
            }
        }
        return runs
    }

    // MARK: - Bridges to the disk format

    /// Decode `<stem>.summary.json`. Returns nil only when the file is missing or
    /// unreadable; a present-but-partial file decodes to a tolerant value.
    static func load(from url: URL) -> MeetingSummary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MeetingSummary.self, from: data)
    }

    /// Decode from an already-parsed JSON object (e.g. the `original_summary` /
    /// `corrected_summary` sub-objects inside a correction record).
    init?(jsonObject: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(jsonObject),
              let data = try? JSONSerialization.data(withJSONObject: jsonObject),
              let decoded = try? JSONDecoder().decode(MeetingSummary.self, from: data) else {
            return nil
        }
        self = decoded
    }

    /// Re-serialize to the on-disk dict shape the Python writer produces: snake_case
    /// keys, `owner`/`due` as explicit null when absent, `detected_language` defaulting
    /// to "en". Used by the write paths (summary.json overwrite, correction record) so
    /// they keep the exact JSON shape rather than relying on encoder null behaviour.
    func jsonObject() -> [String: Any] {
        let actionDicts: [[String: Any]] = actions
            .filter { !$0.task.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { a in
                var d: [String: Any] = [
                    "task": a.task,
                    "confidence": a.confidence.isEmpty ? "medium" : a.confidence,
                    "resolved": a.resolved,
                ]
                d["owner"] = (a.owner?.isEmpty == false) ? a.owner! : NSNull()
                d["due"] = (a.due?.isEmpty == false) ? a.due! : NSNull()
                // AI10: explicit null like owner/due, matching what the Python
                // writer emits, so a rewrite never silently drops a digest's
                // grouping nor invents a key shape the reader has not seen.
                d["group"] = (a.group?.isEmpty == false) ? a.group! : NSNull()
                return d
            }
        return [
            "title": title,
            "summary": summary,
            "decisions": decisions,
            "actions": actionDicts,
            "questions": questions,
            "attendees": attendees,
            "detected_language": detectedLanguage ?? "en",
            // WF7: preserve the workflow-defined sections through an edit (the
            // editor renders them read-only but must not drop them on save).
            "extra_sections": extraSections.map { ["name": $0.name, "content": $0.content] },
        ]
    }
}
