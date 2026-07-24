import Foundation

/// One labelled correction pair (AI9): the meeting source as detection saw it,
/// mapped to the workflow the user moved that meeting to afterwards.
///
/// Written by `WorkflowCorrectionStore` at WF8 reassignment time. Nothing else
/// produces one: a reassignment is the only place in the product where the user
/// states, in so many words, "this meeting belonged somewhere else".
struct WorkflowCorrection: Codable, Equatable {
    /// The detected app's bundle id. Never empty: a correction that cannot be
    /// keyed to a source can never surface on a prompt, so the store drops it.
    let bundleID: String
    /// `WorkflowRoutingHint.normalizeTitle` of the meeting title at record time.
    /// Empty when the recording had no title, which confines that pair to the
    /// bundle tier.
    let titleKey: String
    let workflowID: UUID
    /// Carried for the event log and for reading the file by hand. Resolution is
    /// always by `workflowID`, so a renamed workflow keeps its history.
    let workflowName: String
    let at: Date
}

/// AI9: the routing hint the detection prompt shows when repeated corrections
/// disagree with what the matching rules pick.
///
/// The pairs already existed in spirit and nowhere in fact. `workflow_reassigned`
/// goes to `events.jsonl`, which rotates and drops its oldest generation, and
/// `MeetingMetaSidecar.reassigned` rewrites the workflow block in place, so the
/// sidecar remembers the corrected side and forgets that a correction happened.
/// A count that silently decreases over time is worse than no count, so the pairs
/// are persisted by `WorkflowCorrectionStore` and read back here.
///
/// **This is a count, not a model.** Two tiers of key (bundle + normalized title
/// first, bundle alone as the fallback), a threshold, and a strict-plurality
/// rule. That is the whole thing. A single-user product accumulates corrections
/// at a rate of a handful per quarter, which is several orders of magnitude below
/// what any classifier needs, and the AI5 spike already measured what happens
/// when a labeller is asked to be cleverer than its evidence.
enum WorkflowRoutingHint {

    /// Corrections needed on one key before the prompt says anything. Three, so a
    /// single misclick plus one real correction stays silent and a deliberate
    /// pattern speaks up on the next meeting. Not a config knob: it is one line to
    /// change, the owner has no way to calibrate it without data, and CI5's
    /// dead-knob fence exists because this repo has shipped settings nothing read.
    static let minimumCorrections = 3

    /// Cap on a stored title key. A window title is attacker-free here (it is the
    /// user's own meeting), but an unbounded key in an append-only file is still
    /// worth bounding.
    static let maxTitleKeyLength = 120

    /// What the prompt should say. Nil from `suggest` means "say nothing", which
    /// is the normal case and stays the normal case until real corrections pile up.
    struct Suggestion: Equatable {
        let workflowID: UUID
        let workflowName: String
        /// Corrections backing the winning workflow on the tier that fired.
        let corrections: Int
        /// True when the evidence came from the bundle + title key rather than the
        /// bundle alone. Recorded on the event so a later reader can tell a
        /// per-meeting pattern from a whole-app one.
        let matchedOnTitle: Bool
        /// Whether the chip may show this workflow already selected.
        ///
        /// False for the one direction that can do damage: the rules routed this
        /// meeting to an NDA workflow and the suggestion is not one. Pre-selecting
        /// there would hand a meeting the user marked confidential to the cloud
        /// path on a Record click nobody read. The hint still appears, so the
        /// suggestion stays discoverable; it just costs one explicit click.
        /// WF8 draws the same line, confirming NDA transitions with an alert.
        let preselects: Bool
    }

