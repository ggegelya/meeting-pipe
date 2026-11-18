import Foundation

/// STOR7: everything one meeting left on this Mac, located before anything is trashed.
///
/// `softDeleteMeeting` used to trash the library entries for a stem and stop there. That threw the
/// sink sidecars (`<stem>.filesystem.json`, `<stem>.obsidian.json`), the only pointers to the
/// published copies, into the Trash and left the copies themselves, now unfindable from the app;
/// and it never touched the grading in `corrections/<stem>.json`. This reads the pointers first.
///
/// Pure over its inputs: the directory listing (one per batch, so a later list-once batch needs no
/// API change), the roots a published copy may be trashed from, and two file probes.
struct MeetingFootprint: Equatable {
    /// Library entries whose stem matches.
    var rawFiles: [URL] = []
    /// `corrections/<stem>.json`, the summary grading (ADR 0015), when there is one.
    var corrections: URL?
    /// Local published copies safe to trash: the filesystem sink's two files, the Obsidian note and
    /// its audio attachment. Each passed `publishedCopy`'s guard.
    var publishedCopies: [URL] = []
    /// What stays where it is, so the confirm can say so.
    var kept: [Kept] = []

    enum Kept: Equatable, Hashable {
        /// A Notion page. Removing it needs `mp unpublish` (STOR7's remaining half).
        case notionPage
        /// The LAN sink's copy on a network share, likewise.
        case networkCopy
        /// A local copy the guard refused: outside today's sink folders, or not named for this stem.
        case unverifiedCopy(PublishSink)
        /// A sink sidecar that could not be read, so where its copy is cannot be known.
        case unreadableSidecar(PublishSink)
    }

    struct Probe {
        /// A regular file (not a directory, not followed through a symlink) exists at the URL.
        var isRegularFile: (URL) -> Bool
        /// A sink sidecar's JSON object.
        var readObject: (URL) -> StoreLoad<[String: Any]>

        static let live = Probe(
            isRegularFile: { url in
                let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
                return type == .typeRegular
            },
            readObject: { url in
                StoreLoad.read(url) { data in
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw StoreShapeError(why: "\(url.lastPathComponent) is not a JSON object")
                    }
                    return object
                }
            }
        )
    }

    /// - Parameters:
    ///   - listing: the library directory's entries (one listing serves a whole batch).
    ///   - correctionsDir: nil when there is none to look in (tests, a headless build).
    ///   - publishedRoots: the local sink folders a published copy may be trashed from.
    ///   - derived: false for the merge's fragment cleanup, which keeps the old raw-only scope.
    static func locate(
        stem: String,
        listing: [URL],
        correctionsDir: URL?,
        publishedRoots: [URL],
        derived: Bool = true,
        probe: Probe = .live
    ) -> MeetingFootprint {
        var footprint = MeetingFootprint()
        footprint.rawFiles = listing.filter { MeetingStore.stem(of: $0) == stem }
        guard derived else { return footprint }

        if let dir = correctionsDir {
            let url = dir.appendingPathComponent("\(stem).json")
            if probe.isRegularFile(url) { footprint.corrections = url }
        }

        func sidecar(_ sink: PublishSink) -> URL? {
            footprint.rawFiles.first { $0.lastPathComponent == "\(stem).\(sink.rawValue).json" }
        }
        func consider(_ path: String?, sink: PublishSink, named accepts: (String) -> Bool) {
            guard let path, !path.isEmpty else { return }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            guard probe.isRegularFile(url) else { return }   // already gone: nothing to trash or to keep
            // A sink folder set to the library itself: the file is already a library entry.
            if footprint.rawFiles.contains(where: { $0.standardizedFileURL.path == url.path }) { return }
            if accepts(url.lastPathComponent), isUnder(url, roots: publishedRoots) {
                footprint.publishedCopies.append(url)
            } else {
                footprint.kept.append(.unverifiedCopy(sink))
            }
        }

        if let url = sidecar(.filesystem) {
            switch probe.readObject(url) {
            case .loaded(let obj):
                consider(obj["summary_path"] as? String, sink: .filesystem) { $0 == "\(stem).summary.md" }
                consider(obj["actions_path"] as? String, sink: .filesystem) { $0 == "\(stem).actions.json" }
            case .missing:
                break
            case .unparseable, .unreadable:
                footprint.kept.append(.unreadableSidecar(.filesystem))
            }
        }
        if let url = sidecar(.obsidian) {
            switch probe.readObject(url) {
            case .loaded(let obj):
                // PIPE31: the note's name leads with the stem, so two recordings never share one. An
                // older title-only note cannot be proved this meeting's alone, so it stays.
                consider(obj["note_path"] as? String, sink: .obsidian) { $0.hasPrefix("\(stem) ") || $0 == "\(stem).md" }
                if let vault = obj["vault"] as? String, let rel = obj["attachment_rel"] as? String, !rel.isEmpty {
                    consider((vault as NSString).appendingPathComponent(rel), sink: .obsidian) { $0.hasPrefix("\(stem).") }
                }
            case .missing:
                break
            case .unparseable, .unreadable:
                footprint.kept.append(.unreadableSidecar(.obsidian))
            }
        }
        if sidecar(.notion) != nil { footprint.kept.append(.notionPage) }
        if sidecar(.lan) != nil { footprint.kept.append(.networkCopy) }
        return footprint
    }

    /// Strictly inside one of `roots` after `..` is resolved; a root itself never qualifies. Each
    /// root is matched as written and with its symlinks resolved, because the pipeline's sinks
    /// record resolved paths (`publish_fs` / `publish_obsidian` call `.resolve()`).
    static func isUnder(_ url: URL, roots: [URL]) -> Bool {
        let path = url.standardizedFileURL.path
        return roots.contains { root in
            [root.standardizedFileURL.path, root.resolvingSymlinksInPath().standardizedFileURL.path].contains { base in
                !base.isEmpty && base != "/" && path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
            }
        }
    }
}

