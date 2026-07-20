import Foundation

/// Reversible speaker-label overrides in `<stem>.speaker_labels.json` (FEAT3-UNDO).
///
/// In-app speaker naming used to rewrite `<stem>.json` in place (baking the roster
/// name over the diarization label), which made it a one-way door: the original
/// `THEM-A` label was lost and there was no in-app undo. This store parallels
/// `TranscriptCorrectionStore` for speaker labels: the daemon enrolls the voiceprint
/// (`mp roster enroll --no-relabel`) but leaves `<stem>.json` untouched and records
/// the assigned name here, resolved at load time. Undo just drops the override, so
/// the diarization label always survives on disk.
///
/// Schema: `{ "schema_version": 1, "labels": { "THEM-A": "Alice" }, "segments": { "42": "Bob" } }`.
///   - `labels` maps a raw diarization cluster label to the whole-cluster name
///     (FEAT3-UNDO's "Name this speaker").
///   - `segments` maps a zero-based segment index (matching `TranscriptSegment.index`)
///     to a per-segment override that wins over the cluster (FEAT3-SEGMENT's
///     "Reassign to..."). The value is a raw label or a name; display resolves it
///     through `TranscriptDisplay.displayName`.
enum SpeakerLabelStore {

    /// Sidecar shape version (CI4). This was the one cross-language sidecar with
    /// no stamp. Both readers are fail-open on it (an unknown value is ignored,
    /// not rejected), matching `TranscriptCorrectionStore`; it exists so a future
    /// shape change is diagnosable from the file rather than inferred.
    static let schemaVersion = 1

    /// The parsed overlay. Empty maps read as "no overrides", so a missing or
    /// malformed sidecar never hides the transcript's own labels.
    struct Overlay: Equatable {
        var labels: [String: String]
        var segments: [Int: String]

        static let empty = Overlay(labels: [:], segments: [:])
        var isEmpty: Bool { labels.isEmpty && segments.isEmpty }
    }

    enum WriteError: Swift.Error, LocalizedError {
        case serializationFailed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .serializationFailed(let s): return "Couldn't serialize speaker labels: \(s)"
            case .writeFailed(let s):         return "Couldn't write speaker labels: \(s)"
            }
        }
    }

    static func path(stem: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(stem).speaker_labels.json")
    }

    /// Reads the overlay. Returns `.empty` for a missing or malformed sidecar.
    static func read(stem: String, in directory: URL) -> Overlay {
        let url = path(stem: stem, in: directory)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }
        var labels: [String: String] = [:]
        if let raw = obj["labels"] as? [String: Any] {
            for (k, v) in raw where !k.isEmpty {
                if let s = v as? String, !s.isEmpty { labels[k] = s }
            }
        }
        var segments: [Int: String] = [:]
        if let raw = obj["segments"] as? [String: Any] {
            for (k, v) in raw {
                if let idx = Int(k), let s = v as? String, !s.isEmpty { segments[idx] = s }
            }
        }
        return Overlay(labels: labels, segments: segments)
    }

    // MARK: - Cluster-level naming (FEAT3-UNDO)

    /// Assign the whole `label` cluster the display name `name`. Overwrites any
    /// prior name for that cluster.
    @discardableResult
    static func setLabel(_ label: String, to name: String, stem: String, in directory: URL) throws -> Overlay {
        var overlay = read(stem: stem, in: directory)
        overlay.labels[label] = name
        try write(overlay: overlay, stem: stem, in: directory)
        return overlay
    }

    /// Drop the name override for `label`, reverting the cluster to its diarization
    /// label. The undo half of FEAT3-UNDO.
    @discardableResult
    static func removeLabel(_ label: String, stem: String, in directory: URL) throws -> Overlay {
        var overlay = read(stem: stem, in: directory)
        overlay.labels.removeValue(forKey: label)
        try write(overlay: overlay, stem: stem, in: directory)
        return overlay
    }

    // MARK: - Per-segment reassignment (FEAT3-SEGMENT)

    /// Override a single segment's speaker (wins over its cluster's label). The
    /// per-segment reassignment FEAT3-SEGMENT rides on this same overlay.
    @discardableResult
    static func setSegment(_ index: Int, to target: String, stem: String, in directory: URL) throws -> Overlay {
        var overlay = read(stem: stem, in: directory)
        overlay.segments[index] = target
        try write(overlay: overlay, stem: stem, in: directory)
        return overlay
    }

    @discardableResult
    static func removeSegment(_ index: Int, stem: String, in directory: URL) throws -> Overlay {
        var overlay = read(stem: stem, in: directory)
        overlay.segments.removeValue(forKey: index)
        try write(overlay: overlay, stem: stem, in: directory)
        return overlay
    }

    /// Reassign a batch of segments to `target` in one write (multi-select).
    @discardableResult
    static func setSegments(_ indices: [Int], to target: String, stem: String, in directory: URL) throws -> Overlay {
        var overlay = read(stem: stem, in: directory)
        for i in indices { overlay.segments[i] = target }
        try write(overlay: overlay, stem: stem, in: directory)
        return overlay
    }

    /// Drop the per-segment overrides for a batch, reverting each to its cluster.
    @discardableResult
    static func removeSegments(_ indices: [Int], stem: String, in directory: URL) throws -> Overlay {
        var overlay = read(stem: stem, in: directory)
        for i in indices { overlay.segments.removeValue(forKey: i) }
        try write(overlay: overlay, stem: stem, in: directory)
        return overlay
    }

    // MARK: - Resolution (pure, no I/O)

    /// The label to render for a segment: the per-segment reassignment if any, else
    /// the raw diarization label, mapped through the cluster-name table. So a segment
    /// reassigned to a named cluster shows that cluster's name, and an un-reassigned
    /// segment shows its cluster's name when named. Matches the Python
    /// `speaker_overlay.apply_overlay` resolution (the two must agree). Feed the
    /// result to `TranscriptDisplay.displayName`.
    static func displayLabel(for segment: TranscriptSegment, using overlay: Overlay) -> String? {
        guard let base = overlay.segments[segment.index] ?? segment.speakerID else { return nil }
        return overlay.labels[base] ?? base
    }

    /// The user-assigned override for a segment (a per-segment reassignment or a
    /// cluster name), or nil when the segment carries its plain diarization label. A
    /// per-segment override (FEAT3-SEGMENT) wins over the cluster name (FEAT3-UNDO).
    /// The signal the row uses to show a name and to branch the context menu.
    static func assignedLabel(for segment: TranscriptSegment, using overlay: Overlay) -> String? {
        if overlay.segments[segment.index] != nil {
            return displayLabel(for: segment, using: overlay)
        }
        if let raw = segment.speakerID, let name = overlay.labels[raw] {
            return name
        }
        return nil
    }

    // MARK: - Internal

    /// Atomic temp-file + rename. An empty overlay deletes the sidecar, so the next
    /// load reads as "no overrides" (matching `TranscriptCorrectionStore`).
    private static func write(overlay: Overlay, stem: String, in directory: URL) throws {
        let url = path(stem: stem, in: directory)
        let fm = FileManager.default
        if overlay.isEmpty {
            if fm.fileExists(atPath: url.path) {
                do { try fm.removeItem(at: url) }
                catch { throw WriteError.writeFailed(error.localizedDescription) }
            }
            return
        }
        var payload: [String: Any] = ["schema_version": Self.schemaVersion]
        if !overlay.labels.isEmpty { payload["labels"] = overlay.labels }
        if !overlay.segments.isEmpty {
            payload["segments"] = Dictionary(uniqueKeysWithValues: overlay.segments.map { (String($0.key), $0.value) })
        }
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
