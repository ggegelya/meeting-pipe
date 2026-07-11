import Combine
import Foundation
import TOMLKit

/// Observable owner of the on-disk workflows directory. One TOML file per workflow at `~/.config/meeting-pipe/workflows/<id>.toml`; UUID is stable across renames so override pins survive retitles. Saves write through a `.writing` sibling then `replaceItemAt` for crash safety. Mutations run on the main queue; disk writes hop to a private queue so the UI never blocks.
final class WorkflowStore: ObservableObject {

    private let directory: URL
    private let writeQueue = DispatchQueue(
        label: "com.meetingpipe.workflowstore.write",
        qos: .utility
    )

    @Published private(set) var workflows: [Workflow] = []

    /// Default workflows directory, sibling to `config.toml`.
    static let defaultDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/meeting-pipe/workflows")
    }()

    /// Does not load on init; callers invoke `load` explicitly so tests can drive migration with a fresh directory.
    init(directory: URL = WorkflowStore.defaultDirectory) {
        self.directory = directory
    }

    /// Load all `*.toml` files from the directory, replacing the in-memory list. Safe to call after a manual filesystem edit.
    func load() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            workflows = []
            return
        }
        var loaded: [Workflow] = []
        for url in entries where url.pathExtension == "toml" {
            do {
                let wf = try Self.decode(url: url)
                loaded.append(wf)
            } catch {
                Log.main.warning("WorkflowStore: skipping unreadable \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        loaded.sort(by: Self.orderComparator)
        workflows = loaded
    }

    /// Insert or replace a workflow and persist to disk.
    func upsert(_ workflow: Workflow) throws {
        let w = workflow
        if w.isDefault {
            // Clear the flag on every other workflow first to maintain the single-default invariant.
            workflows = workflows.map { existing in
                guard existing.id != w.id else { return existing }
                var clone = existing
                clone.isDefault = false
                return clone
            }
        }
        if let idx = workflows.firstIndex(where: { $0.id == w.id }) {
            workflows[idx] = w
        } else {
            workflows.append(w)
        }
        try persistAll()
    }

    /// Remove the workflow with the given id. Returns false (no-op) when not found or when the workflow is the default.
    @discardableResult
    func delete(id: UUID) throws -> Bool {
        guard let idx = workflows.firstIndex(where: { $0.id == id }) else { return false }
        if workflows[idx].isDefault { return false }
        let url = directory.appendingPathComponent("\(id.uuidString).toml")
        workflows.remove(at: idx)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        return true
    }

    /// Assign sequential `order` values from the given array and persist.
    func reorder(_ ordered: [Workflow]) throws {
        var rebuilt: [Workflow] = []
        for (i, w) in ordered.enumerated() {
            var clone = w
            clone.order = i
            rebuilt.append(clone)
        }
        workflows = rebuilt
        try persistAll()
    }

    /// The workflow flagged `isDefault`, or nil on a freshly-empty store.
    var defaultWorkflow: Workflow? {
        workflows.first(where: { $0.isDefault })
    }

    /// Lookup by id; nil when absent.
    func workflow(id: UUID) -> Workflow? {
        workflows.first(where: { $0.id == id })
    }

    // MARK: - Persistence helpers

    /// Write all in-memory workflows to disk. Round-tripping the full set on each save is cheap at single-digit counts and keeps load/memory invariants simple.
    private func persistAll() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for wf in workflows {
            let url = directory.appendingPathComponent("\(wf.id.uuidString).toml")
            let toml = Self.encode(wf)
            let tmp = url.appendingPathExtension("writing")
            try toml.data(using: .utf8)?.write(to: tmp, options: .atomic)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        }
    }

    private static func orderComparator(_ a: Workflow, _ b: Workflow) -> Bool {
        if a.order != b.order { return a.order < b.order }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    // MARK: - TOML encoding/decoding
    //
    // TOMLKit bridges values one level at a time, so the struct is walked by hand.
    // Flat, explicit keys mean a user who opens the file sees names that match UI labels.

    static func encode(_ wf: Workflow) -> String {
        let doc = TOMLTable()
        doc["id"] = wf.id.uuidString
        doc["name"] = wf.name
        doc["color"] = wf.color
        if let e = wf.emoji, !e.isEmpty { doc["emoji"] = e }
        doc["context_prompt"] = wf.contextPrompt
        // Omit the key when the workflow inherits the global default (TECH-WF1);
        // a missing key decodes back to nil (inherit).
        if let backend = wf.backend {
            doc["backend"] = backend.rawValue
        }
        doc["is_default"] = wf.isDefault
        doc["order"] = wf.order

        let flags = TOMLTable()
        flags["nda_mode"] = wf.flags.ndaMode
        flags["redact_muted_spans"] = wf.flags.redactMutedSpans
        doc["flags"] = flags

        // Omit the table entirely while the workflow keeps its audio forever
        // (STOR1's default), so every workflow predating retention stays
        // byte-unchanged on disk. An absent table decodes back to `.keep`.
        if wf.retention != WorkflowRetention() {
            let retention = TOMLTable()
            retention["policy"] = wf.retention.policy.rawValue
            retention["after_days"] = wf.retention.afterDays
            doc["retention"] = retention
        }

        let rulesArr = TOMLArray()
        for r in wf.matchingRules {
            let t = TOMLTable()
            t["id"] = r.id.uuidString
            t["bundle_id"] = r.bundleID
            t["title_regex"] = r.titleRegex
            rulesArr.append(t)
        }
        doc["matching_rules"] = rulesArr

        let sinksArr = TOMLArray()
        for s in wf.sinks {
            let t = TOMLTable()
            t["type"] = s.typeName
            if case .notion(let dbId) = s {
                t["database_id"] = dbId
            }
            sinksArr.append(t)
        }
        doc["sinks"] = sinksArr

        // WF7: `[[extra_sections]]`, mirroring `matching_rules`. Omitted while a
        // workflow defines none, so a workflow predating WF7 stays byte-unchanged
        // on disk until it is edited (the `retention`-table precedent).
        if !wf.extraSections.isEmpty {
            let sectionsArr = TOMLArray()
            for s in wf.extraSections {
                let t = TOMLTable()
                t["id"] = s.id.uuidString
                t["name"] = s.name
                t["instruction"] = s.instruction
                sectionsArr.append(t)
            }
            doc["extra_sections"] = sectionsArr
        }

        return doc.convert(to: .toml)
    }

    static func decode(url: URL) throws -> Workflow {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let doc = try TOMLTable(string: raw)

        let idString = doc["id"]?.string ?? UUID().uuidString
        let id = UUID(uuidString: idString) ?? UUID()
        let name = doc["name"]?.string ?? "Untitled"
        let color = doc["color"]?.string ?? MPColors.defaultWorkflowHex
        let emoji = doc["emoji"]?.string
        let contextPrompt = doc["context_prompt"]?.string ?? ""
        // Missing or unrecognized backend decodes to nil (inherit the global
        // default); a valid value stays pinned. (TECH-WF1)
        let backend = doc["backend"]?.string.flatMap(WorkflowBackend.init(rawValue:))
        let isDefault = doc["is_default"]?.bool ?? false
        let order = doc["order"]?.int ?? 0

        var flags = WorkflowFlags()
        if let f = doc["flags"]?.table {
            flags.ndaMode = f["nda_mode"]?.bool ?? false
            flags.redactMutedSpans = f["redact_muted_spans"]?.bool ?? false
        }

        // A missing table, or a policy name a newer build wrote, decodes to
        // keep-forever. Retention deletes audio, so it fails safe.
        var retention = WorkflowRetention()
        if let r = doc["retention"]?.table {
            retention.policy = (r["policy"]?.string).flatMap(RetentionPolicy.init(rawValue:)) ?? .keep
            retention.afterDays = max(1, r["after_days"]?.int ?? retention.afterDays)
        }

        var rules: [WorkflowMatchingRule] = []
        if let arr = doc["matching_rules"]?.array {
            for value in arr {
                guard let t = value.table else { continue }
                let rid = (t["id"]?.string).flatMap { UUID(uuidString: $0) } ?? UUID()
                rules.append(WorkflowMatchingRule(
                    id: rid,
                    bundleID: t["bundle_id"]?.string ?? "",
                    titleRegex: t["title_regex"]?.string ?? ""
                ))
            }
        }

        var sinks: [WorkflowSink] = []
        if let arr = doc["sinks"]?.array {
            for value in arr {
                guard let t = value.table else { continue }
                let type = t["type"]?.string ?? ""
                switch type {
                case "notion":
                    sinks.append(.notion(databaseId: t["database_id"]?.string ?? ""))
                case "obsidian":
                    sinks.append(.obsidian)
                case "filesystem":
                    sinks.append(.filesystem)
                default:
                    continue
                }
            }
        }

        var extraSections: [WorkflowExtraSection] = []
        if let arr = doc["extra_sections"]?.array {
            for value in arr {
                guard let t = value.table else { continue }
                let sid = (t["id"]?.string).flatMap { UUID(uuidString: $0) } ?? UUID()
                extraSections.append(WorkflowExtraSection(
                    id: sid,
                    name: t["name"]?.string ?? "",
                    instruction: t["instruction"]?.string ?? ""
                ))
            }
        }

        return Workflow(
            id: id,
            name: name,
            color: color,
            emoji: emoji,
            matchingRules: rules,
            contextPrompt: contextPrompt,
            sinks: sinks,
            backend: backend,
            flags: flags,
            retention: retention,
            extraSections: extraSections,
            isDefault: isDefault,
            order: order
        )
    }
}
