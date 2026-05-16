import CoreAudio
import Foundation

/// Production backend for `CoreAudioHALBus`. Wraps
/// `AudioObjectAddPropertyListenerBlock` and returns a teardown closure
/// that removes the listener on unsubscribe.
///
/// Each subscription gets its own dispatch queue handle so two
/// subscribers on the same property don't fight over a shared block
/// pointer. The bus itself serialises handler dispatch onto its own
/// queue, so this layer doesn't need additional synchronisation.
public final class RealCoreAudioBackend: CoreAudioHALBus.Backend {

    public init() {}

    public func register(
        _ address: CoreAudioHALBus.Address,
        handler: @escaping () -> Void
    ) throws -> () -> Void {
        var addr = AudioObjectPropertyAddress(
            mSelector: address.selector,
            mScope: address.scope,
            mElement: address.element
        )
        let queue = DispatchQueue(
            label: "MeetingPipeCore.RealCoreAudioBackend.\(address.objectID).\(address.selector)"
        )
        let listenerBlock: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            address.objectID, &addr, queue, listenerBlock
        )
        guard status == noErr else {
            throw CoreAudioHALBus.BusError.backendFailed(status)
        }
        return {
            var teardownAddr = addr
            _ = AudioObjectRemovePropertyListenerBlock(
                address.objectID, &teardownAddr, queue, listenerBlock
            )
        }
    }
}
