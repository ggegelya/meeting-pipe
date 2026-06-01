import CoreAudio
import Foundation

/// Single-owner registration point for CoreAudio HAL property listeners. Centralises `MeetingLifecycleCoordinator` (process-input-running) and `MicGate` (HAL VAD enable/state, system input mute, default-input-device re-resolve) onto one dispatch queue and one teardown path (TECH-C13 step 1; real `AudioObjectAddPropertyListenerBlock` wired in step 2 and TECH-G-MIC step 1). Threading: all entry points serialised on `queue`; handlers dispatched on the same queue.
public final class CoreAudioHALBus {

    /// Identifies a HAL property subscription: the AudioObject plus the
    /// property selector, scope, and element it listens on.
    public struct Address {
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

    /// Performs the real CoreAudio registration. Production wires `RealCoreAudioBackend`; tests inject a stub. Returns a teardown closure; should throw on registration error so the bus can surface it to the caller's `EventLog`.
    public protocol Backend: AnyObject {
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

    /// Subscribe to a HAL property. On failure, `subscribe_failed` logs the numeric OSStatus and its four-char code (e.g. 560947818 -> "!obj") so a `lifecycle_engage_failed` is traceable to the exact AudioObject + selector.
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

    /// Tear down all active subscriptions. Called at daemon shutdown.
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

/// No-op backend used until real CoreAudio wiring lands (TECH-C13 step 2, TECH-G-MIC step 1). Records no listener but returns a teardown so bus bookkeeping behaves identically to production.
public final class NoopCoreAudioBackend: CoreAudioHALBus.Backend {
    public init() {}

    public func register(
        _ address: CoreAudioHALBus.Address,
        handler: @escaping () -> Void
    ) throws -> () -> Void {
        return {}
    }
}
