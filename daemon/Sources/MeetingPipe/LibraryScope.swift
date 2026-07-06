import Foundation

/// Smart-folder rail scope (TECH-B). Narrows the library before filter chips run. The `workflow` case carries `Workflow.ID` rather than the name so a rename can't silently drop the scope.
enum LibraryScope: Hashable {
    case allMeetings
    case today
    case last7Days
    case last30Days
    case needsYou
    case ndaOnly
    case untagged
    /// Cross-meeting facts projection (DV1): a read-only aggregate of open
    /// actions + recent decisions across the whole library, rendered in its own
    /// view rather than filtering the meeting list (`includes` returns false).
    case facts
    /// Ask-AI projection (AI3): a question box over an engine-backed, cited answer
    /// across the whole library. Like `.facts`, a view rather than a list filter
    /// (`includes` returns false).
    case ask
    case workflow(Workflow.ID)

    /// Rail row label and list header.
    var title: String {
        switch self {
        case .allMeetings: return "All meetings"
        case .today:       return "Today"
        case .last7Days:   return "Last 7 days"
        case .last30Days:  return "Last 30 days"
        case .needsYou:    return "Needs you"
        case .ndaOnly:     return "NDA only"
        case .untagged:    return "Untagged"
        case .facts:       return "Facts"
        case .ask:         return "Ask"
        case .workflow:    return ""   // resolved at render time via the store
        }
    }

    /// SF Symbol for non-workflow scopes. Nil for workflow scopes (they render a colored dot).
    var systemImage: String? {
        switch self {
        case .allMeetings: return "tray.full"
        case .today, .last7Days, .last30Days: return "calendar"
        case .needsYou:    return "bell"
        case .ndaOnly:     return "lock"
        case .untagged:    return "tag"
        case .facts:       return "list.bullet.rectangle"
        case .ask:         return "bubble.left.and.text.bubble.right"
        case .workflow:    return nil
        }
    }

    /// True when the scope is a specific workflow. The toolbar uses this to show the "Edit workflow" button and the inspector pane.
    var isWorkflow: Bool {
        if case .workflow = self { return true }
        return false
    }

    var workflowID: Workflow.ID? {
        if case .workflow(let id) = self { return id }
        return nil
    }

    /// True when `meeting` passes this scope. `workflows` must be the current snapshot (needed for NDA resolution). `now` is injected so tests can pin the clock.
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
        case .needsYou:
            // Anything that wants the owner to act: a failed run, a long-meeting
            // bundle waiting on a paste, a no-speech/empty result to inspect, or a
            // finished meeting whose publish failed outright ("none") or only
            // partially landed ("partial"). A never-published local/NDA meeting
            // has a nil publishState, so it is intentionally absent here
            // (TECH-DSN17; `.empty` added in UX15 so no-speech recordings surface
            // rather than sitting silently in All meetings).
            switch meeting.status {
            case .failed, .manualPasteReady, .empty:
                return true
            case .done:
                return meeting.publishState == "none" || meeting.publishState == "partial"
            default:
                return false
            }
        case .ndaOnly:
            return Self.resolveWorkflow(for: meeting, in: workflows)?.flags.ndaMode == true
        case .untagged:
            return (meeting.workflowName?.isEmpty ?? true)
        case .facts, .ask:
            // Not a list filter: these projections render in their own center
            // column, so no meeting "belongs" to the scope.
            return false
        case .workflow(let id):
            return Self.resolveWorkflow(for: meeting, in: workflows)?.id == id
        }
    }

    /// Lookup by name because the meta sidecar persists the name, not the id (cross-machine portability - TECH-B4). The rail's scope uses id, so a rename can't orphan it; this lookup bridges the two.
    private static func resolveWorkflow(for meeting: Meeting, in workflows: [Workflow]) -> Workflow? {
        guard let name = meeting.workflowName, !name.isEmpty else { return nil }
        return workflows.first { $0.name == name }
    }
}
