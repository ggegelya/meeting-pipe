import CoreAudio
import Foundation

/// Single-owner registration point for CoreAudio HAL property listeners. Centralises `MeetingLifecycleCoordinator` (process-input-running) and `MicGate` (HAL VAD enable/state, system input mute, default-input-device re-resolve) onto one dispatch queue and one teardown path (TECH-C13 step 1; real `AudioObjectAddPropertyListenerBlock` wired in step 2 and TECH-G-MIC step 1). Threading: all entry points serialised on `queue`; handlers dispatched on the same queue.
public final class CoreAudioHALBus {

    /// Identifies a HAL property subscription: the AudioObject plus the
    /// property selector, scope, and element it listens on. Hashable because
    /// the bus keys its one backend listener per address on it (DET21).
    public struct Address: Hashable {
        public let objectID: AudioObjectID
        public let selector: AudioObjectPropertySelector
        public let scope: AudioObjectPropertyScope
        public let element: AudioObjectPropertyElement

        public init(
            objectID: AudioObjectID,
            selector: AudioObjectPropertySelector,
            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
            element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
        ) {
            self.objectID = objectID
            self.selector = selector
            self.scope = scope
            self.element = element
        }

        /// The system object never goes away, so its listeners are kept for the daemon's lifetime.
        var isSystemObject: Bool { objectID == AudioObjectID(kAudioObjectSystemObject) }
    }

    /// Performs the real CoreAudio registration. Production wires `RealCoreAudioBackend`; tests inject a stub. Throws on registration error so the bus can surface it to the caller's `EventLog`. Returns a removal closure whose result is the removal's own `OSStatus` (DET21: it used to be thrown away, and the HAL kept calling blocks the log said were gone).
    public protocol Backend: AnyObject {
        func register(_ address: Address, handler: @escaping () -> Void) throws -> () -> OSStatus
    }

    public struct Token: Hashable {
        fileprivate let id: UInt64
    }

