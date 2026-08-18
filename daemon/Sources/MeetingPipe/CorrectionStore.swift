import Foundation

/// On-disk correction record (see ADR 0015). Phase 2 collects grades; Phase 3 reads the directory to assemble a LoRA training set. Schema locked here so the Swift writer and Python reader (`mp/corrections.py`) agree without a generated client.
enum CorrectionStore {

    enum Verdict: String {
        case good
        case bad
        case edited
    }

    enum Error: Swift.Error {
        case directoryUnavailable(String)
        case summaryUnreadable(URL)
        case runSidecarUnreadable(URL)
        case writeFailed(String)
    }

    /// `~/Library/Application Support/MeetingPipe/corrections`, created on demand.
    static func directory() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(Endpoints.Paths.correctionsRelative,
                                              isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir,
                                                    withIntermediateDirectories: true)
        } catch {
            throw Error.directoryUnavailable(error.localizedDescription)
        }
        return dir
    }

    static func path(forStem stem: String) throws -> URL {
        try directory().appendingPathComponent("\(stem).json")
    }

    /// Loads `<stem>.run.json` (carries `backend`, `model_id`, transcript path).
    static func loadRunSidecar(at url: URL) throws -> [String: Any] {
        do {
            let data = try Data(contentsOf: url)
            guard
                let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw Error.runSidecarUnreadable(url) }
            return parsed
        } catch {
            throw Error.runSidecarUnreadable(url)
        }
    }

    /// Loads `<stem>.summary.json` as a generic dict so re-serialization preserves all fields, including ones Swift doesn't model.
    static func loadOriginalSummary(at url: URL) throws -> [String: Any] {
        do {
            let data = try Data(contentsOf: url)
            guard
                let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw Error.summaryUnreadable(url) }
            return parsed
        } catch {
            throw Error.summaryUnreadable(url)
        }
    }

    /// Writes `<stem>.json`. `correctedSummary` is omitted when nil (good/bad verdicts produce smaller records than edited ones). Atomic replacement, so a crash leaves either the previous record or the new one and never neither (PERF8).
    @discardableResult
    static func write(
        stem: String,
        transcriptPath: String,
        summaryJsonPath: String,
        modelId: String,
        backend: String,
        verdict: Verdict,
        originalSummary: [String: Any],
        correctedSummary: [String: Any]? = nil,
        notes: String? = nil,
        timestamp: Date = Date(),
        directoryOverride: URL? = nil
    ) throws -> URL {
        var record: [String: Any] = [
            "transcript_path": transcriptPath,
            "summary_json_path": summaryJsonPath,
            "model_id": modelId,
            "backend": backend,
            "ts": Self.iso8601.string(from: timestamp),
            "verdict": verdict.rawValue,
            "original_summary": originalSummary,
        ]
        if let corrected = correctedSummary {
            record["corrected_summary"] = corrected
        }
        if let notes = notes, !notes.isEmpty {
            record["notes"] = notes
        }

        guard JSONSerialization.isValidJSONObject(record) else {
            throw Error.writeFailed("invalid JSON object")
        }
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: record,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw Error.writeFailed(error.localizedDescription)
        }

        let dir = try directoryOverride ?? directory()
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        let final = dir.appendingPathComponent("\(stem).json")
        // PERF8 (0): atomic replacement, no window where the destination is absent.
        //
        // This was `write(to: temp)`, then `removeItem(url)`, then `moveItem(temp, url)`. Between
        // the remove and the move the real sidecar did not exist and the only copy of the data was
        // in a `.tmp` nothing in either tree reads or sweeps, so a process death in that window did
        // not lose the edit being saved: it silently lost every hand-made entry this file ever
        // held, unrecoverably, because the reader is fail-open and a missing file reads as empty.
        // That is the wrong failure direction, and it is not theoretical here (four `.ips` reports
        // on 2026-08-13 and 08-14; REC12 is a confirmed abort that runs no termination handler).
        //
        // `.atomic` already writes to a temporary file and renames it into place, so the manual
        // dance was both redundant and strictly less safe than the one-liner it wrapped. A failure
        // now leaves the previous file exactly as it was.
        do {
            try data.write(to: final, options: .atomic)
        } catch {
            throw Error.writeFailed(error.localizedDescription)
        }
        return final
    }

    /// Stems whose correction record is an actual edit (`verdict == edited`), i.e.
    /// summaries the user corrected locally. Drives the Library's "Summary edited
    /// locally" marker (UX15). Grades (good/bad) are excluded: they are not edits.
    /// Returns an empty set when the directory is absent or unreadable.
    static func editedStems(directoryOverride: URL? = nil) -> Set<String> {
        let dir: URL
        do {
            dir = try directoryOverride ?? directory()
        } catch {
            return []
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var stems: Set<String> = []
        for url in entries where url.pathExtension == "json" {
            let stem = url.deletingPathExtension().lastPathComponent
            guard !stem.isEmpty,
                  let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["verdict"] as? String) == Verdict.edited.rawValue
            else { continue }
            stems.insert(stem)
        }
        return stems
    }

    /// Raw bytes of the correction record for the given stem, or nil when absent/unreadable.
    /// Sendable-returning sibling of `read`, so a caller can do the file I/O off the main
    /// actor and parse the (non-Sendable) `[String: Any]` on it (CONC4).
    static func readData(stem: String, directoryOverride: URL? = nil) -> Data? {
        let dir: URL
        do {
            dir = try directoryOverride ?? directory()
        } catch {
            return nil
        }
        return try? Data(contentsOf: dir.appendingPathComponent("\(stem).json"))
    }

    /// Reads the correction record for the given stem, or nil when absent/unreadable.
    static func read(stem: String, directoryOverride: URL? = nil) -> [String: Any]? {
        guard let data = readData(stem: stem, directoryOverride: directoryOverride) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
