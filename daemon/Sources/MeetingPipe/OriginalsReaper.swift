import Foundation

/// Retention reaper for the kept full recordings under
/// `MuteRedactor.originalsDirectory()` (ADR 0016, MIC13). Those copies exist
/// only to recover from a wrong mute-redaction; the canonical redacted artifact
/// lives in `raw/` and is never touched here. ADR 0016 mandates a retention
/// policy and a reaper for them: they are sensitive at rest and otherwise grow
/// unbounded. This is the shared sweep STOR1 later extends to a second scope
/// (per-workflow `raw/` audio); MIC13 wires only the `originals/` scope.
///
/// Policy: reap a copy older than `maxAge`, and if the folder still exceeds
/// `maxTotalBytes`, reap oldest-first until it fits. Deletion is permanent
/// (`removeItem`, not the Trash): the goal is to reclaim disk, and these copies
/// are owner-only and backup-excluded, so parking them in the Trash would defeat
/// both. As a side benefit the sweep also clears copies that leaked before the
/// delete cascade existed.
enum OriginalsReaper {

    /// Keep a recovery copy this long, then reclaim it. A wrong redaction is
    /// noticed within days of reviewing the notes, so 30 days is a generous
    /// window. STOR1 makes this configurable; here it is a fixed default.
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    /// Ceiling on the whole originals folder (~10 GB, roughly 14 h of stereo
    /// audio). Past it, the oldest copies are reclaimed first regardless of age.
    static let maxTotalBytes: Int = 10 * 1024 * 1024 * 1024

    /// One kept recording, reduced to the facts the policy decides on.
    struct Candidate: Equatable {
        let url: URL
        let sizeBytes: Int
        let modified: Date
    }

    /// Pure policy: which candidates to reap. Age first (older than `maxAge`),
    /// then size (oldest-first among the survivors until the folder total is
    /// within `maxTotalBytes`). No filesystem access, so it is unit-testable
    /// with synthetic candidates.
    static func decideReap(
        candidates: [Candidate],
        now: Date,
        maxAge: TimeInterval = OriginalsReaper.maxAge,
        maxTotalBytes: Int = OriginalsReaper.maxTotalBytes
    ) -> [URL] {
        var reap: [URL] = []
        var survivors: [Candidate] = []
        for candidate in candidates {
            if now.timeIntervalSince(candidate.modified) > maxAge {
                reap.append(candidate.url)
            } else {
                survivors.append(candidate)
            }
        }
        var total = survivors.reduce(0) { $0 + $1.sizeBytes }
        if total > maxTotalBytes {
            // Oldest first, so the freshest recovery copies survive longest.
            for candidate in survivors.sorted(by: { $0.modified < $1.modified }) {
                if total <= maxTotalBytes { break }
                reap.append(candidate.url)
                total -= candidate.sizeBytes
            }
        }
        return reap
    }

    /// Enumerate the originals directory, apply the policy, and delete the
    /// reaped copies. Returns the number reclaimed; 0 when the directory is
    /// absent or nothing is past policy. Off-main callers only: this does
    /// blocking filesystem IO.
    @discardableResult
    static func sweep(
        in directory: URL = MuteRedactor.originalsDirectory(),
        now: Date = Date()
    ) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        let candidates: [Candidate] = entries.compactMap { url in
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            ),
                let size = values.fileSize,
                let modified = values.contentModificationDate
            else { return nil }
            return Candidate(url: url, sizeBytes: size, modified: modified)
        }
        let doomed = decideReap(candidates: candidates, now: now)
        guard !doomed.isEmpty else { return 0 }

        let sizeByURL = Dictionary(candidates.map { ($0.url, $0.sizeBytes) }, uniquingKeysWith: { first, _ in first })
        var reaped = 0
        var bytesFreed = 0
        for url in doomed {
            do {
                try fm.removeItem(at: url)
                reaped += 1
                bytesFreed += sizeByURL[url] ?? 0
            } catch {
                Log.writeLine("daemon", "WARN: could not reap kept original \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if reaped > 0 {
            Log.event(category: "coordinator", action: "originals_reaped", attributes: [
                "count": reaped,
                "bytes_freed": bytesFreed,
            ])
            Log.writeLine("daemon", "reaped \(reaped) kept original recording(s) past the retention window, freed \(bytesFreed / (1024 * 1024)) MB")
        }
        return reaped
    }
}
