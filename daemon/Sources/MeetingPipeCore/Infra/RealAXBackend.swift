import ApplicationServices
import Foundation

/// Production backend for `AXObserverBus`. Caches one `AXObserver` per
/// PID and multiplexes notification handlers off of it so a single
/// AX-tree walk satisfies the lifecycle + gate consumers, matching the
/// "AX tree walked exactly once per meeting" requirement in TECH-C13.
///
/// Threading: AXObserver requires a runloop. The backend pins each
/// observer's run-loop source to the *main* runloop so handlers fire
/// where AppKit / SwiftUI subscribers can act on them without a hop.
/// The bus itself adds a defensive `DispatchQueue.main.async` on top,
/// but pinning here keeps the underlying notification source live.
///
/// Each `register` returns a teardown that detaches the notification.
/// When the observer's handler count drops to zero, its run-loop
/// source is removed and the observer is discarded.
public final class RealAXBackend: AXObserverBus.Backend {

    private final class ObserverEntry {
        let observer: AXObserver
        var handlerCount: Int = 0
        init(observer: AXObserver) { self.observer = observer }
    }

    private let lock = NSLock()
    private var observersByPID: [pid_t: ObserverEntry] = [:]

    public init() {}

    public func register(
        pid: pid_t,
        element: AXUIElement,
        notification: String,
        handler: @escaping () -> Void
    ) throws -> () -> Void {
        let entry = try obtainObserver(for: pid)
        let handlerBox = HandlerBox(handler: handler)
        let userInfo = Unmanaged.passRetained(handlerBox).toOpaque()

        let addErr = AXObserverAddNotification(
            entry.observer,
            element,
            notification as CFString,
            userInfo
        )
        guard addErr == .success else {
            Unmanaged<HandlerBox>.fromOpaque(userInfo).release()
            throw AXObserverBus.BusError.backendFailed(addErr)
        }
        lock.lock()
        entry.handlerCount += 1
        lock.unlock()

        return { [weak self] in
            _ = AXObserverRemoveNotification(entry.observer, element, notification as CFString)
            Unmanaged<HandlerBox>.fromOpaque(userInfo).release()
            self?.releaseObserver(pid: pid)
        }
    }

    private func obtainObserver(for pid: pid_t) throws -> ObserverEntry {
        lock.lock()
        defer { lock.unlock() }
        if let existing = observersByPID[pid] { return existing }
        var observer: AXObserver?
        let createErr = AXObserverCreate(pid, AXBackendCallback, &observer)
        guard createErr == .success, let observer = observer else {
            throw AXObserverBus.BusError.backendFailed(createErr)
        }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        let entry = ObserverEntry(observer: observer)
        observersByPID[pid] = entry
        return entry
    }

    private func releaseObserver(pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = observersByPID[pid] else { return }
        entry.handlerCount -= 1
        if entry.handlerCount <= 0 {
            let source = AXObserverGetRunLoopSource(entry.observer)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            observersByPID.removeValue(forKey: pid)
        }
    }
}

/// AXObserver callback signature requires a C function pointer. The
/// per-handler closure is stored in a retained `HandlerBox` whose
/// opaque pointer is passed as `userInfo`; the callback unboxes and
/// invokes it.
private func AXBackendCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo = userInfo else { return }
    let box = Unmanaged<HandlerBox>.fromOpaque(userInfo).takeUnretainedValue()
    box.handler()
}

private final class HandlerBox {
    let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
}
