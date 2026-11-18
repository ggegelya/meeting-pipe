import AppKit
import ApplicationServices
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import os
import UserNotifications

/// Published state for the four TCC permissions the daemon touches. Main-actor isolated (CONC12): under tools 5.9 a non-isolated `async` method runs on the generic executor, so before this every refresh and request committed its `@Published` writes from the cooperative pool. A new `async` probe added here inherits the isolation, so `commit` provably runs on main from every entry point.
@MainActor
final class PermissionsCenter: ObservableObject {

    /// Process-wide singleton shared by the Permissions tab and the Coordinator.
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
                return "Required for the other side of the call, and to notice a meeting in a browser tab. Without it, recordings are mic-only and a meeting in a browser tab never prompts."
            case .accessibility:
                return "Required to notice a meeting at all: it reads the meeting app's windows and call controls. Without it, nothing is detected and nothing auto-stops."
            case .notifications:
                return "Used for every failure notice, the warning before a silent recording is stopped, a recording that could not start or had to stop, and the processing-done and mic-only notices. Optional, but without it those reach you only in the menu bar and the Library."
            }
        }
    }

    enum Status: Equatable {
        case granted
        case denied
        case notDetermined
        case unknown

        /// The value `permission_changed` writes (OBS5).
        var label: String {
            switch self {
            case .granted: return "granted"
            case .denied: return "denied"
            case .notDetermined: return "not_determined"
            case .unknown: return "unknown"
            }
        }
    }

    @Published private(set) var microphone: Status = .unknown
    @Published private(set) var screenRecording: Status = .unknown
    @Published private(set) var accessibility: Status = .unknown
    @Published private(set) var notifications: Status = .unknown
    /// UX92: whether MeetingPipe's banners are on. Authorized with alerts turned off delivers
    /// nothing visible, so it counts as off for the menu line and Finish setup. Nil until read.
    @Published private(set) var notificationAlertsEnabled: Bool?

    /// UX92: denied, or authorized with alerts off. What the menu line and Finish setup read.
    var notificationsOff: Bool {
        NotificationAuthReading.isOff(status: notifications, alertsEnabled: notificationAlertsEnabled)
    }

    /// UX92: the last reading logged, so `notification_auth` is written on a change only.
    private var lastNotificationReading: NotificationAuthReading?

    /// Kinds where the last `request*` call could not prompt and fell through to System Settings. Drives the "toggle MeetingPipe on, then Re-check" hint; cleared on grant or Re-check click.
    @Published private(set) var deferredToSettings: Set<Kind> = []

    /// Fires when a permission transitions to `.granted`. Coordinator subscribes so the detector can pick up an in-progress meeting immediately after the user grants mic or Accessibility from System Settings.
    let permissionGranted = PassthroughSubject<Kind, Never>()

    private var refreshTimer: Timer?

    /// Return the current status for a given kind.
    func status(_ kind: Kind) -> Status {
        switch kind {
        case .microphone:      return microphone
        case .screenRecording: return screenRecording
        case .accessibility:   return accessibility
        case .notifications:   return notifications
        }
    }

    // MARK: Probes

    /// Re-read all permission states from TCC. Read-only: must never call any API that can surface a TCC dialog (CGRequest*, SCShareableContent on macOS 14.4+, requestAuthorization, etc.) - polling at 2 s would re-pop the prompt indefinitely.
    func refreshAll() async {
        await refreshMic()
        refreshScreenRecording()
        refreshAccessibility()
        await refreshNotifications()
    }

    /// Poll at 2 s so a grant flipped in System Settings reflects in the Permissions tab without a re-open.
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
        refreshMicSync()
    }

    /// Synchronous mic probe. The `async` `refreshMic()` wrapper exists only for call-site uniformity with the genuinely-async notification probe.
    func refreshMicSync() {
        let raw = AVCaptureDevice.authorizationStatus(for: .audio)
        commit(\.microphone, kind: .microphone, status: Self.status(forAVAuth: raw))
    }

    func refreshScreenRecording() {
        // Read-only. CGPreflightScreenCaptureAccess reflects TCC changes immediately without triggering a dialog.
        // Do NOT call SCShareableContent here: on macOS 14.4+ it surfaces the TCC dialog when access is denied,
        // so calling it on a 2 s poll would re-pop the prompt indefinitely.
        // Fold in SystemAudioCapture.permissionState (the last verdict from the prewarm path) so a fresh launch
        // with a cached .granted verdict doesn't briefly flash .notDetermined while CGPreflight catches up.
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
        // AX has no "not determined"; fold both untrusted states into .denied for a single "Open Settings" affordance.
        let new: Status = trusted ? .granted : .denied
        commit(\.accessibility, kind: .accessibility, status: new)
    }

    func refreshNotifications() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        // UX92: banners off reads the same as denied to the owner, so it is read beside the grant.
        let alerts: Bool? = switch settings.alertSetting {
        case .enabled: true
        case .disabled: false
        default: nil
        }
        let reading = NotificationAuthReading(status: settings.authorizationStatus, alertsEnabled: alerts)
        if reading != lastNotificationReading {
            lastNotificationReading = reading
            notificationAlertsEnabled = alerts
            NotificationAuthReading.latest.withLock { $0 = reading }
            Log.event(category: "daemon", action: "notification_auth", attributes: reading.attributes)
        }
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

    /// Re-probe Microphone, Screen Recording, and Accessibility synchronously (all cheap TCC reads, no dialog). Notifications excluded: it requires an async UNUserNotificationCenter call and the menu-bar warning row doesn't depend on it.
    func refreshMenuRelevantSync() {
        refreshMicSync()
        refreshScreenRecording()
        refreshAccessibility()
    }

    // MARK: Requests

    /// Surface the system mic dialog if not yet decided; otherwise just refresh. Returns the post-request status.
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

    /// Request Screen Recording via CGRequestScreenCaptureAccess (the only API that adds the bundle to System Settings and prompts on first install). macOS 15 only prompts once per (bundle, cdhash); reinstalls produce a new cdhash so the re-request usually no-ops and must fall through to System Settings - without that fallback the Request button silently does nothing.
    @discardableResult
    func requestScreenRecording() async -> Status {
        // Reuse prewarm so this rides the same trusted path as startup (CGRequestScreenCaptureAccess + SCShareableContent fetch).
        await SystemAudioCapture.prewarm()
        refreshScreenRecording()
        if screenRecording != .granted {
            markDeferredAndOpenSettings(.screenRecording)
        }
        return screenRecording
    }

    /// macOS won't grant Accessibility programmatically. `kAXTrustedCheckOptionPrompt` adds the bundle to the Accessibility list; System Settings handles the actual toggle.
    @discardableResult
    func requestAccessibility() -> Status {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let opts: CFDictionary = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        refreshAccessibility()
        return accessibility
    }

    /// macOS only shows the Notifications dialog once; subsequent `requestAuthorization` calls return the prior verdict silently. `tccutil reset` does not affect Notifications. If already decided, fall through to System Settings so the button always does something visible.
    @discardableResult
    func requestNotifications() async -> Status {
        let center = UNUserNotificationCenter.current()
        let current = await center.notificationSettings().authorizationStatus
        if current == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshNotifications()
            if notifications != .granted {
                markDeferredAndOpenSettings(.notifications)
            }
        } else {
            await refreshNotifications()
            if notifications != .granted {
                markDeferredAndOpenSettings(.notifications)
            }
        }
        return notifications
    }

    /// Clear the "fell through to Settings" hint; called by the Re-check button.
    func clearDeferredHint(_ kind: Kind) {
        if deferredToSettings.contains(kind) {
            deferredToSettings.remove(kind)
        }
    }

    private func markDeferredAndOpenSettings(_ kind: Kind) {
        deferredToSettings.insert(kind)
        openSystemSettings(for: kind)
    }

    // MARK: System Settings deep links

    /// Open the System Settings pane for the given permission kind.
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
            // macOS Ventura+ moved Notifications to the extension surface; the legacy
            // `com.apple.preference.notifications` URL silently fails on 13+ (Settings opens but the deep link does nothing).
            urlString = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
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
        // OBS5 (UI-13): an unchanged status changes nothing, so it publishes nothing. The assignment
        // used to run regardless, so the Permissions pane re-rendered four times every 2 s poll.
        guard prev != status else { return }
        self[keyPath: keyPath] = status
        // OBS5: every transition, revocations included. Every status starts `.unknown`, so the first
        // observation after launch is `at_launch`, not a grant the owner just made: the retired
        // `permission_granted` row reported four months-old grants at every launch, and a revoked
        // Screen Recording showed up only as a recording with no system audio.
        var attributes: [String: Any] = ["kind": kind.rawValue, "from": prev.label, "to": status.label]
        if prev == .unknown { attributes["at_launch"] = true }
        Log.event(category: "coordinator", action: "permission_changed", attributes: attributes)
        if prev != .unknown {
            Log.writeLine("daemon", "permission \(kind.rawValue): \(prev.label) -> \(status.label)")
        }
        if status == .granted && prev != .granted {
            permissionGranted.send(kind)
            // Drop the deferred hint once the kind flips on; no need to show "toggle on, then re-check" under a green row.
            if deferredToSettings.contains(kind) {
                deferredToSettings.remove(kind)
            }
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

    /// Inject a status without touching TCC; lets XCTest assert the `permissionGranted` broadcast contract without relying on host-process TCC state.
    func simulateStatusForTesting(_ status: Status, kind: Kind) {
        switch kind {
        case .microphone:      commit(\.microphone, kind: kind, status: status)
        case .screenRecording: commit(\.screenRecording, kind: kind, status: status)
        case .accessibility:   commit(\.accessibility, kind: kind, status: status)
        case .notifications:   commit(\.notifications, kind: kind, status: status)
        }
    }
}

