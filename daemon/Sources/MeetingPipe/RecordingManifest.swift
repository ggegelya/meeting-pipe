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
/// Since REC21 it also carries a second copy of the two redaction facts the
/// `.capturemode` and `.offrecord` markers hold, so one failed marker write does
/// not leave a crash-interrupted recording with nothing saying a cut was owed.
///
/// Daemon-internal, like `<stem>.capturemode` and `<stem>.recordfail.json`: the
/// daemon both writes and reads it, and it is never part of the Swift-to-Python
/// `<stem>.meta.json` contract. On recovery the daemon rebuilds
/// `<stem>.meta.json` from `meta` so the pipeline still arms its egress guard
/// for NDA / regulated and keeps the meeting title; the summary mode drives
/// whether the recovered file is enqueued `.auto` or `.byo`.
enum RecordingManifest {

    static let schemaVersion = 1

    /// Parsed manifest: the recording's summary mode, the meta-sidecar payload
    /// captured at record start, and the two redaction facts (REC21).
    struct Parsed: Equatable {
        let summaryMode: SummaryMode
        /// The `MeetingMetaSidecar.build` dictionary as written at start. Empty
        /// for a manual, workflow-less, non-regulated recording.
        let meta: [String: Any]
        /// The capture mode the recording started under, or nil in a manifest written
        /// before REC21. The second copy of `<stem>.capturemode`.
        var captureMode: CaptureMode? = nil
        /// An off-the-record span was opened under lossless capture: the second copy of
        /// `<stem>.offrecord`. False in a manifest written before REC21.
        var offRecord: Bool = false

        /// Whether this manifest alone says the recording owes a redaction.
        var owesRedaction: Bool { captureMode == .captureFirstRedact || offRecord }

        static func == (lhs: Parsed, rhs: Parsed) -> Bool {
            lhs.summaryMode == rhs.summaryMode
                && lhs.captureMode == rhs.captureMode
                && lhs.offRecord == rhs.offRecord
                && NSDictionary(dictionary: lhs.meta).isEqual(to: rhs.meta)
        }
    }

    /// What is on disk for a stem's manifest (REC21). `unreadable` is kept apart from
    /// `absent` because recovery and Retry fail closed on it: it used to read as "no
    /// manifest", which recovers as `.auto` with no sidecar, so a BYO, NDA or regulated
    /// orphan whose manifest was torn went down the cloud path.
    enum LoadResult: Equatable {
        case absent
        case unreadable
        case parsed(Parsed)

        var parsed: Parsed? {
            if case .parsed(let p) = self { return p }
            return nil
        }
    }

    static func url(forStem stem: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(stem).recovery.json")
    }

    /// Persist the manifest atomically. Best-effort: a write failure only costs the
    /// privacy-aware recovery path, so it is logged and answered, never thrown into the
    /// start path.
    @discardableResult
    static func write(
        summaryMode: SummaryMode, meta: [String: Any], captureMode: CaptureMode? = nil, offRecord: Bool = false,
        forStem stem: String, in directory: URL
    ) -> Bool {
        guard let data = encode(
            summaryMode: summaryMode, meta: meta, captureMode: captureMode, offRecord: offRecord, forStem: stem
        ) else { return false }
        return write(data, forStem: stem, in: directory)
    }

    /// PERF28: the same write off the main thread, awaited, under `RecordStartFileWrite`'s bound.
    /// The payload is serialized on the caller (the meta dictionary is not Sendable) and only the
    /// bytes cross. A write that runs out its budget is logged and the start goes on; its late
    /// return keeps what it wrote, since the recording is most likely still live and needs it
    /// (a late write after a clean stop leaves a stale manifest beside the final, which costs
    /// nothing a crash-time routing loss would not cost more).
    @MainActor
    static func writeOffMain(
        summaryMode: SummaryMode, meta: [String: Any], captureMode: CaptureMode?,
        forStem stem: String, in directory: URL,
        onLateFinish: @escaping @Sendable () -> Void = {}
    ) async {
        guard let data = encode(
            summaryMode: summaryMode, meta: meta, captureMode: captureMode, offRecord: false, forStem: stem
        ) else { return }
        let outcome = await RecordStartFileWrite.run(
            producing: url(forStem: stem, in: directory), keepsLateResult: true, onLateFinish: onLateFinish
        ) {
            _ = write(data, forStem: stem, in: directory)
        }
        if case .timedOut = outcome {
            Log.writeLine("recorder", "WARN: recovery manifest write for \(stem) did not finish within \(Int(RecordStartFileWrite.budgetSeconds)) s; continuing; a late write is kept")
        }
    }

