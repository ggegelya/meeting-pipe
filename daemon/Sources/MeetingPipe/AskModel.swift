import Foundation

/// UX37: the seam `AskModel` runs a question over. `LibraryWindowModel` conforms
/// (its `askMeetings` already existed, and `cancelAsk` forwards to the launcher's
/// retained ask process); a test substitutes a fake that parks the completion,
/// which is what makes "the view died mid-run" observable at all.
///
/// Main-actor isolated to match `MeetingLibraryService`'s own threading contract
/// (every method on it must run on main). `LibraryWindowModel` conforms in an
/// extension rather than in its declaration, so it keeps its existing isolation
/// instead of inheriting this one.
@MainActor
protocol AskRunning: AnyObject {
    /// Run one `mp ask` across the library and return its parsed answer (AI3).
    func askMeetings(question: String) async -> Result<AskAnswer, Error>
    /// Terminate the in-flight `mp ask` subprocess, if any (UX37).
    func cancelAsk()
}

/// One question asked this session and what came back for it.
struct AskEntry: Identifiable, Equatable {
    /// How the run ended. `cancelled` is a first-class outcome rather than an
    /// error: a stopped ask has to say it was stopped, not render a blank pane
    /// or the "terminated" stderr tail of the process the user themselves killed.
    enum Outcome: Equatable {
        case answered(AskAnswer)
        case failed(String)
        case cancelled
    }

    let id: UUID
    let question: String
    let askedAt: Date
    let outcome: Outcome

    /// The answer, when this entry has one.
    var answer: AskAnswer? {
        if case .answered(let a) = outcome { return a }
        return nil
    }

    /// The failure message, when this entry failed.
    var errorText: String? {
        if case .failed(let message) = outcome { return message }
        return nil
    }

    var wasCancelled: Bool { outcome == .cancelled }
}

/// The run currently in flight (UX37). Carries `startedAt` so a surface can show
/// how long it has been going; AI11's stdout heartbeat lands as another field
/// here when it ships, without moving where the running state lives.
struct AskInFlight: Equatable {
    let id: UUID
    let question: String
    let startedAt: Date
}

/// UX37: the Ask rail's state, owned by the Library root instead of the view.
///
/// Everything a run needs to survive lives here: the question text, the run in
/// flight, and this session's answers. `LibraryRootView` holds it as a
/// `@StateObject` beside `digestList`, so switching the rail to Facts destroys
/// only `AskView`; an `mp ask` that is still running completes into this model,
/// and the answer is there when the view comes back. Before this the whole run
/// was `@State` on the view struct, so a scope switch silently threw the answer
/// away while the subprocess kept burning its 10-minute budget uncancellably.
///
/// The `DigestListModel` precedent, one rail over, with two additions a
/// long-running question needs: a Cancel that reaches the subprocess, and a
/// session history so coming back shows what was already asked.
///
/// `AskView` is a pure renderer over this type and holds no run state of its
/// own. UX38 rewrites that renderer against this same surface.
@MainActor
final class AskModel: ObservableObject {

    /// How many question/answer pairs one session keeps. Bounded because an
    /// entry retains a whole answer (and its citations) and the list is
    /// append-forever otherwise; 20 is far past what a single session asks and
    /// costs a few hundred KB at worst. Durable, unbounded history is UX38's
    /// call, not this task's.
    static let historyLimit = 20

    /// Live text in the input field. Owned here so a scope switch does not blank
    /// a half-typed question.
    @Published var question: String = ""

    /// The run in flight, or nil when idle.
    @Published private(set) var inFlight: AskInFlight?

    /// This session's questions, newest first. In memory only.
    @Published private(set) var history: [AskEntry] = []

    /// True while a question is running.
    var isAsking: Bool { inFlight != nil }

    /// The newest outcome, which is what a renderer shows under the input.
    var latest: AskEntry? { history.first }

    var trimmedQuestion: String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private let runner: AskRunning

    /// Called when the run in flight ends, however it ends. Carries the deeplink
    /// consume (AUTO1), so `pendingAskQuestion` is cleared on completion rather
    /// than on render: a scope switch mid-run must not lose the question that
    /// started it.
    private var onRunFinished: (() -> Void)?

