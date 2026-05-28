import CoreAudio
import Foundation

/// Production backend for `CoreAudioHALBus`. Wraps `AudioObjectAddPropertyListenerBlock`. Each subscription gets its own dispatch queue so two subscribers on the same property don't share a block pointer; the bus's own queue handles serialisation on top.
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
