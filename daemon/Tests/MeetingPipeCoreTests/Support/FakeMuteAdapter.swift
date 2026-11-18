import Foundation
@testable import MeetingPipeCore

/// Counts starts and stops, records the context each start was given, and replays events into
/// whatever sink MicGate installed. Moved out of `MuteSourceFusionTests` by T13 so the routing
/// test in `MicGateIntegrationTests` can observe which adapter a bundle id reached.
final class FakeMuteAdapter: MicGateAdapter {
    let bundleIDs: Set<String>
    let app: String
    let source: MuteReadingSource

    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var startedContexts: [MeetingLifecycleContext] = []
    private var sink: ((AXMuteButtonProbe.Event) -> Void)?

    init(app: String, source: MuteReadingSource, bundleIDs: Set<String> = ["com.microsoft.teams2"]) {
        self.app = app
        self.source = source
        self.bundleIDs = bundleIDs
    }

    func start(
        context: MeetingLifecycleContext,
        handle: MicGateAdapterHandle,
        sink: @escaping (AXMuteButtonProbe.Event) -> Void
    ) throws {
        starts += 1
        startedContexts.append(context)
        self.sink = sink
    }

    func stop() { stops += 1 }

    func send(_ event: AXMuteButtonProbe.Event) { sink?(event) }
}
