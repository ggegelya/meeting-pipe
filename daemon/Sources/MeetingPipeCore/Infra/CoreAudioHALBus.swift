import CoreAudio
import Foundation

/// Single-owner registration point for CoreAudio HAL property listeners.
///
/// Both `MeetingLifecycleCoordinator` (process-input-running, default
/// input device changes) and `MicGate` (HAL VAD enable/state, system
/// input mute) need property listeners on the same AudioObject space.
/// Centralising registration here keeps the runtime predictable: one
/// dispatch queue, one place to inspect what's currently subscribed,
/// one teardown path on shutdown.
///
/// The skeleton lands in TECH-C13 step 1. Real registration via
/// `AudioObjectAddPropertyListenerBlock` is wired in step 2 (PrimaryC13
/// signals) and TECH-G-MIC step 1 (HAL VAD / system mute probes). For
/// now the bus only owns the subscription bookkeeping and the test
/// seam; the production `RealCoreAudioBackend` defaults to a no-op
/// registration and emits a log line so callers can observe the gap.
///
/// Threading: every entry point is serialised on `queue`. Handlers are
/// dispatched on the same queue, matching the contract that
/// `AudioObjectAddPropertyListenerBlock`'s dispatch queue parameter
/// would normally provide.
public final class CoreAudioHALBus {

    /// Identifies a HAL property subscription. Keys the bus so two
    /// subscribers on the same address share one underlying CoreAudio
    /// listener once the real backend lands.
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
    }

    /// Concrete backend that performs the real CoreAudio registration.
    /// Production wires `RealCoreAudioBackend`; tests inject a stub.
    public protocol Backend: AnyObject {
        /// Returns a teardown closure that the bus stores against the
        /// subscription token. Implementations should fail loud if
        /// registration errors; the bus surfaces the error to the
        /// caller's `EventLog`.
        func register(_ address: Address, handler: @escaping () -> Void) throws -> () -> Void
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

    private struct Subscription {
        let address: Address
        let teardown: () -> Void
    }

    private let backend: Backend
    private let eventLog: EventLog
    private let queue = DispatchQueue(label: "MeetingPipeCore.CoreAudioHALBus")
    private var subscriptions: [Token: Subscription] = [:]
    private var nextID: UInt64 = 0

    public init(backend: Backend = NoopCoreAudioBackend(), eventLog: EventLog = NoopEventLog()) {
        self.backend = backend
        self.eventLog = eventLog
    }

    /// Subscribe to a HAL property. Returns a token the caller stores
    /// and passes to `unsubscribe` at meeting end.
    ///
    /// Per-subscription diagnostic events bracket the registration so a
    /// `lifecycle_engage_failed` is traceable down to the exact
    /// AudioObject + selector that returned the OSStatus. On failure,
    /// `subscribe_failed` reports both the numeric status and its
    /// four-char code (e.g. 560947818 -> "!obj") before re-throwing.
    public func subscribe(_ address: Address, handler: @escaping () -> Void) throws -> Token {
        let attemptAttrs: [String: Any] = [
            "object_id": address.objectID,
            "selector": fourCC(address.selector),
            "scope": fourCC(address.scope),
            "element": address.element
        ]
        eventLog.emit(category: "halbus", action: "subscribe_attempt", attributes: attemptAttrs)
        do {
            let token = try queue.sync { () throws -> Token in
                let teardown = try backend.register(address, handler: { [queue] in
                    queue.async(execute: handler)
                })
                nextID += 1
                let token = Token(id: nextID)
                subscriptions[token] = Subscription(address: address, teardown: teardown)
                return token
            }
            eventLog.emit(category: "halbus", action: "subscribed", attributes: attemptAttrs)
            return token
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

    public func unsubscribe(_ token: Token) {
        queue.sync {
            guard let sub = subscriptions.removeValue(forKey: token) else { return }
            sub.teardown()
            eventLog.emit(category: "halbus", action: "unsubscribed", attributes: [
                "object_id": sub.address.objectID,
                "selector": fourCC(sub.address.selector)
            ])
        }
    }

    /// Tear down every active subscription. Called at daemon shutdown.
    public func reset() {
        queue.sync {
            for sub in subscriptions.values { sub.teardown() }
            subscriptions.removeAll()
        }
    }

    public var activeSubscriptionCount: Int {
        queue.sync { subscriptions.count }
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

/// Default backend used until the real CoreAudio wiring lands. Records
/// no listener but returns a teardown so the bus's bookkeeping behaves
/// identically to production. Step 2 (TECH-C13) and TECH-G-MIC step 1
/// replace this with a real `AudioObjectAddPropertyListenerBlock`
/// backend.
public final class NoopCoreAudioBackend: CoreAudioHALBus.Backend {
    public init() {}

    public func register(
        _ address: CoreAudioHALBus.Address,
        handler: @escaping () -> Void
    ) throws -> () -> Void {
        return {}
    }
}