    init(runner: AskRunning) {
        self.runner = runner
    }

    // MARK: - Running

    /// Run whatever is in the input field.
    ///
    /// One at a time: a second ask while one is running is **refused**, not
    /// queued and not swapped in. The running question is the one the user is
    /// waiting on, and silently killing it to start another would throw away
    /// work that may be seconds from landing. Cancel is the explicit way to make
    /// room, and it names what happened.
    @discardableResult
    func ask() -> Bool {
        start(trimmedQuestion)
    }

    /// Fill the field from a suggestion (or any other one-click source) and run
    /// it. Refused while a run is in flight, and refused before the field is
    /// rewritten, so a rejected ask leaves nothing changed behind it.
    @discardableResult
    func ask(_ text: String) -> Bool {
        guard inFlight == nil else { return false }
        question = text
        return start(trimmedQuestion)
    }

    /// AUTO1 + UX37: prefill and run a deeplinked question, clearing the pending
    /// question only when the run it started has finished.
    ///
    /// `onConsumed` is the caller's "forget this deeplink" write. It fires on
    /// completion (or on cancel), never on render, so a mount / unmount / mount
    /// cycle mid-run leaves the question exactly where it was. A remount re-calls
    /// this with the same still-pending question, which is why the in-flight
    /// question is matched first: re-running it would spawn a second subprocess
    /// for a question already being answered.
    func acceptDeeplink(_ pending: String?, onConsumed: @escaping () -> Void) {
        guard let pending else { return }
        let q = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        // Already running (this deeplink, or an earlier question). A different
        // question stays pending rather than being dropped, so the next mount
        // still runs it; refusing here is the same one-at-a-time rule as `ask()`.
        guard inFlight == nil else { return }
        question = q
        start(q, onFinished: onConsumed)
    }

    /// Stop the run in flight and record it as cancelled.
    ///
    /// The model closes the run out immediately rather than waiting for the
    /// subprocess to die: the user asked for it to stop, so the pane says
    /// "cancelled" at once even if the terminate is slow, and the late
    /// completion is dropped as stale by the run-id guard in `finish`.
    func cancel() {
        guard let run = inFlight else { return }
        inFlight = nil
        runner.cancelAsk()
        record(AskEntry(id: run.id, question: run.question, askedAt: run.startedAt, outcome: .cancelled))
        let consume = onRunFinished
        onRunFinished = nil
        consume?()
    }

    // MARK: - Internals

    @discardableResult
    private func start(_ q: String, onFinished: (() -> Void)? = nil) -> Bool {
        guard !q.isEmpty, inFlight == nil else { return false }
        let run = AskInFlight(id: UUID(), question: q, startedAt: Date())
        inFlight = run
        onRunFinished = onFinished
        Task { [weak self] in
            guard let self else { return }
            let result = await self.runner.askMeetings(question: q)
            self.finish(run: run, result: result)
        }
        return true
    }

    /// Land a completion. The run-id guard is what makes an abandoned or
    /// cancelled run harmless: its answer is dropped instead of overwriting
    /// whatever the model has moved on to.
    private func finish(run: AskInFlight, result: Result<AskAnswer, Error>) {
        guard inFlight?.id == run.id else { return }
        inFlight = nil
        record(AskEntry(
            id: run.id,
            question: run.question,
            askedAt: run.startedAt,
            outcome: AskModel.outcome(for: result)
        ))
        let consume = onRunFinished
        onRunFinished = nil
        consume?()
    }

    /// The pipeline reports an engine-level refusal as a `success` carrying a
    /// non-empty `error`, so both shapes have to fold into one failed outcome.
    private static func outcome(for result: Result<AskAnswer, Error>) -> AskEntry.Outcome {
        switch result {
        case .success(let answer):
            if let message = answer.error, !message.isEmpty { return .failed(message) }
            return .answered(answer)
        case .failure(let error):
            return .failed(error.localizedDescription)
        }
    }

    private func record(_ entry: AskEntry) {
        history.insert(entry, at: 0)
        if history.count > AskModel.historyLimit {
            history.removeLast(history.count - AskModel.historyLimit)
        }
    }
}
