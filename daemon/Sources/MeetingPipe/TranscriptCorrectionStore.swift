import Foundation

/// Per-line transcript corrections in `<stem>.transcript_corrections.json`. Keeps user edits separate from the pipeline's `<stem>.json` so re-transcription doesn't trample them; the sidecar overlays pipeline output at load time.
///
/// Schema: `{ "schema_version": 1, "segments": [{ "index": 3, "original_text": "...", "edited_text": "..." }, ...] }`. `index` is zero-based, matching `TranscriptSegment.index`. `original_text` is the pipeline snapshot at edit time so downstream tools can detect drift if the pipeline later rewrites the file.
///
/// This is a Swift-to-Python contract (PIPE9): the pipeline's `mp.transcript_corrections` reads the same sidecar so a regenerate / re-index reflects these edits. Both sides resolve by segment index and are pinned by a golden parity fixture (`Fixtures/transcript-corrections-golden.json`); a reader is fail-open, so `schema_version` is stamped but unknown values are ignored, not rejected.
enum TranscriptCorrectionStore {

    /// Sidecar shape version (PIPE9). Stamped on every write; bump when the key set or a key's meaning changes.
    static let schemaVersion = 1

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

    static func path(stem: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(stem).transcript_corrections.json")
    }

    /// Reads corrections keyed by segment index. Returns empty for a missing or malformed sidecar so the transcript itself is never hidden.
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

    /// Upserts a correction. Preserves the earliest `originalText` across re-edits so the pipeline-truth snapshot doesn't decay. Removes the override when `edited` matches the resolved original (no-op).
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

    /// Replace the whole set in one write. The per-key `upsert` / `remove` above
    /// are read-modify-write, so a caller that recomputed the set in one pure
    /// step (ASR3's re-transcribe carry, which re-anchors every correction onto
    /// a freshly-numbered transcript) would otherwise rewrite the file per entry
    /// and, worse, read a half-migrated set back on each pass. Mirrors
    /// `SpeakerLabelStore.replace`; empty deletes the sidecar.
    static func replace(
        _ corrections: [Int: Correction],
        stem: String,
        in directory: URL
    ) throws {
        try write(corrections: corrections, stem: stem, in: directory)
    }

    /// Overlays corrections onto segments in-place. Pure, no I/O.
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

    /// Atomic temp-file + rename so a crash never leaves a half-formed file. An empty dict deletes the sidecar so the next load reads as "no corrections".
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
        let payload: [String: Any] = [
            "schema_version": Self.schemaVersion,
            "segments": sortedItems,
        ]
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