// MARK: - The confirm

extension MeetingFootprint {
    /// The single-meeting delete confirm's body, from what was actually located (STOR7 item 4). It
    /// replaced "Every file for this meeting (audio, transcript, summary, sidecars) goes to the
    /// Trash", which was untrue on both sides: published copies and the grading stayed, and nothing
    /// said voice samples, digests and backups do.
    var confirmText: String {
        var goes = ["the audio, transcript, summary and sidecars"]
        if !publishedCopies.isEmpty {
            goes.append(publishedCopies.count == 1 ? "the published local copy" : "the \(publishedCopies.count) published local copies")
        }
        if corrections != nil { goes.append("your grading of its summary") }
        var text = "This moves \(Self.list(goes)) to the Trash. "
        let offMachine = Self.offMachineSentence(kept)
        if !offMachine.isEmpty { text += offMachine + " " }
        return text + Self.stayingSentence + " " + LibraryDialogs.trashRecoveryNote
    }

    /// What no delete removes, named in every Trash confirm, single and batch.
    static let stayingSentence =
        "Voice samples learned from it, digests that quote it, and backups that contain it stay."

    /// The batch confirm's body: a sum over the selection's footprints.
    static func batchConfirmText(_ footprints: [MeetingFootprint]) -> String {
        let copies = footprints.reduce(0) { $0 + $1.publishedCopies.count }
        var text = "Each meeting's audio, transcript, summary and sidecars go to the Trash"
        if copies > 0 { text += ", with \(copies == 1 ? "1 published local copy" : "\(copies) published local copies")" }
        if footprints.contains(where: { $0.corrections != nil }) { text += " and their summary gradings" }
        text += ". "
        let offMachine = offMachineSentence(footprints.flatMap(\.kept))
        if !offMachine.isEmpty { text += offMachine + " " }
        return text + stayingSentence.replacingOccurrences(of: "from it", with: "from them")
            .replacingOccurrences(of: "quote it", with: "quote them")
            .replacingOccurrences(of: "contain it", with: "contain them")
            + " " + LibraryDialogs.trashRecoveryNote
    }

    private static func offMachineSentence(_ kept: [Kept]) -> String {
        var parts: [String] = []
        if kept.contains(.notionPage) { parts.append("the Notion page") }
        if kept.contains(.networkCopy) { parts.append("the copy on your network share") }
        let unverified = kept.contains { if case .unverifiedCopy = $0 { return true }; if case .unreadableSidecar = $0 { return true }; return false }
        if unverified { parts.append("a published copy outside your current sink folders") }
        guard !parts.isEmpty else { return "" }
        return "Not removed, and no longer findable from the app: \(list(parts))."
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}

// MARK: - The trash

/// Trash a located footprint and count what actually moved (STOR7, SW-18): `meeting_deleted` used
/// to log the matched count after a loop that swallowed each failure.
struct FootprintTrashOutcome {
    var trashed = 0
    var failed = 0
    var correctionsTrashed = false
    var publishedTrashed = 0
    var firstFailure: Error?

    /// `kind` goes to the `trash_failed` row; `file` only for a library entry, whose name is a
    /// timestamp stem. A published note's name carries the title slug (SEC38), so it is never logged.
    mutating func trash(_ url: URL, stem: String, kind: String, logName: Bool, with trash: (URL) throws -> Void) -> Bool {
        do {
            try trash(url)
            trashed += 1
            return true
        } catch {
            failed += 1
            var attrs: [String: Any] = ["stem": stem, "kind": kind]
            if logName { attrs["file"] = url.lastPathComponent }
            Log.failure(category: "library", action: "trash_failed", error: error, attributes: attrs, describe: logName)
            if firstFailure == nil { firstFailure = error }
            return false
        }
    }
}

/// STOR7: the folders a delete may trash a published copy from: the filesystem sink's output folder
/// and the Obsidian vault, as configured now. The LAN share is not here: a network copy stays until
/// `mp unpublish` exists. An empty setting contributes nothing.
enum LocalPublishRoots {
    static func roots(filesystemOutputDir: String, obsidianVaultPath: String) -> [URL] {
        [filesystemOutputDir, obsidianVaultPath]
            .map { ($0 as NSString).expandingTildeInPath }
            .filter { !$0.isEmpty && $0 != "/" }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
