import Foundation

/// Detects the two ways a recordings directory can drift out of sync
/// with the library list: a `<stem>.wav` that the library can't
/// surface (because the stem doesn't match the daemon's
/// `yyyyMMdd-HHmmss` format, so `MeetingStore.parseStem` rejects it)
/// and a stem whose sidecars exist without an accompanying `.wav`
/// (which the library silently drops in `MeetingStore.scan`).
///
/// The reaper is intentionally read-only: it surfaces a list, it
/// never deletes. The user resolves the orphan by hand because the
/// remediation is case-by-case (rename, delete, restore from backup).
enum OrphanScan {

    /// A wav file present on disk that the library cannot turn into
    /// a row. Today the only path to this state is a stem that does
    /// not parse as `yyyyMMdd-HHmmss`.
    struct WavWithoutRow: Equatable {
        let stem: String
        let url: URL
    }

    /// A stem whose sidecar(s) are on disk without the load-bearing
    /// `<stem>.wav`. Library rows require the wav; without it the
    /// sidecars are dead weight.
    struct RowWithoutWav: Equatable {
        let stem: String
        /// The orphaned sidecar files (relative to the recordings
        /// directory). Sorted so the report is deterministic.
        let sidecars: [URL]
    }

    struct Report: Equatable {
        let wavsWithoutRow: [WavWithoutRow]
        let rowsWithoutWav: [RowWithoutWav]

        var isEmpty: Bool {
            wavsWithoutRow.isEmpty && rowsWithoutWav.isEmpty
        }

        var total: Int {
            wavsWithoutRow.count + rowsWithoutWav.count
        }
    }

    /// Pure scan over an in-memory file list. Split from `scan(directory:)`
    /// so tests don't have to seed real files for every assertion.
    static func detect(stems: [String: [URL]]) -> Report {
        var wavsWithoutRow: [WavWithoutRow] = []
        var rowsWithoutWav: [RowWithoutWav] = []

        for (stem, files) in stems {
            if stem.isEmpty { continue }
            let wav = files.first { $0.pathExtension == "wav" }
            let sidecars = files
                .filter { $0.pathExtension != "wav" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            if let wav, MeetingStore.parseStem(stem) == nil {
                wavsWithoutRow.append(WavWithoutRow(stem: stem, url: wav))
            }
            if wav == nil, !sidecars.isEmpty {
                rowsWithoutWav.append(RowWithoutWav(stem: stem, sidecars: sidecars))
            }
        }

        wavsWithoutRow.sort { $0.stem < $1.stem }
        rowsWithoutWav.sort { $0.stem < $1.stem }
        return Report(
            wavsWithoutRow: wavsWithoutRow,
            rowsWithoutWav: rowsWithoutWav
        )
    }

    /// Read the recordings directory once, group by stem, and run
    /// `detect`. Missing or unreadable directory returns an empty
    /// report so the doctor probe can carry on with a friendly note.
    static func scan(directory: URL) -> Report {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return Report(wavsWithoutRow: [], rowsWithoutWav: [])
        }
        var byStem: [String: [URL]] = [:]
        for url in entries {
            let stem = MeetingStore.stem(of: url)
            if stem.isEmpty { continue }
            byStem[stem, default: []].append(url)
        }
        return detect(stems: byStem)
    }
}
