import Foundation

/// T13: wait on a condition, never on a yield count. A count is a guess at how many hops the work
/// under test takes; it passes while the guess holds and fails, or passes vacuously, when an `await`
/// is added or the cooperative pool's width changes. This polls `condition` with `Task.yield()` and
/// a short sleep until it holds or `timeout` passes, and says which. The deadline is generous on
/// purpose: a busy Mac running parallel suites stalls far longer than a test means to wait.
///
/// Not `@discardableResult`: a caller that ignores the answer has asserted nothing.
@MainActor
public func waitUntil(timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if condition() { return true }
        if Date() >= deadline { return false }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// T13: the one sanctioned bounded runway, for **absence** assertions only ("this did not happen"),
/// where there is no condition to wait on. Yields and drains main several times. Anything waiting for
/// something to happen uses `waitUntil` instead.
@MainActor
public func yieldRunway() async {
    for _ in 0..<20 {
        await Task.yield()
        await drainMain()
    }
}

/// T13: run everything already queued on the main queue, then return. Async, so the caller's own
/// main-actor work is not blocked while the queue drains.
@MainActor
public func drainMain() async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { done.resume() }
    }
}

/// T13: the synchronous form of `drainMain`, for a sync test already on the main thread: spins the
/// main run loop until a block queued now has run. Deterministic (it waits for the block, not for a
/// time), and false only if main stayed blocked past `timeout`, which the caller asserts.
public func drainMainSync(timeout: TimeInterval = 10) -> Bool {
    precondition(Thread.isMainThread, "drainMainSync spins the main run loop, so it must run on main")
    var done = false
    DispatchQueue.main.async { done = true }
    let deadline = Date().addingTimeInterval(timeout)
    while !done, Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return done
}
