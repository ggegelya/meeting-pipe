import AppKit
import SwiftUI

/// Step 2 (TECH-UX1): walk the four TCC permissions, requesting each on demand
/// (one button per row) rather than firing the unframed first-run dialog burst.
/// Denied permissions that can't be re-prompted route to System Settings.
struct OnboardingStepPermissions: View {
    @ObservedObject private var perms = PermissionsCenter.shared
    @State private var inFlight: PermissionsCenter.Kind?

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
