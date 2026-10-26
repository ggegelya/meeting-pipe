import CoreAudio
import Foundation
@testable import MeetingPipeCore

/// CONC9: a `CoreAudioHALBus.Backend` that tests can fire from any thread, the way
/// `coreaudiod` delivers property changes. Registrations are guarded by a lock because
/// the bus registers on its own queue while the test fires from `concurrentPerform`
/// workers; `CoreAudioHALBusTests.RecordingBackend` is single-threaded and would race.
final class ConcurrentHALBackend: CoreAudioHALBus.Backend {
    private struct Registration {
        let selector: AudioObjectPropertySelector
        let fire: () -> Void
    }

    private let lock = NSLock()
    private var nextID = 0
    private var live: [Int: Registration] = [:]

    func register(
        _ address: CoreAudioHALBus.Address,
        handler: @escaping () -> Void
    ) throws -> () -> Void {
        let id: Int = lock.withLock {
            nextID += 1
            live[nextID] = Registration(selector: address.selector, fire: handler)
            return nextID
        }
        return { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.live[id] = nil }
        }
    }

    /// Fire every live registration on `selector`, outside the lock, as the HAL would.
    func fire(_ selector: AudioObjectPropertySelector) {
        let handlers = lock.withLock { live.values.filter { $0.selector == selector }.map(\.fire) }
        for handler in handlers { handler() }
    }

    func liveCount(_ selector: AudioObjectPropertySelector) -> Int {
        lock.withLock { live.values.filter { $0.selector == selector }.count }
    }
}

/// A value shared between the test thread and a signal's queue, read and written under a lock.
final class LockedBox<Value> {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}
