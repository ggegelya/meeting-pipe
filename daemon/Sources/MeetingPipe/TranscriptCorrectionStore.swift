import Foundation

/// Per-line transcript corrections in `<stem>.transcript_corrections.json`. Keeps user edits separate from the pipeline's `<stem>.json` so re-transcription doesn't trample them; the sidecar overlays pipeline output at load time.
///
/// Schema: `{ "schema_version": 1, "segments": [{ "index": 3, "original_text": "...", "edited_text": "..." }, ...] }`. `index` is zero-based, matching `TranscriptSegment.index`. `original_text` is the pipeline snapshot at edit time, and both readers check it (ASR12): an entry applies only while the segment still reads that text, so an index that now points at a different sentence is skipped rather than laid over it. A skipped entry stays in the file for a later carry to recover.
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

    /// Reads corrections keyed by segment index. Returns empty for a missing or malformed sidecar so the transcript itself is never hidden. Display-only: a writer goes through `loadForWrite` (STOR9).
    static func read(stem: String, in directory: URL) -> [Int: Correction] {
        load(stem: stem, in: directory).orEmpty([:])
    }

    /// The typed read (STOR9). A top level that is not a JSON object is unparseable, as in Python's
    /// `storage.load_json_object`; an object without a usable `segments` array reads as no corrections.
    static func load(stem: String, in directory: URL) -> StoreLoad<[Int: Correction]> {
        StoreLoad.read(path(stem: stem, in: directory)) { data in
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw StoreShapeError(why: "the transcript corrections file is not a JSON object")
            }
            var out: [Int: Correction] = [:]
            for raw in obj["segments"] as? [[String: Any]] ?? [] {
                guard let idx = (raw["index"] as? NSNumber)?.intValue,
                      let original = raw["original_text"] as? String,
                      let edited = raw["edited_text"] as? String else {
                    continue
                }
                out[idx] = Correction(segmentIndex: idx, originalText: original, editedText: edited)
            }
            return out
        }
    }

    /// What every writer here starts from (STOR9): refuse an unreadable sidecar, quarantine an
    /// unparseable one, so an edit never saves an empty-plus-one state over the owner's corrections.
    static func loadForWrite(stem: String, in directory: URL) throws -> [Int: Correction] {
        try StoreGuard.valueForWrite(
            load(stem: stem, in: directory), empty: [:],
            url: path(stem: stem, in: directory), store: "transcript_corrections", pathKind: .library
        )
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
        var existing = try loadForWrite(stem: stem, in: directory)
        // `pipelineOriginal` is the line as the tab shows it: the prior edit when that entry is
        // live, the pipeline's text when `apply` skipped it as drifted (ASR12). Keeping a drifted
        // entry's stale snapshot would save the new edit and skip it on every load after.
        let prior = existing[segmentIndex]
        let priorIsLive = prior.map { $0.editedText == pipelineOriginal || $0.originalText == pipelineOriginal } ?? false
        let resolvedOriginal = priorIsLive ? (prior?.originalText ?? pipelineOriginal) : pipelineOriginal
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
        var existing = try loadForWrite(stem: stem, in: directory)
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
        // STOR9: the caller computed the set from the fail-open read, so the file is checked here.
        _ = try loadForWrite(stem: stem, in: directory)
        try write(corrections: corrections, stem: stem, in: directory)
    }

    /// Overlays corrections onto segments in-place. Pure, no I/O.
    static func apply(
        corrections: [Int: Correction],
        to segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        applyCounting(corrections: corrections, to: segments).segments
    }

    /// Whether a correction still describes this segment (ASR12's drift check): its snapshot is
    /// the text the pipeline wrote there. `seg.text` is `TranscriptLoader.parse`'s trimmed text,
    /// and `mp.transcript_corrections.is_live` trims the same way, so the trees agree.
    static func isLive(_ c: Correction, on seg: TranscriptSegment) -> Bool {
        c.originalText == seg.text
    }

    /// `apply`, plus how many entries were skipped because their segment drifted (ASR12). The
    /// Transcript tab says so when the count is above zero; nothing is deleted.
    static func applyCounting(
        corrections: [Int: Correction],
        to segments: [TranscriptSegment]
    ) -> (segments: [TranscriptSegment], drifted: Int) {
        guard !corrections.isEmpty else { return (segments, 0) }
        var drifted = 0
        let out = segments.map { seg -> TranscriptSegment in
            guard let c = corrections[seg.index] else { return seg }
            guard isLive(c, on: seg) else {
                drifted += 1
                return seg
            }
            if c.editedText != seg.text {
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
        return (out, drifted)
    }

    // MARK: - Internal

    /// Atomic replacement, so a crash leaves either the previous file or the new one and never
    /// neither (PERF8; the shape this replaced claimed crash safety and did not have it). An empty
    /// dict deletes the sidecar so the next load reads as "no corrections".
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
            try data.write(to: url, options: .atomic)
        } catch {
            throw WriteError.writeFailed(error.localizedDescription)
        }
    }
}
