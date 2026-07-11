import Foundation

/// Read-only view of the pipeline-owned named-speaker roster
/// (`~/.config/meeting-pipe/roster.json`), surfaced in Preferences ▸ Pipeline as a
/// "People" list (FEAT3-MANAGE). The daemon reads it only for display; every mutation
/// (rename / remove) goes through `mp roster` so the matching + k-means logic keeps a
/// single owner. This is the same display-only exception `VoiceprintProfile` makes for
/// `voiceprint.json`, not part of the `<stem>.meta.json` Swift-to-Python contract.
enum RosterProfile {

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(Endpoints.Paths.rosterRelative)
    }

    /// One enrolled person: the name and how many sample embeddings back it.
    struct Person: Equatable, Identifiable {
        let name: String
        let sampleCount: Int
        var id: String { name }
    }

    /// The enrolled people, sorted case-insensitively by name, or `[]` when the roster
    /// is absent / empty / malformed. Pure over the URL for testability.
    static func people(at url: URL = fileURL) -> [Person] {
        guard
            let data = try? Data(contentsOf: url),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let people = obj["people"] as? [[String: Any]]
        else { return [] }
        return people
            .compactMap { entry -> Person? in
                guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
                return Person(name: name, sampleCount: (entry["samples"] as? [Any])?.count ?? 0)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