/// UX92: one Notifications reading, the grant and whether banners are on. Pure, so the menu line,
/// Finish setup, the `notification_auth` row and the doctor probe read one rule.
struct NotificationAuthReading: Equatable, Sendable {
    /// `granted`, `denied`, `not_determined` or `provisional`.
    let status: String
    let alertsEnabled: Bool?

    init(status: UNAuthorizationStatus, alertsEnabled: Bool?) {
        switch status {
        case .authorized, .ephemeral: self.status = "granted"
        case .provisional: self.status = "provisional"
        case .denied: self.status = "denied"
        case .notDetermined: self.status = "not_determined"
        @unknown default: self.status = "not_determined"
        }
        self.alertsEnabled = alertsEnabled
    }

    init(status: String, alertsEnabled: Bool?) {
        self.status = status
        self.alertsEnabled = alertsEnabled
    }

    var isOff: Bool { status == "denied" || alertsEnabled == false }

    var attributes: [String: Any] {
        ["status": status, "alerts": alertsEnabled.map { $0 ? "enabled" : "disabled" } ?? "unknown"]
    }

    static func isOff(status: PermissionsCenter.Status, alertsEnabled: Bool?) -> Bool {
        status == .denied || alertsEnabled == false
    }

    /// The daemon's latest reading, for the in-app doctor sheet, whose probes run off main. Nil in
    /// the `MeetingPipe doctor` process, which has no reading of its own and says so.
    static let latest = OSAllocatedUnfairLock<NotificationAuthReading?>(initialState: nil)
}
