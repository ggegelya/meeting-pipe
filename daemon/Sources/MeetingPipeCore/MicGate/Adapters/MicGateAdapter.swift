import ApplicationServices
import Foundation

/// AX handle from the executable's once-per-meeting walk. Absent mute button falls through to RMS + HAL VAD only.
public struct MicGateAdapterHandle {
    public let muteButton: AXUIElement?
    /// Fresh-tree-walk resolver for the live mute button, injected by the daemon
    /// (it owns the AX walk). The probe calls it to re-arm when its cached
    /// element goes stale (Teams 2 re-render / compact-view swap), so the read
    /// recovers instead of latching `.unknown` forever (TECH-MIC6).
    public let resolveMuteButton: (() -> AXUIElement?)?

    public init(muteButton: AXUIElement? = nil, resolveMuteButton: (() -> AXUIElement?)? = nil) {
        self.muteButton = muteButton
        self.resolveMuteButton = resolveMuteButton
    }
}

/// Per-app MicGate adapter. Forwards `AXMuteButtonProbe.Event`s to the sink installed by the `MicGate` coordinator (TECH-G-MIC step 4).
public protocol MicGateAdapter: AnyObject {
    var bundleIDs: Set<String> { get }
    /// MuteLabels TOML app key (`"teams"`, `"zoom"`, `"slack"`, …).
    var app: String { get }
    /// Which oracle this adapter's readings come from. `MicGate` starts at most one
    /// adapter per source for a meeting and fuses their readings (MIC8), so an app
    /// with both an AX control and a log signal gets both. Defaults to `.ax`: every
    /// adapter that predates MIC8 reads a mute *button*.
    var source: MuteReadingSource { get }

    func start(
        context: MeetingLifecycleContext,
        handle: MicGateAdapterHandle,
        sink: @escaping (AXMuteButtonProbe.Event) -> Void
    ) throws

    func stop()
}

public extension MicGateAdapter {
    var source: MuteReadingSource { .ax }
}