    public enum BusError: Error, LocalizedError {
        case backendFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .backendFailed(let status):
                return "CoreAudioHALBus backend registration failed (OSStatus=\(status))"
            }
        }
    }

    /// One backend listener and the handlers fanned out from it (DET21). `epoch` tags the backend
    /// registration, so a block from an earlier registration of the same address that the HAL still
    /// calls after a removal finds a different epoch and fans out to nothing.
    private struct Listener {
        let epoch: UInt64
        let remove: () -> OSStatus
        var handlers: [Token: () -> Void]
    }

    private let backend: Backend
    private let eventLog: EventLog
    private let now: () -> TimeInterval
    private let queue = DispatchQueue(label: "MeetingPipeCore.CoreAudioHALBus")
    /// Marks `queue` so a re-entrant call from inside a handler can detect it
    /// and run inline instead of dead-locking on `queue.sync`. Per-instance, so
    /// being on a *different* bus's queue is correctly treated as off-queue.
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var listeners: [Address: Listener] = [:]
    private var tokenAddress: [Token: Address] = [:]
    private var nextID: UInt64 = 0
    private var nextEpoch: UInt64 = 0

    /// Stale-delivery counter (DET21), under its own lock because the signals report from their own queues.
    private let staleLock = NSLock()
    private var staleCounts: [String: Int] = [:]
    private var lastStaleEmit: TimeInterval?
    public static let staleDeliveryEmitInterval: TimeInterval = 60

    public init(
        backend: Backend = NoopCoreAudioBackend(),
        eventLog: EventLog = NoopEventLog(),
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.backend = backend
        self.eventLog = eventLog
        self.now = now
        queue.setSpecific(key: queueKey, value: 1)
    }

    /// Serialise `body` on `queue`. Handlers are dispatched on `queue`
    /// (`subscribe` below), and a handler may call back into `subscribe` /
    /// `unsubscribe` (e.g. `HALSystemMuteProbe` rebinding the mute listener when
    /// the default input device changes). A plain `queue.sync` from there would
    /// wait on the queue it is already running on -> `EXC_BREAKPOINT`. When
    /// already on `queue`, run inline; the serial queue still guarantees mutual
    /// exclusion on `listeners`.
    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try body()
        }
        return try queue.sync(execute: body)
    }

    /// Subscribe a handler to a HAL property. The first handler on an address registers the one
    /// backend listener for it; later handlers join its fan-out table and touch the HAL not at all,
    /// so `subscribe_attempt` / `subscribed` / `subscribe_failed` rows mark real HAL registrations
    /// only. On failure, `subscribe_failed` logs the numeric OSStatus and its four-char code (e.g.
    /// 560947818 -> "!obj") so a `lifecycle_engage_failed` is traceable to the exact AudioObject + selector.
    public func subscribe(_ address: Address, handler: @escaping () -> Void) throws -> Token {
        try onQueue { () throws -> Token in
            if listeners[address] == nil {
                try registerBackendListener(address)
            }
            nextID += 1
            let token = Token(id: nextID)
            listeners[address]?.handlers[token] = handler
            tokenAddress[token] = address
            return token
        }
    }

    /// On `queue`. Registers the backend listener for `address` and logs the attempt and its outcome.
    private func registerBackendListener(_ address: Address) throws {
        let attemptAttrs = addressAttributes(address)
        eventLog.emit(category: "halbus", action: "subscribe_attempt", attributes: attemptAttrs)
        nextEpoch += 1
        let epoch = nextEpoch
        do {
            let remove = try backend.register(address, handler: { [weak self, queue] in
                queue.async { self?.deliver(address, epoch: epoch) }
            })
            listeners[address] = Listener(epoch: epoch, remove: remove, handlers: [:])
            eventLog.emit(category: "halbus", action: "subscribed", attributes: attemptAttrs)
        } catch let busError as BusError {
            var attrs = attemptAttrs
            if case .backendFailed(let status) = busError {
                attrs["osstatus"] = Int(status)
                attrs["osstatus_4cc"] = fourCC(UInt32(bitPattern: status))
            }
            eventLog.emit(category: "halbus", action: "subscribe_failed", attributes: attrs)
            throw busError
        } catch {
            var attrs = attemptAttrs
            attrs["error"] = "\(error)"
            eventLog.emit(category: "halbus", action: "subscribe_failed", attributes: attrs)
            throw error
        }
    }

    /// On `queue`. Fans one backend delivery out to the handlers current at delivery time. A handler
    /// may re-enter `subscribe` / `unsubscribe`, so membership is re-checked before each call: one
    /// removed by an earlier handler in this same delivery does not run.
    ///
    /// A delivery from a block whose registration is gone (removed, or replaced under a newer
    /// epoch) is the leak D057 describes, which a `noErr` removal cannot rule out. It used to return
    /// here uncounted, so `stale_delivery_count` read zero with the leak present; it now counts as
    /// `bus_epoch` (DET21 amendment, 2026-11-17).
    private func deliver(_ address: Address, epoch: UInt64) {
        guard let listener = listeners[address], listener.epoch == epoch else {
            noteStaleDelivery(source: "bus_epoch")
            return
        }
        for (token, handler) in listener.handlers.sorted(by: { $0.key.id < $1.key.id }) {
            guard listeners[address]?.epoch == epoch, listeners[address]?.handlers[token] != nil else { continue }
            handler()
        }
    }

    /// Remove a handler. Nothing above the bus ever removes a HAL listener (DET21). When the last
    /// handler leaves, a listener on the system object is kept for the daemon's lifetime (it cannot
    /// die, and those are the addresses whose re-subscribes leaked); a listener on any other object
    /// (a device, a process) is removed, because a retained listener on an object the HAL destroys
    /// could go deaf if the id came back. A removal that fails with anything but `!obj` keeps the
    /// entry, inert with no handlers, and a later subscribe reuses it rather than registering twice.
    public func unsubscribe(_ token: Token) {
        onQueue {
            guard let address = tokenAddress.removeValue(forKey: token) else { return }
            listeners[address]?.handlers[token] = nil
            guard let listener = listeners[address], listener.handlers.isEmpty, !address.isSystemObject else { return }
            let status = listener.remove()
            if status == noErr || status == kAudioHardwareBadObjectError {
                listeners[address] = nil
            }
            emitRemoval(address, status: status)
        }
    }

    /// On `queue`. `unsubscribed` only when the HAL said `noErr`; anything else is `unsubscribe_failed` with the status.
    private func emitRemoval(_ address: Address, status: OSStatus) {
        var attrs: [String: Any] = [
            "object_id": address.objectID,
            "selector": fourCC(address.selector)
        ]
        if status == noErr {
            eventLog.emit(category: "halbus", action: "unsubscribed", attributes: attrs)
        } else {
            attrs["osstatus"] = Int(status)
            attrs["osstatus_4cc"] = fourCC(UInt32(bitPattern: status))
            eventLog.emit(category: "halbus", action: "unsubscribe_failed", attributes: attrs)
        }
    }

    /// Remove every backend listener and drop every handler. Called at daemon shutdown. Flushes a
    /// pending stale-delivery count first, so a count under a minute old is not lost at quit.
    public func reset() {
        flushStaleDeliveries()
        onQueue {
            for (address, listener) in listeners.sorted(by: { $0.value.epoch < $1.value.epoch }) {
                emitRemoval(address, status: listener.remove())
            }
            listeners.removeAll()
            tokenAddress.removeAll()
        }
    }

    /// Handlers currently subscribed, across every address.
    public var activeSubscriptionCount: Int {
        onQueue { tokenAddress.count }
    }

    /// Backend listeners currently registered (one per address at most, DET21).
    public var backendListenerCount: Int {
        onQueue { listeners.count }
    }

    // MARK: - Stale deliveries (DET21)

    /// A signal's generation guard dropped a delivery meant for a session that has moved on. Counted
    /// per `source` and emitted as `halbus/stale_delivery_count` at most once a minute while non-zero,
    /// so a field log shows whether anything still delivers to a stopped session.
    public func noteStaleDelivery(source: String) {
        let pending: [String: Int]? = staleLock.withLock {
            staleCounts[source, default: 0] += 1
            let t = now()
            if let last = lastStaleEmit, t - last < Self.staleDeliveryEmitInterval { return nil }
            lastStaleEmit = t
            defer { staleCounts.removeAll() }
            return staleCounts
        }
        if let pending { emitStale(pending) }
    }

    private func flushStaleDeliveries() {
        let pending: [String: Int] = staleLock.withLock {
            defer { staleCounts.removeAll() }
            return staleCounts
        }
        if !pending.isEmpty { emitStale(pending) }
    }

    private func emitStale(_ counts: [String: Int]) {
        var attrs: [String: Any] = ["count": counts.values.reduce(0, +)]
        for (source, count) in counts { attrs[source] = count }
        eventLog.emit(category: "halbus", action: "stale_delivery_count", attributes: attrs)
    }

    private func addressAttributes(_ address: Address) -> [String: Any] {
        [
            "object_id": address.objectID,
            "selector": fourCC(address.selector),
            "scope": fourCC(address.scope),
            "element": address.element
        ]
    }

    private func fourCC(_ code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        if let s = String(bytes: bytes, encoding: .ascii), s.allSatisfy({ $0.isASCII && !$0.isNewline }) {
            return s
        }
        return String(code)
    }
}

/// No-op backend used until real CoreAudio wiring lands (TECH-C13 step 2, TECH-G-MIC step 1). Records no listener but returns a teardown so bus bookkeeping behaves identically to production.
public final class NoopCoreAudioBackend: CoreAudioHALBus.Backend {
    public init() {}

    public func register(
        _ address: CoreAudioHALBus.Address,
        handler: @escaping () -> Void
    ) throws -> () -> OSStatus {
        return { noErr }
    }
}
