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

    /// Writes `<stem>.json`. `correctedSummary` is omitted when nil (good/bad verdicts produce smaller records than edited ones). Atomic via temp-file + rename so a crash never leaves a half-formed file that breaks Phase 3.
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
        let temp = dir.appendingPathComponent("\(stem).json.tmp")
        do {
            try data.write(to: temp, options: .atomic)
            if FileManager.default.fileExists(atPath: final.path) {
                _ = try? FileManager.default.removeItem(at: final)
            }
            try FileManager.default.moveItem(at: temp, to: final)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw Error.writeFailed(error.localizedDescription)
        }
        return final
    }

    /// Reads the correction record for the given stem, or nil when absent/unreadable.
    static func read(stem: String, directoryOverride: URL? = nil) -> [String: Any]? {
        let dir: URL
        do {
            dir = try directoryOverride ?? directory()
        } catch {
            return nil
        }
        let url = dir.appendingPathComponent("\(stem).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
