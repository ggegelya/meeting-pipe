import Foundation

/// The coarse selector driven by the smart-folder rail (TECH-B IA
/// re-architecture).
///
/// A scope narrows the entire library to a single bucket before the
/// in-list filter chips (`MeetingFilter`) run on top. Two surfaces read
/// from it:
///   • `LibrarySidebar` renders one row per case and binds the selection.
///   • `LibraryListView` calls `predicate(_:workflows:)` before letting
///     `MeetingFilterEngine` apply the user's chip filter.
///
/// The "workflow" associated value carries the Workflow.ID rather than
/// the name so a rename in the editor doesn't silently drop the scope.
enum LibraryScope: Hashable {
    case allMeetings
    case today
    case last7Days
    case last30Days
    case ndaOnly
    case untagged
    case workflow(Workflow.ID)

    /// Display label for the rail row and the list header.
    var title: String {
        switch self {
        case .allMeetings: return "All meetings"
        case .today:       return "Today"
        case .last7Days:   return "Last 7 days"
        case .last30Days:  return "Last 30 days"
        case .ndaOnly:     return "NDA only"
        case .untagged:    return "Untagged"
        case .workflow:    return ""   // resolved at render time via the store
        }
    }

    /// SF Symbol used by non-workflow scopes. Workflow scopes render
    /// their colored dot directly, so this returns nil for them.
    var systemImage: String? {
        switch self {
        case .allMeetings: return "tray.full"
        case .today, .last7Days, .last30Days: return "calendar"
        case .ndaOnly:     return "lock"
        case .untagged:    return "tag"
        case .workflow:    return nil
        }
    }

    /// True when this scope filters by a specific workflow. The toolbar
    /// uses this to decide whether to surface the "Edit workflow"
    /// affordance and whether to host the right-side inspector pane.
    var isWorkflow: Bool {
        if case .workflow = self { return true }
        return false
    }

    var workflowID: Workflow.ID? {
        if case .workflow(let id) = self { return id }
        return nil
    }

    /// Whether a meeting passes this scope. `workflows` must be the
    /// current store snapshot — needed so the "NDA only" scope can
    /// resolve a meeting's workflow → flags.ndaMode.
    ///
    /// `now` is injected so unit tests can pin the wall clock without
    /// stubbing `Date.init`.
    func includes(_ meeting: Meeting, workflows: [Workflow], now: Date = Date()) -> Bool {
        switch self {
        case .allMeetings:
            return true
        case .today:
            return meeting.startedAt >= Calendar.current.startOfDay(for: now)
        case .last7Days:
            guard let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: now)
            else { return true }
            return meeting.startedAt >= cutoff
        case .last30Days:
            guard let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: now)
            else { return true }
            return meeting.startedAt >= cutoff
        case .ndaOnly:
            return Self.resolveWorkflow(for: meeting, in: workflows)?.flags.ndaMode == true
        case .untagged:
            return (meeting.workflowName?.isEmpty ?? true)
        case .workflow(let id):
            return Self.resolveWorkflow(for: meeting, in: workflows)?.id == id
        }
    }

    /// Workflow lookup by name. The meta sidecar persists the name
    /// rather than the id (cross-machine portability of recordings was
    /// the original choice — see TECH-B4); the rail resolves by id so a
    /// rename can't orphan the row, which means we match by name here.
    private static func resolveWorkflow(for meeting: Meeting, in workflows: [Workflow]) -> Workflow? {
        guard let name = meeting.workflowName, !name.isEmpty else { return nil }
        return workflows.first { $0.name == name }
    }
}
