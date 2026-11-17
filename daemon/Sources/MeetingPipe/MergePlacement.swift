import Foundation

/// REC36: where the system channel sits in the merge and where the recording is cut, persisted
/// beside the capture intermediates so the orphan sweep merges a recording `stop()` did not
/// finish the same way `stop()` would have.
///
/// The REC9 head offset is measured from the recorder's own memory (the system channel's first
/// frame against the recording start) and the END9 held-end trim is decided by the session
/// controller at stop, so neither survived to `recoverOrphan`, which merged at offset 0 with no
/// cut. In the field the offset's p90 is 4.24 s and its maximum 33.21 s, so a recovered recording
/// placed the far side that much too early.
///
/// `<stem>.placement.json`, daemon-internal like `<stem>.recordfail.json`: the recorder writes it
/// at stop before the merge (removed again once a verified final is promoted) and at the
/// termination flush, and `RecordingPostProcessor.recoverOrphan` reads it. `span_sec` is written
/// only at the termination flush: its presence says REC30's coverage check never ran at stop, so
/// recovery runs it instead, and a stop that did run it is never measured twice.
enum MergePlacement {

    static let schemaVersion = 1

    struct Values: Equatable {
        /// REC9: seconds after the recording started that the system channel's first frame landed.
        var systemHeadOffsetSec: Double
        /// END9: cut the final at this many seconds, nil for no cut.
        var limitSeconds: Double? = nil
        /// REC30: recording start to capture stop, present only when the stop-time coverage check
        /// did not run.
        var spanSec: Double? = nil
    }

    enum LoadResult: Equatable {
        case absent
        case unreadable
        case loaded(Values)
    }

    static func url(forFinal final: URL) -> URL {
        let stem = final.deletingPathExtension().lastPathComponent
        return final.deletingLastPathComponent().appendingPathComponent("\(stem).placement.json")
    }

    /// Best-effort and atomic: a failed write costs only the placement of a recording that is then
    /// also interrupted, so it is logged and answered, never thrown into the stop or quit path.
    @discardableResult
    static func write(_ values: Values, forFinal final: URL) -> Bool {
        var payload: [String: Any] = [
            "schema_version": schemaVersion,
            "system_head_offset_sec": values.systemHeadOffsetSec,
        ]
        if let limit = values.limitSeconds { payload["limit_sec"] = limit }
        if let span = values.spanSec { payload["span_sec"] = span }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url(forFinal: final), options: .atomic)
            return true
        } catch {
            Log.writeLine("recorder", "WARN: could not write merge placement for \(final.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    /// A file that does not parse, or carries a non-finite or negative value, is `unreadable`;
    /// recovery treats it as absent (offset 0, no cut), which is today's behaviour, and says so.
    static func load(forFinal final: URL) -> LoadResult {
        let url = url(forFinal: final)
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard
            let data = try? Data(contentsOf: url),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let offset = number(obj["system_head_offset_sec"]), offset >= 0
        else { return .unreadable }
        var values = Values(systemHeadOffsetSec: offset)
        if let raw = obj["limit_sec"] {
            guard let limit = number(raw), limit > 0 else { return .unreadable }
            values.limitSeconds = limit
        }
        if let raw = obj["span_sec"] {
            guard let span = number(raw), span >= 0 else { return .unreadable }
            values.spanSec = span
        }
        return .loaded(values)
    }

    static func remove(forFinal final: URL) {
        try? FileManager.default.removeItem(at: url(forFinal: final))
    }

    /// A finite JSON number, never a boolean (JSONSerialization hands back NSNumber for both).
    private static func number(_ raw: Any?) -> Double? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let value = n.doubleValue
        return value.isFinite ? value : nil
    }
}
