import Foundation

/// The 500 ms debounced save that `ConfigStore`, `GlossaryStore` and `SecretsStore` each hand-copied (CONC8).
/// It owns the skeleton and nothing else: the hop to main, the re-armed `Timer`, a private serial utility
/// queue the work runs on, and `flush()` / `performNow(_:)` for a save that cannot wait.
///
/// A store keeps its own policy. `prepare` runs **on main** when the timer fires: it snapshots the
/// published state and returns the work to run (or `nil` to skip, which is how a gate is expressed).
/// The work runs on `queue`, never on main, and `completion` reports the outcome back on main. Saves are
/// serial, so a later snapshot never lands before an earlier one, and `performNow` goes through the same
/// queue, so no two writers ever use a store's `.writing` temp file at once.
final class DebouncedSaver {
    typealias Work = () throws -> Void

    private let interval: TimeInterval
    private let queue: DispatchQueue
    private let prepare: () -> Work?
    private let completion: (Result<Void, Error>) -> Void
    /// Main-confined.
    private var timer: Timer?

    init(
        interval: TimeInterval = 0.5,
        queue: DispatchQueue,
        prepare: @escaping () -> Work?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        self.interval = interval
        self.queue = queue
        self.prepare = prepare
        self.completion = completion
    }

    /// A private serial utility queue named for its store.
    static func makeQueue(label: String) -> DispatchQueue {
        DispatchQueue(label: label, qos: .utility)
    }

    /// Debounce: (re)arm the timer. Safe from any thread; a background caller hops to main first, because a
    /// `Timer` needs a run loop.
    func schedule() {
        guard Thread.current.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.schedule() }
            return
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.fire()
        }
    }

    private func fire() {
        timer = nil
        guard let work = prepare() else { return }
        queue.async { [completion] in
            let result = Result { try work() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Cancel a pending timer and save now, synchronously. Main only. A save already queued runs first.
    func flush() {
        timer?.invalidate()
        timer = nil
        guard let work = prepare() else { return }
        completion(Result { try queue.sync(execute: work) })
    }

    /// Run `work` now on the saver's queue and wait for it, so an explicit save (an Apply button, a test)
    /// is ordered behind any save already in flight. Cancels a pending timer, which this supersedes.
    func performNow(_ work: Work) throws {
        timer?.invalidate()
        timer = nil
        try queue.sync(execute: work)
    }
}