    private static func encode(
        summaryMode: SummaryMode, meta: [String: Any], captureMode: CaptureMode?, offRecord: Bool,
        forStem stem: String
    ) -> Data? {
        var payload: [String: Any] = [
            "schema_version": schemaVersion,
            "summary_mode": token(for: summaryMode),
            "meta": meta,
            "off_record": offRecord,
        ]
        if let captureMode { payload["capture_mode"] = captureMode.marker }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ) else {
            Log.writeLine("recorder", "WARN: could not serialize recovery manifest for \(stem)")
            return nil
        }
        return data
    }

    private static func write(_ data: Data, forStem stem: String, in directory: URL) -> Bool {
        do {
            try data.write(to: url(forStem: stem, in: directory), options: .atomic)
            return true
        } catch {
            Log.writeLine("recorder", "WARN: could not write recovery manifest for \(stem): \(error.localizedDescription)")
            return false
        }
    }

    /// Read the manifest for a stem (REC21). A missing file is `absent` (a pre-REC2 orphan, or
    /// a clean stop that removed it), which leaves recovery on its legacy default (`.auto`, no
    /// synthesized sidecar). Anything present that is not what this writer produces is
    /// `unreadable`: bytes that do not parse, a `summary_mode` that is not exactly `"auto"` or
    /// `"byo"` (a misspelt token used to recover a BYO meeting as `.auto`, F148), a `meta` that
    /// is present but not an object (it used to become an empty payload, dropping the NDA and
    /// regulated routing), or a `capture_mode` / `off_record` of the wrong type or value. Keys
    /// a manifest written before REC21 lacks (`capture_mode`, `off_record`) read as absent.
    static func load(forStem stem: String, in directory: URL) -> LoadResult {
        let url = url(forStem: stem, in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard
            let data = try? Data(contentsOf: url),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let modeToken = obj["summary_mode"] as? String,
            let mode = summaryMode(fromToken: modeToken)
        else { return .unreadable }
        var meta: [String: Any] = [:]
        if let raw = obj["meta"] {
            guard let dict = raw as? [String: Any] else { return .unreadable }
            meta = dict
        }
        var captureMode: CaptureMode?
        if let raw = obj["capture_mode"] {
            guard let token = raw as? String, let parsed = CaptureMode(marker: token) else { return .unreadable }
            captureMode = parsed
        }
        var offRecord = false
        if let raw = obj["off_record"] {
            // JSONSerialization hands back NSNumber for bools and numbers alike; only a JSON
            // boolean counts.
            guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                return .unreadable
            }
            offRecord = number.boolValue
        }
        return .parsed(Parsed(summaryMode: mode, meta: meta, captureMode: captureMode, offRecord: offRecord))
    }

    static func remove(forStem stem: String, in directory: URL) {
        try? FileManager.default.removeItem(at: url(forStem: stem, in: directory))
    }

    // MARK: - SummaryMode <-> token

    /// The two tokens this writer produces, or nil for anything else, which makes the manifest
    /// `unreadable` (REC21, F148). This used to map every unknown value to `.auto` under a
    /// "fail-closed" label that held only in the sense that it never flipped an auto meeting to
    /// BYO; a BYO meeting with a torn token went to the cloud summary.
    static func summaryMode(fromToken token: String) -> SummaryMode? {
        switch token {
        case "auto": return .auto
        case "byo": return .byo
        default: return nil
        }
    }

    static func token(for mode: SummaryMode) -> String {
        mode == .byo ? "byo" : "auto"
    }
}
