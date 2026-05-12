import SwiftUI

/// Preferences > Permissions tab (TECH-E3). One row per TCC permission
/// the daemon touches, with a status badge and a button that either
/// surfaces the system prompt (when never-determined) or opens the
/// matching System Settings pane (when denied).
///
/// State is read from `PermissionsCenter.shared`. The tab polls every
/// 2 s while visible so a grant flipped from System Settings reflects
/// without re-opening Preferences.
struct PermissionsTab: View {
    @ObservedObject private var center = PermissionsCenter.shared
    @State private var workingKind: PermissionsCenter.Kind? = nil

    var body: some View {
        Form {
            Section {
                ForEach(PermissionsCenter.Kind.allCases) { kind in
                    PermissionRow(
                        kind: kind,
                        status: center.status(kind),
                        isWorking: workingKind == kind,
                        onAction: { action in
                            Task { await perform(action: action, on: kind) }
                        }
                    )
                }
            } header: {
                Text("System permissions")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Granting Accessibility from System Settings requires a daemon restart for the change to take effect — macOS caches the trust verdict per-process at launch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Re-check") {
                            Task { await center.refreshAll() }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.top, 6)
        .onAppear { center.startPolling() }
        .onDisappear { center.stopPolling() }
    }

    @MainActor
    private func perform(
        action: PermissionRow.Action,
        on kind: PermissionsCenter.Kind
    ) async {
        workingKind = kind
        defer { workingKind = nil }
        switch action {
        case .request:
            switch kind {
            case .microphone:      await center.requestMic()
            case .screenRecording: await center.requestScreenRecording()
            case .accessibility:   _ = center.requestAccessibility()
            case .notifications:   await center.requestNotifications()
            }
        case .openSettings:
            center.openSystemSettings(for: kind)
        }
    }
}

/// One row per permission. Pulled out so SwiftUI doesn't rebuild the
/// whole list when a single status flips.
private struct PermissionRow: View {
    let kind: PermissionsCenter.Kind
    let status: PermissionsCenter.Status
    let isWorking: Bool
    let onAction: (Action) -> Void

    enum Action {
        case request
        case openSettings
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(iconTint)
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(kind.displayName)
                        .font(.body.weight(.semibold))
                    statusBadge
                }
                Text(kind.rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            actionButton
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusBadge: some View {
        let (text, tint, icon) = badgeAttributes
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(tint.opacity(0.15))
        )
    }

    private var badgeAttributes: (String, Color, String) {
        switch status {
        case .granted:        return ("Granted", .green, "checkmark.circle.fill")
        case .denied:         return ("Denied", .red, "xmark.octagon.fill")
        case .notDetermined:  return ("Not requested", .orange, "questionmark.circle.fill")
        case .unknown:        return ("Checking…", .secondary, "ellipsis.circle")
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if isWorking {
            ProgressView().controlSize(.small)
                .frame(minWidth: 90, alignment: .trailing)
        } else {
            switch status {
            case .granted:
                Button("Open Settings") { onAction(.openSettings) }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            case .denied:
                Button("Open Settings") { onAction(.openSettings) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            case .notDetermined, .unknown:
                Button("Request") { onAction(.request) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var iconName: String {
        switch kind {
        case .microphone:      return "mic"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility:   return "accessibility"
        case .notifications:   return "bell"
        }
    }

    private var iconTint: Color {
        switch status {
        case .granted: return .green
        case .denied:  return .red
        default:       return .secondary
        }
    }
}
