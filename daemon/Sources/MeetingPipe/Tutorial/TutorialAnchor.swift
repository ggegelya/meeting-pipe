import SwiftUI

/// Somewhere the app can be put so a tutorial step's control is on screen
/// (FEAT15).
///
/// The tutorial drives the shipped UI rather than reproducing it, so a surface is
/// a place the app already knows how to open for its own reasons. A Preferences
/// *pane* is its own surface rather than a detail of one, because that is what
/// the app's own deeplinks treat it as (`menuPreferencesPermissions`,
/// `menuPreferencesIntegrations`) and because a control on an unselected pane is
/// exactly as invisible as one in a closed window.
///
/// Adding a case means giving its window a `.tutorialStage(_:)` and teaching
/// `Coordinator.presentTutorialSurface` to open it. `TutorialFenceTests` fails
/// until both exist.
enum TutorialSurface: String, CaseIterable, Sendable {
    case library
    case preferencesPipeline
    case preferencesPermissions

    /// The window a surface belongs to. Two panes of Preferences share a stage,
    /// so the overlay is gated on this rather than on the surface itself.
    var window: TutorialWindow {
        switch self {
        case .library: return .library
        case .preferencesPipeline, .preferencesPermissions: return .preferences
        }
    }
}

/// The windows that carry a `.tutorialStage(_:)`. One per hosted root, which is
/// the granularity a SwiftUI overlay actually has.
enum TutorialWindow: String, CaseIterable, Sendable {
    case library
    case preferences
}

/// A control the tutorial points at, by name, in the running app (FEAT15).
///
/// **This enum is the whole maintenance story, so read this before adding a
/// case.** The task's own framing is that the animation is easy and staying true
/// is not: a step naming a control that has been renamed or deleted is the
/// stale-doc failure DOC7 and DOC9 spent two sweeps cleaning up, except that a
/// tour cannot be grepped the way a sentence can. So the tour never spells a
/// control's name and never looks one up by string at runtime. It names *this*
/// enum, and each case declares three facts a test checks against the source:
///
/// - `attachedIn` is the file that must carry `.tutorialAnchor(.<case>)`. Delete
///   the control and the modifier goes with it, leaving the case unattached.
/// - `namedIn` is the file that must spell `control` as a literal. Rename the
///   button and the literal moves, leaving the case naming something the app no
///   longer says.
/// - `control` is the control's on-screen name, spelled once, here. The card
///   renders it from the anchor, and no step's prose may repeat it, so a rename
///   is one edit rather than a hunt through narration.
///
/// Each of those is a red suite in `TutorialFenceTests`, not a human noticing. A
/// fourth guard is the compiler: a deleted case breaks every step that names it,
/// so removing a control cannot leave a tour that silently highlights nothing.
///
/// This is the rule the app already applies to its own copy, one level up: a
/// backend's display name lives in `SummarizationEngine` and a sink's in
/// `PublishLanding`, never at the render site (UX31, UX49). A tutorial is copy
/// about controls, so it gets the same treatment.
/// Anchors point only at controls the window renders unconditionally. That is a
/// rule, not a coincidence: the filter bar's "Save as smart folder" was the first
/// candidate for a step and had to be dropped, because it is drawn only once a
/// filter is active, so a tour that opened on a clean Library would have pointed
/// at nothing every time. Driving the real UI means a step can only ever assume
/// what the surface guarantees; anything else is the tour driving app *state*,
/// which is a much larger promise than narrating.
enum TutorialAnchor: String, CaseIterable, Sendable {
    case scopeRail
    case record
    case search
    case preferencesGear
    case vocabulary
    case speakerLabels
    case regulatedMode

    /// Where a case lives in the app, and what the app calls it.
    struct Home: Sendable, Equatable {
        let surface: TutorialSurface
        /// Path, from the repository root, of the file carrying the attachment.
        let attachedIn: String
        /// Path, from the repository root, of the file spelling `control`.
        let namedIn: String
        /// The control's own on-screen name. One home, and this is it.
        let control: String
    }

    var home: Home {
        switch self {
        case .scopeRail:
            return Home(
                surface: .library,
                attachedIn: "daemon/Sources/MeetingPipe/LibrarySidebar.swift",
                namedIn: "daemon/Sources/MeetingPipe/LibrarySidebar.swift",
                control: "Library"
            )
        case .record:
            return Home(
                surface: .library,
                attachedIn: "daemon/Sources/MeetingPipe/LibraryToolbar.swift",
                namedIn: "daemon/Sources/MeetingPipe/LibraryToolbar.swift",
                control: "Record"
            )
        case .search:
            return Home(
                surface: .library,
                attachedIn: "daemon/Sources/MeetingPipe/FilterBarView.swift",
                namedIn: "daemon/Sources/MeetingPipe/FilterBarView.swift",
                control: "Search titles, summaries, decisions…"
            )
        case .preferencesGear:
            return Home(
                surface: .library,
                attachedIn: "daemon/Sources/MeetingPipe/LibraryToolbar.swift",
                namedIn: "daemon/Sources/MeetingPipe/LibraryToolbar.swift",
                control: "Preferences…"
            )
        case .vocabulary:
            return Home(
                surface: .preferencesPipeline,
                attachedIn: "daemon/Sources/MeetingPipe/Preferences/VocabularyEditor.swift",
                namedIn: "daemon/Sources/MeetingPipe/Preferences/VocabularyEditor.swift",
                control: "Vocabulary"
            )
        case .speakerLabels:
            return Home(
                surface: .preferencesPipeline,
                attachedIn: "daemon/Sources/MeetingPipe/Preferences/PreferencesView+Pipeline.swift",
                namedIn: "daemon/Sources/MeetingPipe/Preferences/PreferencesView+Pipeline.swift",
                control: "Speaker labels"
            )
        case .regulatedMode:
            return Home(
                surface: .preferencesPermissions,
                attachedIn: "daemon/Sources/MeetingPipe/Preferences/PreferencesView+Permissions.swift",
                namedIn: "daemon/Sources/MeetingPipe/Preferences/PreferencesView+Permissions.swift",
                control: "Regulated mode"
            )
        }
    }

    var surface: TutorialSurface { home.surface }
    /// The control's on-screen name, for the card to render. Never re-spelled.
    var control: String { home.control }
}

// MARK: - Attaching an anchor to a real control

/// Where each anchor sits inside the surface that reported it. Merged across the
/// whole surface so the overlay decides from one picture rather than from
/// whichever probe fired last, the way `GuideView` collects its heading offsets.
struct TutorialAnchorFrames: PreferenceKey {
    static let defaultValue: [TutorialAnchor: CGRect] = [:]
    static func reduce(value: inout [TutorialAnchor: CGRect], nextValue: () -> [TutorialAnchor: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Mark this view as the control `anchor` names.
    ///
    /// A geometry probe behind the control, reporting its frame in the enclosing
    /// stage's coordinate space. Nothing here reads the tutorial's state, so an
    /// anchored control renders identically whether the tutorial ever runs or not.
    func tutorialAnchor(_ anchor: TutorialAnchor) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: TutorialAnchorFrames.self,
                    value: [anchor: geo.frame(in: .named(TutorialStageSpace.name))]
                )
            }
        )
    }
}

/// The coordinate space every anchor reports into, declared by
/// `.tutorialStage(_:)` on the surface root. One name, so a frame read in a probe
/// and a hole drawn in the overlay are the same numbers.
enum TutorialStageSpace {
    static let name = "tutorial-stage"
}
