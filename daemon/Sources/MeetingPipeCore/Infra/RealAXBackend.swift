import ApplicationServices
import Foundation

/// Production backend for `AXObserverBus`. Caches one `AXObserver` per PID so a single AX-tree walk satisfies lifecycle + gate consumers (TECH-C13 "walked exactly once per meeting"). Run-loop source is pinned to the main runloop because AXObserver requires a runloop and handlers need to fire where AppKit/SwiftUI subscribers can act without a hop; the bus adds a defensive `DispatchQueue.main.async` on top but pinning here keeps the source live. Observer is discarded when handler count reaches zero.
public final class RealAXBackend: AXObserverBus.Backend {

    /// The AX and run-loop calls this backend makes (PERF16), so a test can fail an add or kill a PID without a live client or Accessibility trust. The observer is opaque here; `live` is the only place it is an `AXObserver`.
    struct Calls {
        var createObserver: (pid_t) -> (AXError, AnyObject?)
        var addNotification: (AnyObject, AXUIElement, CFString, UnsafeMutableRawPointer) -> AXError
        var removeNotification: (AnyObject, AXUIElement, CFString) -> Void
        var addSource: (AnyObject) -> Void
        var removeSource: (AnyObject) -> Void
        var isAlive: (pid_t) -> Bool

        static var live: Calls {
            Calls(
                createObserver: { pid in
                    var observer: AXObserver?
                    let err = AXObserverCreate(pid, AXBackendCallback, &observer)
                    return (err, observer)
                },
                addNotification: { observer, element, notification, userInfo in
                    AXObserverAddNotification(observer as! AXObserver, element, notification, userInfo)
                },
                removeNotification: { observer, element, notification in
                    _ = AXObserverRemoveNotification(observer as! AXObserver, element, notification)
                },
                addSource: { observer in
                    let source = AXObserverGetRunLoopSource(observer as! AXObserver)
                    CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
                },
                removeSource: { observer in
                    let source = AXObserverGetRunLoopSource(observer as! AXObserver)
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
                },
                isAlive: RealAXBackend.processIsAlive
            )
        }
    }

    private final class ObserverEntry {
        let observer: AnyObject
        /// Live handlers plus registrations in flight: `obtainObserver` reserves a slot
        /// under the lock, so no concurrent release can discard an entry mid-add.
        var handlerCount: Int = 0
        /// False once the run-loop source is off the main run loop, so it comes off once.
        var sourceAttached = true
        /// CONC6: the entry owns every handler box registered on its observer, so none is freed while a
        /// callback on main (which runs from this observer's source) can still be using it. Freed, on
        /// main, when the entry is discarded and its source is off the run loop. A torn-down handler's
        /// box stays until then, with `cancel()` set so a late callback does nothing; the entry is
        /// discarded the moment its last handler goes (every meeting end), which bounds the growth.
        var boxes: [HandlerBox] = []
        init(observer: AnyObject) { self.observer = observer }
    }

    private let calls: Calls
    private let lock = NSLock()
    private var observersByPID: [pid_t: ObserverEntry] = [:]

    public convenience init() {
        self.init(calls: .live)
    }

    init(calls: Calls) {
        self.calls = calls
    }

    /// Only `ESRCH` means the process is gone; `EPERM` is a live process this one may not signal.
    static func processIsAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    /// Cached observers, for tests.
    var cachedObserverCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return observersByPID.count
    }

    public func register(
        pid: pid_t,
        element: AXUIElement,
        notification: String,
        handler: @escaping () -> Void
    ) throws -> () -> Void {
        let entry = try obtainObserver(for: pid)
        let handlerBox = HandlerBox(handler: handler)
        lock.lock(); entry.boxes.append(handlerBox); lock.unlock()
        // Unretained: the entry's `boxes` is the owner (CONC6), so the C callback can never be handed a
        // box a teardown on another thread has already released.
        let userInfo = Unmanaged.passUnretained(handlerBox).toOpaque()

        let addErr = calls.addNotification(entry.observer, element, notification as CFString, userInfo)
        guard addErr == .success else {
            handlerBox.cancel()
            // PERF16: give back the slot `obtainObserver` reserved. Before this, a
            // failed first add left the observer cached and its source on the main
            // run loop until a later register/unregister cycle for the same PID.
            releaseObserver(entry, pid: pid)
            throw AXObserverBus.BusError.backendFailed(addErr)
        }

        let calls = self.calls
        return { [weak self] in
            calls.removeNotification(entry.observer, element, notification as CFString)
            // A notification already queued on the observer can still be delivered after the removal;
            // it finds a cancelled box, which is alive until the entry goes.
            handlerBox.cancel()
            self?.releaseObserver(entry, pid: pid)
        }
    }

    /// The cached observer for `pid` with one handler slot reserved, created if absent.
    /// An entry whose PID is gone is replaced rather than reused (PERF16): PIDs change
    /// on every client restart, and a reused one would be handed a stale observer
    /// whose registrations fail.
    private func obtainObserver(for pid: pid_t) throws -> ObserverEntry {
        lock.lock()
        defer { lock.unlock() }
        if let existing = observersByPID[pid] {
            if calls.isAlive(pid) {
                existing.handlerCount += 1
                return existing
            }
            detachSource(existing)
            observersByPID.removeValue(forKey: pid)
        }
        let (createErr, created) = calls.createObserver(pid)
        guard createErr == .success, let observer = created else {
            throw AXObserverBus.BusError.backendFailed(createErr)
        }
        calls.addSource(observer)
        let entry = ObserverEntry(observer: observer)
        entry.handlerCount = 1
        observersByPID[pid] = entry
        return entry
    }

    /// Give back one handler slot on `entry`, discarding it once unused. Shared by a
    /// teardown and a failed add. Acts on the entry the caller holds, never on
    /// whatever is cached for the PID now, so a replaced entry's late teardown cannot
    /// release its successor.
    private func releaseObserver(_ entry: ObserverEntry, pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        entry.handlerCount -= 1
        guard entry.handlerCount <= 0 else { return }
        detachSource(entry)
        if observersByPID[pid] === entry {
            observersByPID.removeValue(forKey: pid)
        }
    }

    /// Caller holds `lock`.
    private func detachSource(_ entry: ObserverEntry) {
        guard entry.sourceAttached else { return }
        entry.sourceAttached = false
        calls.removeSource(entry.observer)
        // The source is off the run loop, so no new callback starts. One already running on main holds
        // the main queue, so a release hopped onto it runs after that callback returns (CONC6).
        let boxes = entry.boxes
        entry.boxes = []
        DispatchQueue.main.async { withExtendedLifetime(boxes) {} }
    }
}

/// AXObserver callback (C function pointer required). Per-handler closure is stored in a `HandlerBox` owned by its `ObserverEntry` (CONC6) and passed unretained as `userInfo`; the callback unboxes it and invokes it unless a teardown cancelled it.
private func AXBackendCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo = userInfo else { return }
    let box = Unmanaged<HandlerBox>.fromOpaque(userInfo).takeUnretainedValue()
    box.fire()
}

private final class HandlerBox {
    private let handler: () -> Void
    /// Set by a teardown (any thread), read by the callback on main.
    private let cancelled = NSLock()
    private var isCancelled = false

    init(handler: @escaping () -> Void) { self.handler = handler }

    func cancel() {
        cancelled.lock(); isCancelled = true; cancelled.unlock()
    }

    func fire() {
        cancelled.lock(); let live = !isCancelled; cancelled.unlock()
        if live { handler() }
    }
}
