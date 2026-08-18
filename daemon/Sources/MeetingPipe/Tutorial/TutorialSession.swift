import CoreGraphics
import SwiftUI

/// Whoever can bring one of the tutorial's surfaces up (FEAT15).
///
/// A protocol rather than a `Coordinator` reference so the session stays out of
/// the app spine: the tour needs "make this window visible" and nothing else,
/// and `MeetingSessionController` established that a subsystem asks its host
/// rather than reaching for the Coordinator.
///
/// Deliberately not `@MainActor`, matching `AskRunning` and
/// `WindowActivationManager`: everything here is driven from a SwiftUI body or a
/// menu action, both already on main, and isolating the protocol would
/// retroactively isolate the Coordinator that adopts it.
protocol TutorialSurfacePresenter: AnyObject {
    func presentTutorialSurface(_ surface: TutorialSurface)
}

/// The running tutorial (FEAT15).
///
/// One instance for the app, because the tour drives real windows and two tours
/// pointing at the same window at once is not a state worth modelling. The
/// interesting logic is not here: progression is `TutorialRun`, the window moves
/// are `TutorialPlan`, and the geometry is `TutorialSpotlight`. What is left is
/// wiring, which is what makes those three testable without a screen.
///
/// Main-thread by contract, like `WindowActivationManager.shared`: every caller
/// is a SwiftUI body or a menu action.
final class TutorialSession: ObservableObject {
    static let shared = TutorialSession()

    /// Nil when no tour is running. Published, so a stage that is not in the
    /// current step's surface tears its overlay down on its own.
    @Published private(set) var run: TutorialRun?

    /// Anchor frames, per window, as reported by that window's stage. Keyed by
    /// window rather than by surface because a stage is a hosted root: the two
    /// Preferences panes share one, and which of them is selected shows up here
    /// as which anchors reported at all.
    @Published private(set) var frames: [TutorialWindow: [TutorialAnchor: CGRect]] = [:]

    /// Set by the app once its windows exist. Weak: the presenter owns the
    /// windows and outlives nothing here.
    weak var presenter: TutorialSurfacePresenter?

    /// The surface currently believed to be on screen, which is what
    /// `TutorialPlan.entry` compares against. Cleared when a stage disappears,
    /// so closing the Library mid-tour re-opens it rather than leaving the tour
    /// pointing at a window that is gone.
    private var presented: TutorialSurface?

    /// Whether the step now showing found its control. Written by the overlay,
    /// read on the way out of the step, so a control that never resolved is
    /// reported once with the reader's own timing rather than on the first frame
    /// (where a not-yet-laid-out anchor looks identical to a deleted one).
    private var currentFocusIsMissing = false

    init() {}

    var step: TutorialStep? { run?.step }
    var isRunning: Bool { run?.step != nil }

    /// True while `window` holds the control the current step points at. The
    /// stage modifier gates its overlay on this, so exactly one window is dimmed.
    func isStaged(_ window: TutorialWindow) -> Bool {
        step?.surface.window == window
    }

    // MARK: - Running

    func start(steps: [TutorialStep] = TutorialScript.steps) {
        run = TutorialRun(steps: steps)
        currentFocusIsMissing = false
        applyEntry()
    }

    func advance() {
        leaveStep()
        run?.advance()
        applyEntry()
    }

    func rewind() {
        leaveStep()
        run?.rewind()
        applyEntry()
    }

    func dismiss() {
        leaveStep()
        run?.dismiss()
        run = nil
    }

    /// Bring the step's surface up if it is not the one already showing.
    private func applyEntry() {
        guard let step = run?.step else {
            run = nil
            return
        }
        switch TutorialPlan.entry(for: step, presented: presented) {
        case .stay:
            break
        case .open(let surface):
            presenter?.presentTutorialSurface(surface)
            presented = surface
        }
    }

    /// One log line per step that ended without a control under it. Deliberately
    /// not the primary guard: `TutorialFenceTests` is what fails a build over a
    /// control that no longer exists, and this only catches the runtime residue
    /// (a control that exists but was never laid out, a pane the tour did not
    /// select). Worth a line because the reader sees an honest card and would
    /// otherwise have nothing to hand back.
    private func leaveStep() {
        guard currentFocusIsMissing, let anchor = run?.step?.anchor else { return }
        Log.main.error("tutorial: no control found for anchor \(anchor.rawValue, privacy: .public)")
        currentFocusIsMissing = false
    }

    /// Called by the overlay each time it resolves the current step's control.
    func note(focus: TutorialSpotlight.Focus) {
        currentFocusIsMissing = (focus == .missing)
    }

    // MARK: - Surfaces reporting in

    func report(_ reported: [TutorialAnchor: CGRect], on window: TutorialWindow) {
        guard frames[window] != reported else { return }
        frames[window] = reported
    }

    /// A staged window went away. The tour does not end (the reader may be
    /// re-opening it), but the next step must not assume it is still up.
    func windowDisappeared(_ window: TutorialWindow) {
        frames[window] = nil
        if presented?.window == window { presented = nil }
    }
}
