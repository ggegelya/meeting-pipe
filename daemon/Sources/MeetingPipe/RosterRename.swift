import AppKit

/// The one roster-rename path (FEAT3-MANAGE, extended by DV3), shared by
/// Preferences ▸ Pipeline ▸ People and the Library's People rail so both do the
/// same thing to the same files.
///
/// Two steps, in order:
///   1. `mp roster rename` renames the entry in `roster.json`, keeping the
///      voiceprint. The pipeline owns the roster, so this stays a CLI call.
///   2. the **carry**: the new name is written into the reversible speaker-label
///      overlay of every meeting the person appears in, so past transcripts and
///      the People rail follow the rename.
///
/// Step 2 exists because step 1 alone renames a name that nothing else on disk
/// uses: summaries and transcripts keep whatever they were written with, so a
/// rename would silently empty the person's history in the rail that lists it.
/// The carry never rewrites `<stem>.json` (that is FEAT3-UNDO's whole point) and
/// renaming back collapses what it added, so it stays reversible.
///
/// A failed carry is not a failed rename: the roster entry has already changed,
/// so the caller is told the rename succeeded and the per-meeting failure is
/// logged. Nothing here is destructive.
enum RosterRename {

    /// A modal name prompt (NSAlert + text field), the AppKit idiom for the few
    /// text inputs outside SwiftUI. Returns the trimmed new name, or nil on
    /// cancel / no-change / empty.
    static func prompt(currentName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Rename “\(currentName)”"
        alert.informativeText = "The voiceprint is kept; only the name changes. Past meetings follow the new name."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = currentName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty || trimmed == currentName) ? nil : trimmed
    }

    /// Rename `old` to `new`, then carry the name across the library. `completion`
    /// runs on the main queue with the number of meetings the carry touched.
    ///
    /// Threading: the carry itself runs on the launcher's completion thread (a
    /// `Process.terminationHandler`, never main), because it reads and rewrites a
    /// sidecar pair per meeting and the library can hold hundreds.
    static func run(
        from old: String,
        to new: String,
        launcher: PipelineDriver,
        recordingsDir: URL? = (try? Config.load())?.recording.outputDir,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        Log.event(category: "coordinator", action: "roster_rename_requested",
                  attributes: ["old": old, "new": new])
        launcher.rosterRename(old: old, new: new) { result in
            switch result {
            case .success:
                let touched = recordingsDir.map { carry(from: old, to: new, in: $0) } ?? 0
                DispatchQueue.main.async {
                    Log.event(category: "coordinator", action: "roster_rename_done",
                              attributes: ["old": old, "new": new, "meetings_carried": touched])
                    completion(.success(touched))
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    Log.event(category: "coordinator", action: "roster_rename_failed",
                              attributes: ["old": old, "error": error.localizedDescription])
                    completion(.failure(error))
                }
            }
        }
    }

    /// Rewrite the speaker-label overlay of every meeting `old` appears in.
    /// Returns how many meetings were touched. Best-effort per meeting: one
    /// unwritable sidecar does not abort the rest.
    @discardableResult
    static func carry(from old: String, to new: String, in directory: URL) -> Int {
        let key = PeopleRail.normalized(old)
        guard key != PeopleRail.normalized(new), !PeopleRail.normalized(new).isEmpty else { return 0 }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return 0 }
        // A meeting is a candidate if it has either sidecar the resolution reads.
        let stems = Set(
            names
                .filter { $0.hasSuffix(".summary.json") || $0.hasSuffix(".speaker_labels.json") }
                .map { MeetingStore.stem(of: URL(fileURLWithPath: $0)) }
        )

        var touched = 0
        for stem in stems.sorted() {
            let overlay = SpeakerLabelStore.read(stem: stem, in: directory)
            let attendees = MeetingSummary.load(
                from: directory.appendingPathComponent("\(stem).summary.json")
            )?.attendees ?? []
            let people = PeopleRail.resolvedPeople(attendees: attendees, overlay: overlay)
            guard people.contains(where: { PeopleRail.normalized($0) == key }),
                  let next = PeopleRail.renamed(overlay, attendees: attendees, from: old, to: new)
            else { continue }
            do {
                try SpeakerLabelStore.replace(overlay: next, stem: stem, in: directory)
                touched += 1
            } catch {
                Log.main.warning("roster rename carry failed for \(stem): \(error.localizedDescription)")
            }
        }
        return touched
    }
}
