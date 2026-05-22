import Foundation

/// Persists why a meeting's pipeline run failed, as a `<stem>.error.json`
/// sidecar next to the recording. A failed transcribe / summarize / run
/// otherwise surfaces only as one transient notification banner, which
/// Focus modes silence and which is gone in seconds: the owner can lose a
/// meeting and never know. This sidecar is durable. It survives a daemon
/// restart and a missed notification, and the Library reads it to mark the
/// row failed with a reason until the owner retries or deletes the meeting.
///
/// Daemon-owned, distinct from the pipeline's success-path
/// `<stem>.run.json`. The run sidecar is written by `mp run-all` only
/// after summarize succeeds; this file is written by the daemon, which is
/// the one process that observes every failure mode (a SIGKILL'd pipeline
/// writes nothing). The two never describe the same run: success XOR
/// failure. A successful run clears any stale failure sidecar.
enum PipelineFailureSidecar {

    /// Which pipeline stage failed. Coarse but honest: the daemon
    /// distinguishes on-device transcription from the `mp run-all`
    /// subprocess from a launch failure. It does not split summarize vs
    /// publish inside `mp run-all`; `reason` carries that detail.
    enum Stage: String {
        case transcribe   // FluidAudio ASR + diarization, in-process
        case pipeline     // mp run-all: summarize + publish
        case launch       // mp executable missing or could not spawn

        /// Human-readable label for the failed-meeting detail surface.
        var displayName: String {
            switch self {
            case .transcribe: return "Transcription"
            case .pipeline:   return "Summarize and publish"
            case .launch:     return "Pipeline launch"
            }
        }
    }

    /// Parsed contents of a `<stem>.error.json` sidecar.
    struct Failure: Equatable {
        let stage: Stage
        let reason: String
        let ts: String
    }

    /// Suffix appended to the meeting stem. `MeetingStore.stem(of:)`
    /// splits on the first dot, so the stem still resolves cleanly.
    static let suffix = ".error.json"

    static func fileName(forStem stem: String) -> String { stem + suffix }

    static func url(forStem stem: String, in dir: URL) -> URL {
        dir.appendingPathComponent(fileName(forStem: stem))
    }

    /// Write (or overwrite) the failure sidecar. Atomic via temp-file +
    /// rename so a crash mid-write never leaves a half-formed file.
    /// Best-effort: a write failure is logged and swallowed, because
    /// losing the sidecar must never escalate a pipeline failure into a
    /// daemon crash. Returns the written URL, or nil on failure.
    @discardableResult
    static func write(
        stem: String,
        in dir: URL,
        stage: Stage,
        reason: String,
        timestamp: Date = Date()
    ) -> URL? {
        let payload: [String: Any] = [
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

    /// Parse a failure sidecar at a known URL. Returns nil for a missing
    /// file, unreadable bytes, malformed JSON, or an unknown stage value.
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

    /// Parse the failure sidecar for a stem in a recordings directory.
    static func read(stem: String, in dir: URL) -> Failure? {
        read(at: url(forStem: stem, in: dir))
    }

    /// Remove the failure sidecar for a stem, if present. Called when a
    /// run succeeds so a recovered meeting drops out of the failed set.
    /// Best-effort: a missing file is success; any other error is logged.
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
