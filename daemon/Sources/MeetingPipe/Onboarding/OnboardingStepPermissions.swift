import AppKit
import SwiftUI

/// Step 2 (TECH-UX1): walk the four TCC permissions, requesting each on demand
/// (one button per row) rather than firing the unframed first-run dialog burst.
/// Denied permissions that can't be re-prompted route to System Settings.
struct OnboardingStepPermissions: View {
    @ObservedObject private var perms = PermissionsCenter.shared
    @State private var inFlight: PermissionsCenter.Kind?
    /// UX82 item 4: relaunch and come back to this step; nil when no launch agent would answer.
    var relaunch: (() -> Void)? = nil

    /// The Accessibility row's notice. One sentence per case, so it never names a button that
    /// is not there.
    static func accessibilityNotice(canRelaunch: Bool) -> String {
        canRelaunch
            ? "After granting, relaunch MeetingPipe for it to take effect. Setup comes back to this step."
            : "After granting, quit MeetingPipe and open it again for it to take effect."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Grant four permissions")
                .font(.mpTextXL.weight(.semibold))
            Text("Audio capture is fully on-device. None of these permissions send anything off your machine.")
                .font(.callout)
                .foregroundStyle(Color(MPColors.fgMuted))
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                ForEach(PermissionsCenter.Kind.allCases) { kind in
                    row(kind)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await perms.refreshAll() }
    }

    private func row(_ kind: PermissionsCenter.Kind) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(kind))
                .frame(width: 28, height: 28)
                .foregroundStyle(Color(MPColors.fgMuted))
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName).font(.mpTextBase.weight(.medium))
                Text(kind.rationale)
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .fixedSize(horizontal: false, vertical: true)
                if kind == .accessibility {
                    // UX21: the product's own model needs a relaunch here (macOS
                    // caches AX trust per-process at launch), documented in the
                    // Preferences footnote; say so where the grant happens too, or
                    // it reads as granted but does nothing until the next launch.
                    Text(Self.accessibilityNotice(canRelaunch: relaunch != nil))
                        .font(.mpTextXS)
                        .foregroundStyle(.mpWarning)
                        .fixedSize(horizontal: false, vertical: true)
                    if let relaunch {
                        Button("Relaunch MeetingPipe", action: relaunch)
                            .controlSize(.small)
                    }
                }
            }
            Spacer()
            trailing(kind)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(MPColors.border)))
    }

    @ViewBuilder
    private func trailing(_ kind: PermissionsCenter.Kind) -> some View {
        let status = perms.status(kind)
        if status == .granted {
            Label("Granted", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.mpSuccess)
        } else if status == .denied && perms.deferredToSettings.contains(kind) {
            Button("Open Settings") { openSettings(kind) }
                .controlSize(.small)
        } else {
            Button(status == .denied ? "Retry" : "Grant") {
                Task { await request(kind) }
            }
            .controlSize(.small)
            .disabled(inFlight != nil)
        }
    }

    private func request(_ kind: PermissionsCenter.Kind) async {
        inFlight = kind
        switch kind {
        case .microphone:      _ = await perms.requestMic()
        case .screenRecording: _ = await perms.requestScreenRecording()
        case .accessibility:   _ = perms.requestAccessibility()
        case .notifications:   _ = await perms.requestNotifications()
        }
        await perms.refreshAll()
        inFlight = nil
    }

    private func icon(_ kind: PermissionsCenter.Kind) -> String {
        switch kind {
        case .microphone:      return "mic"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility:   return "accessibility"
        case .notifications:   return "bell"
        }
    }

    private func openSettings(_ kind: PermissionsCenter.Kind) {
        let anchor: String
        switch kind {
        case .microphone:      anchor = "Privacy_Microphone"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .accessibility:   anchor = "Privacy_Accessibility"
        case .notifications:   anchor = "Notifications"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
