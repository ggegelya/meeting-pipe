import Foundation

/// Which live workflow a meeting belongs to (WF11).
///
/// A meeting's `<stem>.meta.json` records the workflow's id and the name it had when the
/// meeting was recorded. The Library used to resolve by the name alone, so renaming a
/// workflow (which rewrites only `workflows/<uuid>.toml`) orphaned every meeting under it:
/// zero in its rail count and inspector, out of NDA only, and its vocabulary table no longer
/// found. The id survives a rename, so it is asked first.
///
/// The name stays the fallback, for two reasons that are not going away: a meeting recorded
/// before `workflow_id` existed has only a name, and a library moved to another Mac whose
/// workflows carry other UUIDs has ids that name nothing there (TECH-B4's portability). So an
/// id that names no live workflow falls back to the name, unlike `PrepCardStore.matches`,
/// where a mismatched id is a definite "not this one".
///
/// Pure. `mp.workflows.workflow_name_for_id` + `mp.glossary.meeting_workflow_names` are the
/// Python mirror for the glossary half, pinned by the CI4 `glossary-golden.json` fixture.
enum WorkflowIdentity {

    /// The key both sides compare ids on: case-insensitive, as `PrepCardStore.matches` does.
    static func idKey(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The live workflow a meeting belongs to: the one whose id matches `workflowID`, else the
    /// first one named `workflowName`, else nil.
    static func resolve(
        workflowID: String?,
        workflowName: String?,
        byID: [String: Workflow],
        byName: [String: Workflow]
    ) -> Workflow? {
        if let id = workflowID, !id.isEmpty, let live = byID[idKey(id)] {
            return live
        }
        guard let name = workflowName, !name.isEmpty else { return nil }
        return byName[name]
    }

    /// The name a meeting's glossary table is keyed by: the current name of the workflow its
    /// id points at, else the name it recorded. `live` is (id, name) so the CI4 fixture test
    /// can drive it without building whole workflows.
    static func currentName(
        workflowID: String?,
        recordedName: String?,
        live: [(id: String, name: String)]
    ) -> String? {
        if let id = workflowID, !id.isEmpty,
           let match = live.first(where: { idKey($0.id) == idKey(id) }) {
            return match.name
        }
        guard let recorded = recordedName, !recorded.isEmpty else { return nil }
        return recorded
    }

    static func currentName(workflowID: String?, recordedName: String?, workflows: [Workflow]) -> String? {
        currentName(
            workflowID: workflowID, recordedName: recordedName,
            live: workflows.map { (id: $0.id.uuidString, name: $0.name) }
        )
    }

    /// The names a meeting's glossary table may be keyed by, in the order they are tried: the
    /// current name of the workflow its id points at, then the name it recorded. The recorded
    /// name stays a candidate after a known id because a workflow renamed before WF11 moved
    /// tables still has its table under the old name (the 2026-11-21 amendment);
    /// `GlossaryStore.resolvedTerms(at:workflowNames:)` takes the first that has a usable term.
    /// `currentName` stays the one name a new term is written under. Mirror:
    /// `mp.glossary.meeting_workflow_names`.
    static func glossaryNames(workflowID: String?, recordedName: String?, live: [(id: String, name: String)]) -> [String] {
        var names: [String] = []
        if let id = workflowID, !id.isEmpty,
           let match = live.first(where: { idKey($0.id) == idKey(id) }) {
            names.append(match.name)
        }
        if let recorded = recordedName, !recorded.isEmpty, !names.contains(recorded) {
            names.append(recorded)
        }
        return names
    }

    static func glossaryNames(workflowID: String?, recordedName: String?, workflows: [Workflow]) -> [String] {
        glossaryNames(
            workflowID: workflowID, recordedName: recordedName,
            live: workflows.map { (id: $0.id.uuidString, name: $0.name) }
        )
    }

    /// What the rail counts and the list derivation have to re-run on (WF11): each workflow's
    /// id, name and NDA flag. Membership and NDA only both read them, so a rename or an NDA
    /// toggle has to recount even when nothing in the library moved, and an unrelated
    /// re-render must not.
    struct Fingerprint: Equatable {
        struct Entry: Equatable {
            let id: Workflow.ID
            let name: String
            let ndaMode: Bool
        }
        let entries: [Entry]

        init(_ workflows: [Workflow]) {
            entries = workflows.map { Entry(id: $0.id, name: $0.name, ndaMode: $0.flags.ndaMode) }
        }

        static let empty = Fingerprint([])
    }
}
