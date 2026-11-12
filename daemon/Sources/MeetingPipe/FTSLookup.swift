import Foundation
import MeetingPipeCore

/// The one path from a search surface to the FTS index (PERF20): the Library filter bar, the rail's
/// smart-folder counts and Quick Find each own one. Before this every keystroke ran an un-debounced,
/// bm25-ranked prefix query through `SearchIndex`'s `queue.sync` on main, so typing during a rebuild
/// waited behind whichever write was running.
///
/// A `resolve` runs the lookups off main and delivers on main, latest wins: a later `resolve` cancels
/// a pending debounce and makes any result still in flight for an earlier one undeliverable, so a
/// result computed for a superseded query is never applied. A query `SearchQuery.indexMatch` would
/// not send to the index (empty, or one character) needs no lookup at all; when nothing in the call
/// needs one, the delivery is synchronous, so clearing a search box is immediate.
///
/// Main-confined, like the views and models that own it. The scheduler, the background executor and
/// the main hop are injected so the tests drive every case without real time.
final class FTSLookup {

    /// The free-text debounce shared by the Library filter bar and Quick Find. Inside the spec's
    /// 150 to 250 ms band: long enough that a word typed at speed issues one lookup, short enough
    /// that the list settles while the hands are still on the keys.
    static let debounce: TimeInterval = 0.2

    /// Stems per query, for the queries that reached the index and answered. A query absent from
    /// the map means "no FTS constraint": the caller falls back to the in-memory corpus.
    typealias Results = [String: Set<String>]

    /// `(delay, action) -> cancel`, the `Schedulers.mainRunLoopOnce` shape.
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void
    typealias Executor = (@escaping () -> Void) -> Void

    /// Shared by every instance: lookups are short, and a serial queue keeps two surfaces from
    /// contending for the one `SearchIndex` connection at once. Never the indexer's own queue, or a
    /// lookup would wait behind a whole rebuild instead of one write batch.
    static let lookupQueue = DispatchQueue(label: "MeetingPipe.FTSLookup", qos: .userInitiated)

    private let lookup: (String) -> Set<String>?
    private let delay: TimeInterval
    private let schedule: Scheduler
    private let runOffMain: Executor
    private let deliverOnMain: Executor

    private var generation = 0
    private var cancelPending: (() -> Void)?

    /// - Parameters:
    ///   - schedule: the debounce timer. `Schedulers.mainRunLoopOnce` by default, which stays live
    ///     while a menu is open or an alert is up (CONC10).
    ///   - lookup: query to stems, or nil for no constraint. Runs on `runOffMain`'s thread.
    init(
        delay: TimeInterval = FTSLookup.debounce,
        schedule: @escaping Scheduler = Schedulers.mainRunLoopOnce,
        runOffMain: @escaping Executor = { work in FTSLookup.lookupQueue.async { work() } },
        deliverOnMain: @escaping Executor = { work in DispatchQueue.main.async { work() } },
        lookup: @escaping (String) -> Set<String>?
    ) {
        self.delay = delay
        self.schedule = schedule
        self.runOffMain = runOffMain
        self.deliverOnMain = deliverOnMain
        self.lookup = lookup
    }

    /// Resolve `queries` and hand the results to `deliver` on main, unless a later `resolve`
    /// supersedes this one first. `debounced` waits `delay` before looking anything up; a later
    /// call inside the window replaces this one, so a burst of keystrokes issues one lookup.
    func resolve(_ queries: [String], debounced: Bool, deliver: @escaping (Results) -> Void) {
        generation &+= 1
        let ticket = generation
        cancelPending?()
        cancelPending = nil

        var seen = Set<String>()
        let needed = queries.filter { SearchQuery.indexMatch($0) != nil && seen.insert($0).inserted }
        guard !needed.isEmpty else {
            deliver([:])
            return
        }

        let start: () -> Void = { [weak self] in
            guard let self else { return }
            self.cancelPending = nil
            let lookup = self.lookup
            self.runOffMain {
                var results: Results = [:]
                for query in needed {
                    if let stems = lookup(query) { results[query] = stems }
                }
                self.deliverOnMain {
                    guard ticket == self.generation else { return }
                    deliver(results)
                }
            }
        }
        if debounced {
            cancelPending = schedule(delay, start)
        } else {
            start()
        }
    }

    /// Drop any pending or in-flight resolve without delivering it.
    func cancel() {
        generation &+= 1
        cancelPending?()
        cancelPending = nil
    }
}
