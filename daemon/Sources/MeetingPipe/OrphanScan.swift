import Foundation

/// Detects two drift states: a .wav whose stem fails MeetingStore.parseStem
/// (so the library can't surface it), and a stem whose sidecars exist without
/// a .wav (silently dropped by MeetingStore.scan). Read-only by design; the
/// user resolves each orphan case-by-case.
enum OrphanScan {

    /// A .wav on disk the library cannot surface; currently only stems that fail yyyyMMdd-HHmmss parsing.
    struct WavWithoutRow: Equatable {
        let stem: String
        let url: URL
    }

    /// A stem whose sidecars exist but whose .wav is missing; the library drops such rows.
    struct RowWithoutWav: Equatable {
        let stem: String
        /// Orphaned sidecar files. Sorted for deterministic reports.
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

    /// Pure in-memory scan. Split from scan(directory:) so tests don't need real files.
    static func detect(stems: [String: [URL]]) -> Report {
        var wavsWithoutRow: [WavWithoutRow] = []
        var rowsWithoutWav: [RowWithoutWav] = []

        for (stem, files) in stems {
            if stem.isEmpty { continue }
            // REC6: `.mic.wav` / `.system.wav` also end in `.wav`, so the old
            // `pathExtension == "wav"` check counted an unmerged orphan (capture
            // intermediates, no merged final) as "a wav exists" and hid it from the
            // scan. Exclude the intermediates so such a stem reads as no-wav and, with
            // its `.recovery.json` / `.recordfail.json` sidecar, surfaces as a finding.
            let wav = files.first {
                $0.pathExtension == "wav"
                    && !$0.lastPathComponent.hasSuffix(".mic.wav")
                    && !$0.lastPathComponent.hasSuffix(".system.wav")
            }
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

    /// Read directory once, group by stem, run detect. Returns empty report on error.
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
