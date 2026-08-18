import Foundation

/// One stop on the tutorial: a control to point at, and what to say about it
/// (FEAT15).
///
/// The step does not carry the control's name. It carries an anchor, and the
/// card reads the name off that, which is what makes a rename one edit instead
/// of a hunt through narration. `TutorialFenceTests` holds the other half of
/// that rule: no `body` here may spell its own anchor's control.
struct TutorialStep: Equatable, Sendable {
    let anchor: TutorialAnchor
    /// The step's own headline, in the app's voice: sentence case, second person.
    let headline: String
    /// One or two sentences on what the control does and when it matters.
    let body: String

    var surface: TutorialSurface { anchor.surface }
}

/// The tour, in order (FEAT15).
///
/// Deliberately short. This is not a tour of everything the app can do, which is
/// what `docs/GUIDE.md` is for and what it does better: a document can be
/// skimmed, searched and read out of order, and it costs nothing to keep. What a
/// tour is better at is the handful of controls a reader would not know to look
/// for, so every step here has to earn its place by being hard to discover from
/// the window itself. Speaker separation is the clearest case: two knobs on a
/// Preferences pane that nobody opens until a transcript is already wrong.
///
/// The order walks the surfaces the way a new user meets them: the Library
/// first, since that is what the menu bar opens, then the Preferences panes,
/// which step four points at before step five opens one.
enum TutorialScript {
    static let steps: [TutorialStep] = [
        TutorialStep(
            anchor: .scopeRail,
            headline: "Where meetings are grouped",
            body: """
                Every capture lands in one list, and the rows beneath it are \
                slices of that same set: commitments pulled out of summaries, \
                the people who spoke, a question box that reads across all of \
                them at once. Picking a row changes what the middle column \
                shows; nothing is filed away somewhere else.
                """
        ),
        TutorialStep(
            anchor: .record,
            headline: "Starting a meeting by hand",
            body: """
                Detection normally starts a capture on its own when a call \
                begins. This is the manual path for the times it does not, or \
                for a conversation that was never a call at all. It becomes a \
                stop button while audio is flowing, and the ⌃⌥M hotkey does the \
                same thing from any app.
                """
        ),
        TutorialStep(
            anchor: .search,
            headline: "Finding a meeting again",
            body: """
                This box reads the summaries and the decisions inside them, not \
                only the titles, so a half-remembered phrase is usually enough. \
                The menus beside it narrow by workflow, app, status or date on \
                top of whatever you typed.
                """
        ),
        TutorialStep(
            anchor: .preferencesGear,
            headline: "Where the rest of the settings live",
            body: """
                Hotkeys, what happens after a recording stops, where files are \
                written, which model summarizes, and which permissions have \
                been granted all sit behind this one control. The next step \
                opens it.
                """
        ),
        TutorialStep(
            anchor: .vocabulary,
            headline: "Teaching it your words",
            body: """
                Names, products and acronyms that transcription keeps getting \
                wrong go in here once, and every later meeting picks them up. \
                Terms can be global or scoped to a single workflow, so a client \
                name never reaches an unrelated summary.
                """
        ),
        TutorialStep(
            anchor: .speakerLabels,
            headline: "When two people share one label",
            body: """
                Voices are separated on device, and these two knobs are the only \
                ones that change how. Reach for them when one person keeps being \
                split in two, or two people keep being merged; a voice that is \
                merely named wrong is fixed in that meeting's transcript instead.
                """
        ),
        TutorialStep(
            anchor: .regulatedMode,
            headline: "Keeping a meeting off the wire",
            body: """
                This clamps summarization to the on-device model, so nothing \
                about that conversation leaves the Mac. It is a switch rather \
                than a promise: the line under it names the backend the clamp \
                actually lands on.
                """
        ),
    ]
}

/// What has to happen to the app's windows before a step can be shown (FEAT15).
///
/// Pure and explicitly fed, in the `GuideDocument.currentSection` /
/// `MicGate.decide` idiom, because the alternative is window bookkeeping buried
/// in a controller where nothing can test it. The controller's whole job then
/// becomes running this list.
enum TutorialPlan {

    /// The window move a step needs before its anchor can be pointed at.
    enum Entry: Equatable, Sendable {
        /// Bring this surface up first; the step's anchor lives in it.
        case open(TutorialSurface)
        /// The previous step was already in this surface. Nothing to move.
        case stay
    }

    /// The one rule: open the step's surface unless it is already the one on
    /// screen.
    ///
    /// Stated against what is *presented* rather than against the previous step,
    /// because the tour runs backwards too. A forward-only walk marks step 5 as
    /// `.stay` (its neighbour is in the same window), which is right on the way
    /// down and wrong on the way back up from step 6, where the reader is
    /// looking at Preferences and step 5 is in the Library. That version left
    /// Back pointing at a window nobody could see.
    static func entry(for step: TutorialStep, presented: TutorialSurface?) -> Entry {
        step.surface == presented ? .stay : .open(step.surface)
    }

    /// One entry per step, walking the tour forwards from nothing on screen.
    ///
    /// Derived from `entry(for:presented:)` rather than restating it, so there
    /// is one rule. Used to reason about the shape of the tour (which windows it
    /// visits, and how often it moves between them); the controller asks the
    /// single-step form, since it knows what is actually up.
    static func entries(for steps: [TutorialStep]) -> [Entry] {
        var presented: TutorialSurface?
        return steps.map { step in
            let entry = entry(for: step, presented: presented)
            presented = step.surface
            return entry
        }
    }

    /// The surfaces the tour visits, in first-visit order. What a caller needs
    /// to know to answer "can this tour actually be run": every one of these has
    /// to be a window the app can open and that carries a `.tutorialStage(_:)`.
    static func surfaces(for steps: [TutorialStep]) -> [TutorialSurface] {
        var seen: [TutorialSurface] = []
        for step in steps where !seen.contains(step.surface) {
            seen.append(step.surface)
        }
        return seen
    }
}

/// Where a reader is in the tour. A value type with no view and no window in it,
/// so every edge (the ends, an empty script, a stale index) is answerable in a
/// test rather than by clicking Next eight times.
struct TutorialRun: Equatable, Sendable {
    let steps: [TutorialStep]
    private(set) var index: Int
    /// True once the reader has finished or dismissed the tour. Terminal: the
    /// session drops the run rather than resurrecting it.
    private(set) var isDone: Bool

    init(steps: [TutorialStep] = TutorialScript.steps) {
        self.steps = steps
        self.index = 0
        self.isDone = steps.isEmpty
    }

    var step: TutorialStep? {
        guard !isDone, steps.indices.contains(index) else { return nil }
        return steps[index]
    }

    var isFirst: Bool { index == 0 }
    var isLast: Bool { index == steps.count - 1 }

    /// "Step 3 of 7", the eyebrow the onboarding window already wears. Built
    /// from the script's own length, so a step added or removed cannot leave a
    /// count that lies.
    var progress: String { "Step \(index + 1) of \(steps.count)" }

    /// Forward, or done if this was the last one.
    mutating func advance() {
        guard !isDone else { return }
        if isLast { isDone = true } else { index += 1 }
    }

    /// Back one step. A no-op on the first, so the button can be disabled rather
    /// than silently doing nothing somewhere else.
    mutating func rewind() {
        guard !isDone, !isFirst else { return }
        index -= 1
    }

    mutating func dismiss() { isDone = true }
}
