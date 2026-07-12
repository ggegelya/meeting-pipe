import Foundation

/// One user-flagged moment in a recording (FEAT8): the offset in seconds from
/// recording start where the user pressed the flag hotkey. Pure value type; the
/// session controller appends offsets on the main queue and flushes them at stop.
struct Marker: Equatable, Codable {
    var tSeconds: Double

    enum CodingKeys: String, CodingKey {
        case tSeconds = "t_seconds"
    }
}

/// On-disk `<stem>.markers.json`: the moments the user flagged during a
/// recording. Read by the pipeline (the spanning transcript segments become
/// user-flagged excerpts for the summarizer) and by the Library transcript tab
/// (anchor chips that seek). Written by the daemon at stop, schema versioned
/// per CI2.
struct MarkerFile: Codable {
    var schemaVersion: Int = 1
    var markers: [Marker]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case markers
    }

    /// Sidecar path for a final recording URL: `<stem>.markers.json` next to
    /// `<stem>.wav`. A metadata sibling, safe in the Library-scanned tree.
    static func url(forFinal final: URL) -> URL {
        let stem = final.deletingPathExtension().lastPathComponent
        return final.deletingLastPathComponent().appendingPathComponent("\(stem).markers.json")
    }

    /// Write the flagged offsets for `final`. No-op when empty, so an unflagged
    /// meeting leaves no sidecar. Best-effort: a failed write never blocks the
    /// recording from finishing.
    static func write(seconds: [Double], forFinal final: URL) {
        guard !seconds.isEmpty else { return }
        let file = MarkerFile(markers: seconds.map { Marker(tSeconds: $0) })
        do {
            let data = try JSONEncoder().encode(file)
            try data.write(to: url(forFinal: final), options: .atomic)
        } catch {
            Log.writeLine("recorder", "WARN: could not write markers for \(final.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Read the flagged markers for `final`, or nil when none exists.
    static func read(forFinal final: URL) -> MarkerFile? {
        read(stem: final.deletingPathExtension().lastPathComponent,
             in: final.deletingLastPathComponent())
    }

    /// Read the flagged markers for a stem. The stem-addressed form, for readers
    /// that have no recording to derive the path from: a `drop` retention policy
    /// reclaims the audio but leaves the markers alongside the transcript.
    static func read(stem: String, in directory: URL) -> MarkerFile? {
        let url = directory.appendingPathComponent("\(stem).markers.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MarkerFile.self, from: data)
    }
}
