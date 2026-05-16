import ApplicationServices
import Foundation

/// AX handle the executable's once-per-meeting walk produces for
/// MicGate. The Mute button is required for AX-based gating; absence
/// causes the adapter to fall through to RMS + HAL VAD only.
public struct MicGateAdapterHandle {
    public let muteButton: AXUIElement?

    public init(muteButton: AXUIElement? = nil) {
        self.muteButton = muteButton
    }
}

/// Per-app MicGate adapter. Owns the `AXMuteButtonProbe` configured
/// for its platform and forwards `AXMuteButtonProbe.Event`s to a
/// sink the `MicGate` coordinator (TECH-G-MIC step 4) installs.
public protocol MicGateAdapter: AnyObject {
    var bundleIDs: Set<String> { get }
    /// MuteLabels TOML app key (`"teams"`, `"zoom"`, `"slack"`, …).
    var app: String { get }

    func start(
        context: MeetingLifecycleContext,
        handle: MicGateAdapterHandle,
        sink: @escaping (AXMuteButtonProbe.Event) -> Void
    ) throws

    func stop()
}
