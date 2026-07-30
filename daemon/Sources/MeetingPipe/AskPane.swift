import Foundation

/// Everything the Ask pane shows, decided from `AskModel` plus two cheap facts
/// about the library (UX38).
///
/// Pure, and on its own type, for the reason `daemon/CLAUDE.md` gives for
/// `StatusBarModel`, `LibraryProcessing`, and `WorkflowInspectorPresentation`:
/// "this is only presentation" is a reason to extract, not a reason to skip.
/// The pane the redesign replaced derived everything inline, so the one thing
/// worth pinning (which state the pane is in, and what it says while a run is
/// going) was unreachable from a test.
///
/// The shape it encodes is the owner's, with one amendment recorded in the task:
/// an empty Ask is a centered invitation, and the first question **docks** the
/// input to the top rather than shrinking it into a corner, because a corner
/// hides the surface's primary affordance and the centre-then-top move is the
/// one Spotlight-family muscle memory already has.
struct AskPane: Equatable {

    /// Where the input sits. Docked the moment there is anything to show under
    /// it, which is a run in flight or a session history, so leaving the rail
    /// and coming back finds the same docked pane rather than a centred
    /// invitation over a list (UX37 keeps that history alive).
    enum Layout: Equatable {
        case centered
        case docked
    }

    /// What the pane says while a question is running.
    ///
    /// `indexing` is AI11's heartbeat rather than an invented number: the
    /// pipeline reports how many meetings the embedding index covers so far, so
    /// a first build over a large library reads as progress instead of a
    /// spinner that looks stuck. Everything else is the honest thinking state.
    enum Running: Equatable {
        case thinking
        case indexing(done: Int, total: Int)

        var line: String {
            switch self {
            case .thinking:
                return "Reading your meetings\u{2026}"
            case .indexing(let done, let total):
                return "Updating the index, \(done) of \(total) meetings\u{2026}"
            }
        }
    }

    /// One suggested question. The text is the identity: the pane never shows
    /// the same suggestion twice, so there is nothing else to key on.
    struct Suggestion: Equatable, Identifiable {
        let text: String
        var id: String { text }
    }

    /// How many suggestions the invitation offers. Three is the ceiling the
    /// task named; fewer when the library cannot honestly fill them.
    static let suggestionLimit = 3

    /// A meeting title longer than this is clipped inside a suggestion, which
    /// is a one-line chip and not a place to read a sentence.
    static let suggestionTitleLimit = 42

    let layout: Layout

    /// The invitation's two lines, both nil once docked.
    let headline: String?
    let subhead: String?

    /// Placeholder for the input field, which differs by state on purpose: the
    /// centred field is the whole invitation and carries the example, while the
    /// docked one only has to say that asking again is right here.
    let fieldPlaceholder: String

    let suggestions: [Suggestion]

    /// Non-nil exactly while a question is running.
    let running: Running?

    /// The session's questions, newest first, straight off the model.
    let entries: [AskEntry]

    /// Why the input is inert, nil when it is live. UX37 **refuses** a second
    /// ask while one runs rather than queueing or swapping it, and a refusal
    /// that changes nothing on screen is indistinguishable from a broken
    /// button, so the pane says the rule and names the way out before the user
    /// can trip over it.
    let inputNote: String?

    var isDocked: Bool { layout == .docked }
    var isRunning: Bool { running != nil }

    // MARK: - Derivation

    /// - Parameters:
    ///   - inFlight: the run the model has going, nil when idle.
    ///   - history: the model's session history, newest first.
    ///   - recentWorkflow: the newest meeting's workflow name, nil when the
    ///     newest meetings are untagged.
    ///   - recentTitle: the newest meeting's display title, nil when the
    ///     library is empty.
    ///   - meetingCount: how many meetings the library holds. Zero is the one
    ///     case where suggestions are withheld: a question the corpus cannot
    ///     answer is a worse invitation than none.
    static func derive(
        inFlight: AskInFlight?,
        history: [AskEntry],
        recentWorkflow: String? = nil,
        recentTitle: String? = nil,
        meetingCount: Int = 0
    ) -> AskPane {
        let docked = inFlight != nil || !history.isEmpty
        return AskPane(
            layout: docked ? .docked : .centered,
            headline: docked ? nil : "Ask about your meetings.",
            subhead: docked ? nil : (meetingCount == 0
                                     ? "No meetings recorded yet."
                                     : "Answers cite the meetings they came from."),
            fieldPlaceholder: docked
                ? "Ask another question\u{2026}"
                : "What did we decide about\u{2026}?",
            suggestions: docked ? [] : suggestions(
                recentWorkflow: recentWorkflow,
                recentTitle: recentTitle,
                meetingCount: meetingCount
            ),
            running: inFlight.map(running),
            entries: history,
            inputNote: inFlight == nil
                ? nil
                : "One question at a time. Cancel to ask another."
        )
    }

    /// The running line for one in-flight run. An index beat with no meetings
    /// in it says nothing a user can act on, so it degrades to the thinking
    /// state rather than rendering `0 of 0`, and a `done` past `total` is
    /// clamped: a ratio that reads over 100% would make the honest number look
    /// like a guess.
    private static func running(_ run: AskInFlight) -> Running {
        guard let p = run.indexing, p.total > 0 else { return .thinking }
        return .indexing(done: min(p.done, p.total), total: p.total)
    }

    /// Two of these come off the library and one is always true, so the
    /// invitation is never a wall of placeholders on a fresh install and never
    /// three variations of the same question on a busy one.
    ///
    /// Framing is deliberate: every suggestion asks something answerable from
    /// the transcripts. Cmd+K already owns find-me-a-meeting (UX25), and a
    /// suggestion that reads like a search would blur the two surfaces the
    /// moment a user tried it.
    static func suggestions(
        recentWorkflow: String?,
        recentTitle: String?,
        meetingCount: Int
    ) -> [Suggestion] {
        guard meetingCount > 0 else { return [] }
        var out: [String] = []
        if let workflow = trimmed(recentWorkflow) {
            out.append("What did we decide in \(workflow) recently?")
        }
        if let title = trimmed(recentTitle) {
            out.append("What came out of \(clip(title))?")
        }
        out.append("What are my open action items?")
        return out.prefix(suggestionLimit).map(Suggestion.init(text:))
    }

    private static func trimmed(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// Clip on a word boundary where there is one, so a chip ends on a word
    /// rather than mid-syllable.
    private static func clip(_ s: String) -> String {
        guard s.count > suggestionTitleLimit else { return s }
        let head = String(s.prefix(suggestionTitleLimit))
        let cut = head.lastIndex(of: " ").map { String(head[head.startIndex..<$0]) } ?? head
        return cut + "\u{2026}"
    }
}
