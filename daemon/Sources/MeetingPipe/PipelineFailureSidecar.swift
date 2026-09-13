import Foundation

/// Writes `<stem>.error.json` next to a recording when the pipeline fails, so the Library can surface the failure durably (banners are silenced by Focus mode and gone in seconds).
/// Daemon-owned; distinct from `<stem>.run.json` which is written by `mp run-all` only on success. A SIGKILL'd pipeline writes nothing - the daemon is the only observer of every failure mode. Success clears a stale failure sidecar.
enum PipelineFailureSidecar {

    /// Coarse stage label. `reason` carries diagnostics. `publish` reuses the saved summary; other stages may reuse a finalized transcript (UX80).
    enum Stage: String {
        case transcribe   // FluidAudio ASR + diarization, in-process
        case pipeline     // mp run-all: summarize + publish
        case publish      // every configured sink failed; the summary is on disk (PIPE1)
        case launch       // mp executable missing or could not spawn
        case interrupted  // daemon restart stranded a queued/in-flight job (PIPE3)
        case memory       // the on-device model did not fit, or free RAM crossed the floor (LOCAL16)

        var displayName: String {
            switch self {
            case .transcribe:  return "Transcription"
            case .pipeline:    return "Summarize and publish"
            case .publish:     return "Publishing"
            case .launch:      return "Pipeline launch"
            case .interrupted: return "Interrupted"
            case .memory:      return "Not enough memory"
            }
        }

        /// True when a retry can skip straight to publishing the existing `<stem>.summary.json` instead of re-running summarize. Only the publish stage qualifies: it is the one failure that leaves a complete, paid-for summary behind.
        var retriesFromSummary: Bool { self == .publish }
    }

    struct Failure: Equatable {
        let stage: Stage
        let reason: String
        let ts: String
        var metadata: FailureMetadata? = nil
    }

    /// LOCAL16: substring every memory refusal and watchdog abort carries (`mp.resource_guard.LOW_MEMORY_MARKER`). There is no shared constant across the language boundary, so the phrase itself is the contract, the same arrangement as UX21's `not in the local HuggingFace cache`. Matching it is what turns a generic "Summarize and publish" failure into a row that says the Mac ran out of memory.
    static let lowMemoryMarker = "not enough memory"

    /// Suffix appended to the meeting stem. `MeetingStore.stem(of:)` splits on the first dot, so the stem still resolves cleanly.
    static let suffix = ".error.json"

    static func fileName(forStem stem: String) -> String { stem + suffix }

    static func url(forStem stem: String, in dir: URL) -> URL {
        dir.appendingPathComponent(fileName(forStem: stem))
    }

    /// Write (or overwrite) the failure sidecar. Atomic replacement (PERF8). Write failures are swallowed - losing the sidecar must never escalate into a daemon crash. Returns the written URL, or nil on failure.
    @discardableResult
    static func write(
        stem: String,
        in dir: URL,
        stage: Stage,
        reason: String,
        metadata: FailureMetadata? = nil,
        timestamp: Date = Date()
    ) -> URL? {
        var payload: [String: Any] = [
            "schema_version": 1,
            "stem": stem,
            "stage": stage.rawValue,
            "reason": reason,
            "ts": iso8601.string(from: timestamp),
        ]
        if let metadata, let data = try? JSONEncoder().encode(metadata) {
            payload["failure"] = try? JSONSerialization.jsonObject(with: data)
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else {
            Log.main.warning("PipelineFailureSidecar: could not serialize failure for \(stem)")
            return nil
        }
        let final = url(forStem: stem, in: dir)
        // PERF8 (0): atomic replacement, no window where the destination is absent. This is the
        // fourth instance of the remove-then-move shape, and the one PERF8's spec did not name: it
        // scoped to the three stores holding hand-made edits, on the grounds that those cannot be
        // regenerated. This sidecar can be, so the severity is lower, but losing it is still
        // user-visible (a failed meeting reads as clean in the Needs you rail and loses its retry
        // affordance), and leaving one known-bad copy of a data-loss shape is the debt the spec
        // cites as its own reason for fixing three rather than one.
        do {
            try data.write(to: final, options: .atomic)
            return final
        } catch {
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
        let metadata = (obj["failure"] as? [String: Any]).flatMap {
            (try? JSONSerialization.data(withJSONObject: $0)).flatMap(FailureMetadata.decode)
        }
        return Failure(stage: stage, reason: reason, ts: ts, metadata: metadata)
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
