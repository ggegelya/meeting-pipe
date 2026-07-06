import AppKit
import SwiftUI

/// Permissions section: one card per TCC permission, icon badge + status pill + Request/Open Settings button, plus a privacy callout at the bottom.
struct PermissionsSectionView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var center = PermissionsCenter.shared
    @State private var workingKind: PermissionsCenter.Kind? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader("Permissions",
                caption: "The four TCC permissions the daemon needs. None of these send anything off your machine.") {
                Button {
                    // Also clears deferred hints so the user returning from Settings sees a clean state.
                    for kind in PermissionsCenter.Kind.allCases {
                        center.clearDeferredHint(kind)
                    }
                    Task { await center.refreshAll() }
                } label: {
                    Label("Re-check", systemImage: "arrow.clockwise")
                }
            }

            SettingsGroup {
                ForEach(Array(PermissionsCenter.Kind.allCases.enumerated()), id: \.element.id) { index, kind in
                    PermissionsCardRow(
                        kind: kind,
                        status: center.status(kind),
                        isWorking: workingKind == kind,
                        isFirst: index == 0,
                        showsDeferredHint: center.deferredToSettings.contains(kind),
                        onRequest: { perform(action: .request, on: kind) },
                        onOpenSettings: { perform(action: .openSettings, on: kind) }
                    )
                }
            }

            // Regulated mode lives here (moved out of Prompt in the DSN1 IA
            // pass): it is a privacy / egress control, alongside the TCC
            // permissions and the on-device privacy note.
            SettingsGroup("Regulated mode") {
                SettingsToggleRow("Skip Notion publish",
                    sublabel: store.regulatedMode
                        ? "On - Notion publish is disabled for every meeting."
                        : "Off - meetings publish to each workflow's own sinks (Notion only if that workflow enables it).",
                    isOn: $store.regulatedMode,
                    showsDivider: false)
            } footer: {
                Text("Use for client / regulated meetings. The pipeline writes summaries to disk only - no transcript or summary is uploaded to Notion.")
            }

            privacyCallout
                .padding(.top, 4)
                .padding(.bottom, 22)

            Text("Granting Accessibility from System Settings requires a daemon restart for the change to take effect - macOS caches the trust verdict per-process at launch.")
                .font(.mpTextSM)
                .foregroundStyle(Color(MPColors.fgMuted))
                .padding(.leading, 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { center.startPolling() }
        .onDisappear { center.stopPolling() }
    }

    private var privacyCallout: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 16))
                .foregroundStyle(Color(MPColors.signal600))
                .padding(.top, 1)
            Text("Audio capture is fully on-device. The pipeline only reaches the network when sending the transcript to Anthropic for summarization, and when publishing to Notion.")
                .font(.mpTextSM)
                .lineSpacing(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(MPColors.signal600).opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(MPColors.signal600).opacity(0.18), lineWidth: 1)
        )
    }

    private enum Action { case request, openSettings }

    private func perform(action: Action, on kind: PermissionsCenter.Kind) {
        switch action {
        case .request:
            Task {
                workingKind = kind
                defer { workingKind = nil }
                switch kind {
                case .microphone:      await center.requestMic()
                case .screenRecording: await center.requestScreenRecording()
                case .accessibility:   _ = center.requestAccessibility()
                case .notifications:   await center.requestNotifications()
                }
            }
        case .openSettings:
            center.openSystemSettings(for: kind)
        }
    }
}

private struct PermissionsCardRow: View {
    let kind: PermissionsCenter.Kind
    let status: PermissionsCenter.Status
    let isWorking: Bool
    let isFirst: Bool
    let showsDeferredHint: Bool
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst {
                Rectangle()
                    .fill(Color(MPColors.borderFaint))
                    .frame(height: 1)
            }
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(MPColors.bgSunk))
                        .frame(width: 32, height: 32)
                    Image(systemName: iconName)
                        .font(.system(size: 16))
                        .foregroundStyle(Color(MPColors.fgMuted))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(kind.displayName)
                            .font(.mpTextBase.weight(.medium))
                        SettingsStatusPill(
                            tone: pillTone,
                            icon: pillIcon,
                            text: pillText
                        )
                    }
                    Text(rationale)
                        .font(.mpTextSM)
                        .foregroundStyle(Color(MPColors.fgMuted))
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsDeferredHint {
                        Text("Toggle MeetingPipe on in System Settings, then click Re-check.")
                            .font(.mpTextXS)
                            .foregroundStyle(.mpSignal)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 8)
                actionButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if isWorking {
            ProgressView().controlSize(.small).frame(width: 100, alignment: .trailing)
        } else {
            switch status {
            case .granted:
                Button("Open Settings", action: onOpenSettings)
                    .controlSize(.small)
            case .denied:
                Button("Open Settings", action: onOpenSettings)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            case .notDetermined, .unknown:
                Button("Request", action: onRequest)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var iconName: String {
        switch kind {
        case .microphone:      return "mic"
        case .screenRecording: return "rectangle.dashed"
        case .accessibility:   return "figure.stand"
        case .notifications:   return "bell"
        }
    }

    private var rationale: String {
        switch kind {
        case .microphone:
            return "Captures your voice via AVAudioEngine. Audio stays on this Mac."
        case .screenRecording:
            return "Captures system audio via ScreenCaptureKit. No video is recorded."
        case .accessibility:
            return "Reads browser tab titles to detect Meet and Teams Web sessions."
        case .notifications:
            return "Record / skip prompts and 'meeting published' alerts."
        }
    }

    private var pillTone: SettingsStatusPill.Tone {
        switch status {
        case .granted: return .granted
        case .denied:  return .denied
        case .notDetermined, .unknown: return .needed
        }
    }
    private var pillIcon: String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .denied:  return "xmark.octagon.fill"
        case .notDetermined: return "exclamationmark.triangle.fill"
        case .unknown: return "ellipsis.circle"
        }
    }
    private var pillText: String {
        switch status {
        case .granted: return "Granted"
        case .denied:  return "Denied"
        case .notDetermined: return "Needed"
        case .unknown: return "Checking…"
        }
    }
}

// MARK: - Advanced
