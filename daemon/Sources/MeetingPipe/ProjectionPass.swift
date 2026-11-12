import Foundation

/// One projection's off-main pass over the library, latest wins (PERF23).
///
/// Facts, People and Meeting time each re-read the library on every `MeetingStore.revision`. Before
/// this they spawned a `Task.detached` per revision, kept no handle, and applied whichever pass
/// finished last, so a burst of revisions (several per pipeline run, one per local edit) ran N full
/// passes at once and an older snapshot could land last as a stale list or badge.
///
/// `start` cancels the pass in flight and bumps a generation; a pass delivers to `apply` only while
/// its generation is still the current one, so a superseded pass can never overwrite a newer one,
/// whatever order they finish in. The loaders check `Task.isCancelled` between meetings, so a
/// superseded pass also stops reading. `FTSLookup`'s ticket is the in-repo template; this one holds a
/// `Task` instead of a GCD hop because the loaders are what has to notice the cancellation.
///
/// `keep` runs for **every** pass that finishes, superseded or not, before the generation check. It is
/// for content-keyed caches, whose entries are true whichever pass measured them: a revision burst
/// during a cold pass cancels it before it completes, and a cache written back only on completion
/// would then restart from nothing on every bump and never finish.
///
/// Main-confined. The work closure is `async` so a test can hold a pass on a continuation rather than
/// blocking a cooperative-pool thread (CI8).
@MainActor
final class ProjectionPass<Output: Sendable> {

    private var task: Task<Void, Never>?
    private(set) var generation = 0

    nonisolated init() {}

    /// Start a pass, superseding any pass in flight. Returns the pass's task so a test can await it.
    @discardableResult
    func start(
        work: @escaping @Sendable () async -> Output,
        keep: (@MainActor (Output) -> Void)? = nil,
        apply: @escaping @MainActor (Output) -> Void
    ) -> Task<Void, Never> {
        task?.cancel()
        generation &+= 1
        let ticket = generation
        let pass = Task.detached(priority: .userInitiated) { [weak self] in
            let output = await work()
            await self?.deliver(output, ticket: ticket, keep: keep, apply: apply)
        }
        task = pass
        return pass
    }

    private func deliver(
        _ output: Output,
        ticket: Int,
        keep: (@MainActor (Output) -> Void)?,
        apply: @MainActor (Output) -> Void
    ) {
        keep?(output)
        guard ticket == generation else { return }
        apply(output)
    }

    /// Cancel the pass in flight without delivering it. Its `keep` still runs if it finishes.
    func cancel() {
        task?.cancel()
        task = nil
        generation &+= 1
    }
}

/// A per-stem value derived from files on disk, valid only while those files' modification dates
/// are the ones it was computed from (PERF23). The stamp is taken **before** the read, so a write that
/// lands mid-read leaves an entry that the next pass sees as stale rather than one pinned as fresh.
///
/// In memory only: these are projections the views rebuild in a few hundred milliseconds from warm
/// caches, not measurements worth a file under `~/Library/Caches` (`MeetingDurationCache` is the one
/// that is). A failed read is never stored, because an iCloud placeholder materializing changes no
/// mtime (SEC25) and a stored failure would then be pinned for the life of the process.
struct StemFileCache<Value> {

    /// The files' modification dates in a fixed order, nil for a file that is not there.
    typealias Stamp = [Date?]

    struct Entry {
        let stamp: Stamp
        let value: Value
    }

    private(set) var entries: [String: Entry] = [:]

    init() {}

    /// The stored value for `stem`, only when its files are the ones it was computed from.
    func value(for stem: String, stamp: Stamp) -> Value? {
        guard let entry = entries[stem], entry.stamp == stamp else { return nil }
        return entry.value
    }

    mutating func set(_ value: Value, for stem: String, stamp: Stamp) {
        entries[stem] = Entry(stamp: stamp, value: value)
    }

    /// Fold in what another pass measured. Its entries are as true as ours (each carries its own
    /// stamp), so the incoming one wins; a pass that read an older file leaves an entry the next
    /// lookup treats as stale.
    mutating func merge(_ other: StemFileCache<Value>) {
        entries.merge(other.entries) { _, incoming in incoming }
    }

    /// Drop every stem not in `live`, so a deleted meeting does not hold memory for the life of the
    /// process. Called with the full row set of a pass that completed.
    mutating func prune(keeping live: Set<String>) {
        entries = entries.filter { live.contains($0.key) }
    }

    /// Modification dates of `urls`, in order. A file that is not there is nil, which is itself a
    /// state worth keying on: undoing a naming deletes the overlay sidecar.
    static func stamp(_ urls: [URL]) -> Stamp {
        urls.map { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }
}

extension StemFileCache: Sendable where Value: Sendable {}
extension StemFileCache.Entry: Sendable where Value: Sendable {}
