import Foundation

/// Start-time identity manifest written next to a recording so a termination
/// that skips `stop()` (crash, `kill -9`, rebuild, reinstall) can still route
/// the orphaned recording by the privacy + summary intent it was started with
/// (REC2 / AUD-6).
///
/// Before this, the meta sidecar existed only at clean stop and orphan recovery
/// enqueued every recovered file as `.auto` with no sidecar, so a BYO or NDA
/// meeting interrupted mid-call auto-summarized via Anthropic and published to
/// Notion at the next launch. The `.capturemode` marker already persisted the
/// capture posture for the redaction-quarantine decision, but not the two
/// signals recovery needs to keep data on-device: the summary mode (BYO must
/// never silently become an Anthropic+Notion auto-summary) and the workflow's
/// NDA / regulated routing.
///
/// Daemon-internal, like `<stem>.capturemode` and `<stem>.recordfail.json`: the
/// daemon both writes and reads it, and it is never part of the Swift-to-Python
/// `<stem>.meta.json` contract. On recovery the daemon rebuilds
/// `<stem>.meta.json` from `meta` so the pipeline still arms its egress guard
/// for NDA / regulated and keeps the meeting title; the summary mode drives
/// whether the recovered file is enqueued `.auto` or `.byo`.
enum RecordingManifest {

    static let schemaVersion = 1

    /// Parsed manifest: the recording's summary mode and the meta-sidecar
    /// payload captured at record start.
    struct Parsed: Equatable {
        let summaryMode: SummaryMode
        /// The `MeetingMetaSidecar.build` dictionary as written at start. Empty
        /// for a manual, workflow-less, non-regulated recording.
        let meta: [String: Any]

        static func == (lhs: Parsed, rhs: Parsed) -> Bool {
            lhs.summaryMode == rhs.summaryMode
                && NSDictionary(dictionary: lhs.meta).isEqual(to: rhs.meta)
        }
    }

    static func url(forStem stem: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(stem).recovery.json")
    }

    /// Persist the manifest atomically at recording start. Best-effort: a write
    /// failure only costs the privacy-aware recovery path, so it is logged but
    /// never throws into the start path.
    static func write(summaryMode: SummaryMode, meta: [String: Any], forStem stem: String, in directory: URL) {
        let payload: [String: Any] = [
            "schema_version": schemaVersion,
            "summary_mode": token(for: summaryMode),
            "meta": meta,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ) else {
            Log.writeLine("recorder", "WARN: could not serialize recovery manifest for \(stem)")
            return
        }
        do {
            try data.write(to: url(forStem: stem, in: directory), options: .atomic)
        } catch {
            Log.writeLine("recorder", "WARN: could not write recovery manifest for \(stem): \(error.localizedDescription)")
        }
    }

    /// Read the manifest for a stem, or nil when absent / malformed (a pre-REC2
    /// orphan, or a torn write). A nil return leaves recovery on its legacy
    /// default (enqueue `.auto`, no synthesized sidecar).
    static func read(forStem stem: String, in directory: URL) -> Parsed? {
        guard
            let data = try? Data(contentsOf: url(forStem: stem, in: directory)),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let mode = summaryMode(fromToken: obj["summary_mode"] as? String)
        let meta = (obj["meta"] as? [String: Any]) ?? [:]
        return Parsed(summaryMode: mode, meta: meta)
    }

    static func remove(forStem stem: String, in directory: URL) {
        try? FileManager.default.removeItem(at: url(forStem: stem, in: directory))
    }

    // MARK: - SummaryMode <-> token

    /// Fail-closed mapping: only the explicit `"byo"` token is BYO, so a torn or
    /// unknown value defaults to `.auto` (the existing recovery behavior), never
    /// silently flips an auto meeting to a paste bundle.
    static func summaryMode(fromToken token: String?) -> SummaryMode {
        token == "byo" ? .byo : .auto
    }

    static func token(for mode: SummaryMode) -> String {
        mode == .byo ? "byo" : "auto"
    }
}
