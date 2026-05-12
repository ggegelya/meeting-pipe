import AppKit
import ApplicationServices
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import UserNotifications

/// Single source of truth for the four TCC permissions the daemon
/// touches (Microphone, Screen Recording, Accessibility, Notifications).
/// Centralizes the probe + request paths so the Preferences UI, the
/// startup sequence, and the recording gate all read from the same
/// published state and never disagree.
///
/// Threading: every mutation runs on the main queue. Probes are cheap
/// (no IO besides TCC) so callers can poll. Requests are async and
/// return the post-request status. The class is intentionally NOT
/// `@MainActor` so the Coordinator (which isn't main-isolated either)
/// can read the published state synchronously; mutations stick to the
/// main queue by convention, matching the rest of the daemon.
final class PermissionsCenter: ObservableObject {

    /// Process-wide singleton. The Permissions tab and the Coordinator
    /// both observe the same instance so a flip surfaced by one
    /// surface immediately propagates to the other.
    static let shared = PermissionsCenter()

    enum Kind: String, CaseIterable, Identifiable {
        case microphone
        case screenRecording
        case accessibility
        case notifications

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .microphone:      return "Microphone"
            case .screenRecording: return "Screen Recording"
            case .accessibility:   return "Accessibility"
            case .notifications:   return "Notifications"
            }
        }

        var rationale: String {
            switch self {
            case .microphone:
                return "Required. The daemon writes your voice into the recording's left channel."
            case .screenRecording:
                return "Required for the other side of the call. Without it, recordings are mic-only."
            case .accessibility:
                return "Powers the native end-detection that auto-stops the recording when the meeting ends."
            case .notifications:
                return "Used for processing-done, mic-only-fallback, and still-meeting prompts."
            }
        }
    }

    enum Status: Equatable {
        case granted
        case denied
        case notDetermined
        case unknown
    }

    @Published private(set) var microphone: Status = .unknown
    @Published private(set) var screenRecording: Status = .unknown
    @Published private(set) var accessibility: Status = .unknown
    @Published private(set) var notifications: Status = .unknown

    /// Re-evaluates fired into this stream every time a probe lifts a
    /// permission from a non-`.granted` state to `.granted`. Coordinator
    /// subscribes so the detector picks up an in-progress meeting after
    /// the user finally grants mic / Accessibility from System Settings.
    let permissionGranted = PassthroughSubject<Kind, Never>()

    private var refreshTimer: Timer?

    /// Snapshot any permission by kind. Convenience for the view layer.
    func status(_ kind: Kind) -> Status {
        switch kind {
        case .microphone:      return microphone
        case .screenRecording: return screenRecording
        case .accessibility:   return accessibility
        case .notifications:   return notifications
        }
    }

    // MARK: Probes

    /// Re-read every permission state from TCC. Cheap; called at startup,
    /// when the Preferences window opens, and on a 2 s timer while that
    /// window is visible.
    func refreshAll() async {
        await refreshMic()
        refreshScreenRecording()
        refreshAccessibility()
        await refreshNotifications()
    }

    /// Begin polling at 2 s. Used by the Preferences "Permissions" tab
    /// so a grant flipped in System Settings reflects without the user
    /// re-opening the tab. Stops when `stopPolling` is called.
    func startPolling() {
        stopPolling()
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in await self.refreshAll() }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
        Task { await refreshAll() }
    }

    func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refreshMic() async {
        let raw = AVCaptureDevice.authorizationStatus(for: .audio)
        let new = Self.status(forAVAuth: raw)
        commit(\.microphone, kind: .microphone, status: new)
    }

    func refreshScreenRecording() {
        // CGPreflightScreenCaptureAccess is the documented read-only
        // probe — never prompts. It returns true once TCC has an
        // entry; we also fold in SystemAudioCapture's last-known
        // verdict because a successful SCStream proves access even
        // before TCC's cache has updated.
        let preflight = CGPreflightScreenCaptureAccess()
        let new: Status
        if preflight || SystemAudioCapture.permissionState == .granted {
            new = .granted
        } else if SystemAudioCapture.permissionState == .denied {
            new = .denied
        } else {
            new = .notDetermined
        }
        commit(\.screenRecording, kind: .screenRecording, status: new)
    }

    func refreshAccessibility() {
        let trusted = AXIsProcessTrusted()
        // AX has no "not determined" — either trusted or not. We fold
        // both untrusted states into .denied so the UI shows a single
        // "Open Settings" affordance.
        let new: Status = trusted ? .granted : .denied
        commit(\.accessibility, kind: .accessibility, status: new)
    }

    func refreshNotifications() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let new: Status
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            new = .granted
        case .denied:
            new = .denied
        case .notDetermined:
            new = .notDetermined
        @unknown default:
            new = .unknown
        }
        commit(\.notifications, kind: .notifications, status: new)
    }

    // MARK: Requests

    /// Surface the system mic dialog if the user hasn't decided yet;
    /// otherwise just refresh. Returns the post-request status.
    @discardableResult
    func requestMic() async -> Status {
        let raw = AVCaptureDevice.authorizationStatus(for: .audio)
        if raw == .notDetermined {
            _ = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
        }
        await refreshMic()
        return microphone
    }

    /// Surface the Screen Recording dialog (CoreGraphics path — the
    /// only API that actually adds the bundle to System Settings and
    /// pops the system prompt on a fresh install).
    @discardableResult
    func requestScreenRecording() async -> Status {
        // Re-use prewarm so we ride the same code path that the daemon
        // already trusts at startup. prewarm() handles the
        // CGRequestScreenCaptureAccess + SCShareableContent fetch.
        await SystemAudioCapture.prewarm()
        refreshScreenRecording()
        return screenRecording
    }

    /// Accessibility is special: macOS won't grant programmatically.
    /// We pop the prompt via `kAXTrustedCheckOptionPrompt` (which adds
    /// the bundle to the Accessibility list) and open System Settings
    /// when the user needs to flip the toggle manually.
    @discardableResult
    func requestAccessibility() -> Status {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let opts: CFDictionary = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        refreshAccessibility()
        return accessibility
    }

    @discardableResult
    func requestNotifications() async -> Status {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await refreshNotifications()
        return notifications
    }

    // MARK: System Settings deep links

    /// Open the System Settings pane that owns this permission. Used by
    /// the "Open Settings" button on rows whose status is `.denied`.
    func openSystemSettings(for kind: Kind) {
        let urlString: String
        switch kind {
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .notifications:
            urlString = "x-apple.systempreferences:com.apple.preference.notifications"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Internals

    private func commit(
        _ keyPath: ReferenceWritableKeyPath<PermissionsCenter, Status>,
        kind: Kind,
        status: Status
    ) {
        let prev = self[keyPath: keyPath]
        self[keyPath: keyPath] = status
        // Notify subscribers when a permission lifts to granted. The
        // detector subscribes so an in-progress meeting that was
        // invisible (e.g. mic-blocked KVO returning false) becomes
        // visible immediately, without waiting for the next Workspace
        // notification.
        if status == .granted && prev != .granted {
            permissionGranted.send(kind)
        }
    }

    private static func status(forAVAuth raw: AVAuthorizationStatus) -> Status {
        switch raw {
        case .authorized:    return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default:    return .unknown
        }
    }

    // MARK: Test seam

    /// Drive a status transition without touching TCC. Exists so the
    /// XCTest target can assert the `permissionGranted` broadcast
    /// contract without relying on host-process TCC state, which is
    /// not controllable from a unit test.
    func simulateStatusForTesting(_ status: Status, kind: Kind) {
        switch kind {
        case .microphone:      commit(\.microphone, kind: kind, status: status)
        case .screenRecording: commit(\.screenRecording, kind: kind, status: status)
        case .accessibility:   commit(\.accessibility, kind: kind, status: status)
        case .notifications:   commit(\.notifications, kind: kind, status: status)
        }
    }
}