    /// Fold a meeting title into a key two instances of the same recurring meeting
    /// share: lowercased, letters only, single-spaced, length-capped.
    ///
    /// Dropping digits is what makes "Standup 07/23" and "Standup 07/30" one key.
    /// It is deliberately not clever about dates, ordinals, or client suffixes: a
    /// recurring title carrying a word that changes every week simply never
    /// accumulates on this tier, and the bundle tier below picks it up instead.
    /// Degrading to the broader key beats guessing at a title grammar.
    static func normalizeTitle(_ title: String?) -> String {
        guard let title = title else { return "" }
        var out = ""
        var pendingSpace = false
        for ch in title.lowercased() {
            if ch.isLetter {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(ch)
            } else {
                pendingSpace = true
            }
        }
        return String(out.prefix(maxTitleKeyLength))
    }

    /// The workflow to suggest for `source`, or nil to stay quiet.
    ///
    /// Pure: every input is passed in, so the whole rule is table-testable without
    /// a store, a prompt, or a disk.
    ///
    /// Order of business:
    /// 1. No source, or no bundle id, means no key, so nothing to say. (A manual
    ///    recording lands here. It also never raises a prompt, so there is no
    ///    surface for a hint even if there were one to give.)
    /// 2. Try the specific tier (bundle + title key), then the broad tier (bundle
    ///    alone). The specific tier wins outright when it fires.
    /// 3. A tier fires when its top workflow holds at least `minimumCorrections`
    ///    pairs *and* strictly more than the runner-up. The plurality half is what
    ///    keeps three corrections spread across three workflows silent.
    /// 4. A suggestion the rules already make is not a suggestion, and a workflow
    ///    that has since been deleted is not one either.
    static func suggest(
        source: AppSource?,
        matched: Workflow?,
        corrections: [WorkflowCorrection],
        workflows: [Workflow],
        minimumCorrections: Int = WorkflowRoutingHint.minimumCorrections
    ) -> Suggestion? {
        guard minimumCorrections > 0 else { return nil }
        guard let source = source, !source.bundleID.isEmpty else { return nil }

        let sameApp = corrections.filter { $0.bundleID == source.bundleID }
        guard !sameApp.isEmpty else { return nil }

        let titleKey = normalizeTitle(source.meetingTitle)
        // Specific first; a whole-app habit only speaks when this meeting has no
        // habit of its own.
        var tiers: [(pool: [WorkflowCorrection], onTitle: Bool)] = []
        if !titleKey.isEmpty {
            tiers.append((sameApp.filter { $0.titleKey == titleKey }, true))
        }
        tiers.append((sameApp, false))

        for tier in tiers {
            guard let winner = plurality(in: tier.pool, minimum: minimumCorrections) else { continue }
            // The rules already route here: there is nothing to correct, and
            // falling through to the broader tier would suggest moving away from
            // the very workflow the corrections agree on.
            if let matched = matched, matched.id == winner.id { return nil }
            guard let workflow = workflows.first(where: { $0.id == winner.id }) else { continue }
            let downgradesPrivacy = (matched?.flags.ndaMode ?? false) && !workflow.flags.ndaMode
            return Suggestion(
                workflowID: workflow.id,
                workflowName: workflow.name,
                corrections: winner.count,
                matchedOnTitle: tier.onTitle,
                preselects: !downgradesPrivacy
            )
        }
        return nil
    }

    /// The workflow with a strict plurality of `pool` at or above `minimum`, or nil.
    /// Ties break on the uuid string purely so the "no strict winner" rejection is
    /// deterministic rather than dictionary-order dependent.
    private static func plurality(
        in pool: [WorkflowCorrection],
        minimum: Int
    ) -> (id: UUID, count: Int)? {
        guard !pool.isEmpty else { return nil }
        var tally: [UUID: Int] = [:]
        for correction in pool {
            tally[correction.workflowID, default: 0] += 1
        }
        let ranked = tally.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key.uuidString < rhs.key.uuidString
        }
        guard let top = ranked.first, top.value >= minimum else { return nil }
        let runnerUp = ranked.dropFirst().first?.value ?? 0
        guard top.value > runnerUp else { return nil }
        return (top.key, top.value)
    }
}
