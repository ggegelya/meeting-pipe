import Combine
import Foundation
import TOMLKit

/// Observable owner of the on-disk workflows directory.
///
/// Persistence: one TOML file per workflow at
/// `~/.config/meeting-pipe/workflows/<id>.toml`. The UUID stays stable
/// across renames so the matcher's "explicit override" path can pin a
/// meeting to a workflow even after the user retitles it.
///
/// Atomicity: every save writes through a sibling `.writing` file and
/// then `replaceItemAt`s the canonical name, the same shape `ConfigStore`
/// uses. A crash mid-write leaves the previous file intact.
///
/// Threading: SwiftUI views observe via `@Published`; mutations come
/// from the main queue (Preferences / Workflows tab edits, B2 migration,
/// matcher resolution). Disk writes hop to a private queue so the UI
/// never blocks on flash.
final class WorkflowStore: ObservableObject {

    private let directory: URL
    private let writeQueue = DispatchQueue(
        label: "com.meetingpipe.workflowstore.write",
        qos: .utility
    )

    @Published private(set) var workflows: [Workflow] = []

    /// Default workflows path under the user's home dir; matches the
    /// convention used by `~/.config/meeting-pipe/config.toml`.
    static let defaultDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/meeting-pipe/workflows")
    }()

    /// Initialise without loading. Callers explicitly invoke `load` so
    /// tests can drive the migration path with a fresh-empty directory.
    init(directory: URL = WorkflowStore.defaultDirectory) {
        self.directory = directory
    }

    /// Materialise every `*.toml` under the workflows directory into
    /// memory. Idempotent and safe to call after a manual filesystem
    /// edit — every read replaces the in-memory list wholesale.
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

    /// Insert or replace a workflow. Saves to disk synchronously on the
    /// write queue so callers can rely on the file being on disk before
    /// they return.
    func upsert(_ workflow: Workflow) throws {
        let w = workflow
        if w.isDefault {
            // Single-default invariant: clearing the flag on every other
            // workflow first lets the new default land cleanly.
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

    /// Remove the workflow with the matching id. No-op when the id isn't
    /// present. The default workflow can't be removed — `delete` returns
    /// false in that case so the UI can surface a banner instead.
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

    /// Persist the given new order. The wizard's drag-reorder uses this.
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

    /// The workflow flagged `isDefault`. Returns nil for a freshly-empty
    /// store — the matcher logs and falls back to a synthesised "no
    /// workflow" state in that case rather than crashing.
    var defaultWorkflow: Workflow? {
        workflows.first(where: { $0.isDefault })
    }

    /// Lookup by id; nil when not present.
    func workflow(id: UUID) -> Workflow? {
        workflows.first(where: { $0.id == id })
    }

    // MARK: - Persistence helpers

    /// Write every in-memory workflow to disk. Cheap enough at our scale
    /// (single-digit workflows in practice) to round-trip the entire set
    /// on each save; keeps the file/memory invariants trivial to reason
    /// about and lets `load` stay idempotent.
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
    // TOMLKit's value-bridging works one level at a time, so we walk the
    // struct by hand. Keeping the schema flat and explicit means a user
    // who opens the file in their editor sees keys that match the UI
    // labels — useful when debugging a workflow that won't match.

    static func encode(_ wf: Workflow) -> String {
        let doc = TOMLTable()
        doc["id"] = wf.id.uuidString
        doc["name"] = wf.name
        doc["color"] = wf.color
        if let e = wf.emoji, !e.isEmpty { doc["emoji"] = e }
        doc["context_prompt"] = wf.contextPrompt
        doc["backend"] = wf.backend.rawValue
        doc["is_default"] = wf.isDefault
        doc["order"] = wf.order

        let flags = TOMLTable()
        flags["nda_mode"] = wf.flags.ndaMode
        doc["flags"] = flags

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

        return doc.convert(to: .toml)
    }

    static func decode(url: URL) throws -> Workflow {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let doc = try TOMLTable(string: raw)

        let idString = doc["id"]?.string ?? UUID().uuidString
        let id = UUID(uuidString: idString) ?? UUID()
        let name = doc["name"]?.string ?? "Untitled"
        let color = doc["color"]?.string ?? "#3478F6"
        let emoji = doc["emoji"]?.string
        let contextPrompt = doc["context_prompt"]?.string ?? ""
        let backendRaw = doc["backend"]?.string ?? "anthropic"
        let backend = WorkflowBackend(rawValue: backendRaw) ?? .anthropic
        let isDefault = doc["is_default"]?.bool ?? false
        let order = doc["order"]?.int ?? 0

        var flags = WorkflowFlags()
        if let f = doc["flags"]?.table {
            flags.ndaMode = f["nda_mode"]?.bool ?? false
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
            isDefault: isDefault,
            order: order
        )
    }
}
