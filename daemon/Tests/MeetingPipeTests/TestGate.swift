import Foundation

/// A suspension only the test ends (PIPE36). It parks on a continuation rather than blocking a
/// thread, because `ci-local.sh` runs the suites on a one-thread cooperative pool and a blocked
/// thread would wedge every later async test. It ignores cancellation on purpose: that is the
/// wedged-framework shape the deadlines and ceilings exist for. Open every gate a test made
/// before it ends, so no parked continuation outlives it.
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}
