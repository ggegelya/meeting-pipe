import Foundation

/// Writes `<stem>.error.json` next to a recording when the pipeline fails, so the Library can surface the failure durably (banners are silenced by Focus mode and gone in seconds).
/// Daemon-owned; distinct from `<stem>.run.json` which is written by `mp run-all` only on success. A SIGKILL'd pipeline writes nothing - the daemon is the only observer of every failure mode. Success clears a stale failure sidecar.
enum PipelineFailureSidecar {

    /// Coarse stage label. Does not split summarize vs publish inside `mp run-all`; `reason` carries that detail.
    enum Stage: String {
        case transcribe   // FluidAudio ASR + diarization, in-process
        case pipeline     // mp run-all: summarize + publish
        case launch       // mp executable missing or could not spawn
        case interrupted  // daemon restart stranded a queued/in-flight job (PIPE3)

        var displayName: String {
            switch self {
            case .transcribe:  return "Transcription"
            case .pipeline:    return "Summarize and publish"
            case .launch:      return "Pipeline launch"
            case .interrupted: return "Interrupted"
            }
        }
    }

    struct Failure: Equatable {
        let stage: Stage
        let reason: String
        let ts: String
    }

    /// Suffix appended to the meeting stem. `MeetingStore.stem(of:)` splits on the first dot, so the stem still resolves cleanly.
    static let suffix = ".error.json"

    static func fileName(forStem stem: String) -> String { stem + suffix }

    static func url(forStem stem: String, in dir: URL) -> URL {
        dir.appendingPathComponent(fileName(forStem: stem))
    }

    /// Write (or overwrite) the failure sidecar. Atomic via temp-file + rename. Write failures are swallowed - losing the sidecar must never escalate into a daemon crash. Returns the written URL, or nil on failure.
    @discardableResult
    static func write(
        stem: String,
        in dir: URL,
        stage: Stage,
        reason: String,
        timestamp: Date = Date()
    ) -> URL? {
        let payload: [String: Any] = [
            "schema_version": 1,
            "stem": stem,
            "stage": stage.rawValue,
            "reason": reason,
            "ts": iso8601.string(from: timestamp),
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else {
            Log.main.warning("PipelineFailureSidecar: could not serialize failure for \(stem)")
            return nil
        }
        let final = url(forStem: stem, in: dir)
        let temp = final.appendingPathExtension("tmp")
        do {
            try data.write(to: temp, options: .atomic)
            if FileManager.default.fileExists(atPath: final.path) {
                _ = try? FileManager.default.removeItem(at: final)
            }
            try FileManager.default.moveItem(at: temp, to: final)
            return final
        } catch {
            try? FileManager.default.removeItem(at: temp)
            Log.main.warning(
                "PipelineFailureSidecar: write failed for \(stem): \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// Parse a failure sidecar. Returns nil for missing file, unreadable bytes, malformed JSON, or unknown stage.
    static func read(at url: URL) -> Failure? {
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stageRaw = obj["stage"] as? String,
              let stage = Stage(rawValue: stageRaw),
              let reason = obj["reason"] as? String,
              let ts = obj["ts"] as? String else {
            return nil
        }
        return Failure(stage: stage, reason: reason, ts: ts)
    }

    static func read(stem: String, in dir: URL) -> Failure? {
        read(at: url(forStem: stem, in: dir))
    }

    /// Remove the failure sidecar when a run succeeds, so the meeting drops out of the failed set. Missing file is treated as success; other errors are logged.
    static func clear(stem: String, in dir: URL) {
        let target = url(forStem: stem, in: dir)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        do {
            try FileManager.default.removeItem(at: target)
        } catch {
            Log.main.warning(
                "PipelineFailureSidecar: clear failed for \(stem): \(error.localizedDescription)"
            )
        }
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
