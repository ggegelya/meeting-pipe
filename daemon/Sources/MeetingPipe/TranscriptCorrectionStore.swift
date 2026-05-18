import Foundation

/// Per-line transcript corrections persisted as a sidecar next to the
/// recording. The store keeps the user's edits separate from the
/// pipeline's `<stem>.json` so a re-transcribe (or a future FluidAudio
/// rerun) doesn't trample the user's words; the sidecar overlays the
/// pipeline output at load time.
///
/// File: `<stem>.transcript_corrections.json`, shape:
/// ```json
/// {
///   "segments": [
///     { "index": 3, "original_text": "...", "edited_text": "..." },
///     ...
///   ]
/// }
/// ```
/// `index` matches `TranscriptSegment.index` (the segment's position in
/// the source JSON, zero-based). `original_text` is the snapshot of the
/// pipeline output at edit time; if the pipeline rewrites the file
/// later, a downstream tool can diff against the original to detect
/// drift.
enum TranscriptCorrectionStore {

    struct Correction: Equatable {
        let segmentIndex: Int
        let originalText: String
        let editedText: String
    }

    enum WriteError: Swift.Error, LocalizedError {
        case serializationFailed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .serializationFailed(let s): return "Couldn't serialize corrections: \(s)"
            case .writeFailed(let s):         return "Couldn't write corrections: \(s)"
            }
        }
    }

    /// Sidecar URL for a given stem.
    static func path(stem: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(stem).transcript_corrections.json")
    }

    /// Read all corrections keyed by segment index. Returns an empty
    /// dict for a missing or malformed sidecar; an unreadable sidecar
    /// shouldn't hide the transcript itself.
    static func read(stem: String, in directory: URL) -> [Int: Correction] {
        let url = path(stem: stem, in: directory)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["segments"] as? [[String: Any]] else {
            return [:]
        }
        var out: [Int: Correction] = [:]
        for raw in arr {
            guard let idx = (raw["index"] as? NSNumber)?.intValue,
                  let original = raw["original_text"] as? String,
                  let edited = raw["edited_text"] as? String else {
                continue
            }
            out[idx] = Correction(
                segmentIndex: idx,
                originalText: original,
                editedText: edited
            )
        }
        return out
    }

    /// Upsert a correction. `pipelineOriginal` is the text the caller
    /// sees right now (overlay-applied). If a correction already
    /// exists for this segment, the previously-stored `originalText`
    /// is preserved across re-edits so the pipeline-truth snapshot
    /// doesn't decay as the user keeps editing.
    ///
    /// When `edited` matches the resolved original the existing
    /// override is removed (no point persisting a no-op).
    @discardableResult
    static func upsert(
        segmentIndex: Int,
        pipelineOriginal: String,
        edited: String,
        stem: String,
        in directory: URL
    ) throws -> [Int: Correction] {
        var existing = read(stem: stem, in: directory)
        let resolvedOriginal = existing[segmentIndex]?.originalText ?? pipelineOriginal
        if edited == resolvedOriginal {
            existing.removeValue(forKey: segmentIndex)
        } else {
            existing[segmentIndex] = Correction(
                segmentIndex: segmentIndex,
                originalText: resolvedOriginal,
                editedText: edited
            )
        }
        try write(corrections: existing, stem: stem, in: directory)
        return existing
    }

    /// Drop the override for a single segment.
    @discardableResult
    static func remove(
        segmentIndex: Int,
        stem: String,
        in directory: URL
    ) throws -> [Int: Correction] {
        var existing = read(stem: stem, in: directory)
        existing.removeValue(forKey: segmentIndex)
        try write(corrections: existing, stem: stem, in: directory)
        return existing
    }

    /// Overlay corrections onto a list of segments. Pure: no I/O. The
    /// transcript stays sorted by index because each segment is mapped
    /// in place.
    static func apply(
        corrections: [Int: Correction],
        to segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        guard !corrections.isEmpty else { return segments }
        return segments.map { seg in
            if let c = corrections[seg.index], c.editedText != seg.text {
                return TranscriptSegment(
                    index: seg.index,
                    start: seg.start,
                    end: seg.end,
                    text: c.editedText,
                    speakerID: seg.speakerID
                )
            }
            return seg
        }
    }

    // MARK: - Internal

    /// Atomic temp-file + rename so a crash mid-write never leaves a
    /// half-formed JSON file. An empty dict deletes the sidecar so the
    /// next load reads as "no corrections" instead of an empty
    /// segments array.
    private static func write(
        corrections: [Int: Correction],
        stem: String,
        in directory: URL
    ) throws {
        let url = path(stem: stem, in: directory)
        let fm = FileManager.default
        if corrections.isEmpty {
            if fm.fileExists(atPath: url.path) {
                do { try fm.removeItem(at: url) }
                catch { throw WriteError.writeFailed(error.localizedDescription) }
            }
            return
        }
        let sortedItems = corrections.values
            .sorted { $0.segmentIndex < $1.segmentIndex }
            .map { c -> [String: Any] in
                [
                    "index": c.segmentIndex,
                    "original_text": c.originalText,
                    "edited_text": c.editedText,
                ]
            }
        let payload: [String: Any] = ["segments": sortedItems]
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw WriteError.serializationFailed("payload not JSON-serializable")
        }
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw WriteError.serializationFailed(error.localizedDescription)
        }
        let temp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: temp, options: .atomic)
            if fm.fileExists(atPath: url.path) {
                _ = try? fm.removeItem(at: url)
            }
            try fm.moveItem(at: temp, to: url)
        } catch {
            try? fm.removeItem(at: temp)
            throw WriteError.writeFailed(error.localizedDescription)
        }
    }
}
