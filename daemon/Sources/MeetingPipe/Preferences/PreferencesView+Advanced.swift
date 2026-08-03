import AppKit
import SwiftUI

struct AdvancedSectionView: View {
    @ObservedObject private var ui = UISettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader("Advanced",
                caption: "Plumbing for power users. Most people never come here.")

            SettingsGroup("Configuration") {
                SettingsRow("Config file",
                    sublabel: Config.defaultPath.path,
                    showsDivider: false) {
                    Button("Open in editor") {
                        NSWorkspace.shared.open(Config.defaultPath)
                    }
                    .buttonStyle(.mpGhost)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Config.defaultPath])
                    }
                    .buttonStyle(.mpGhost)
                }
                SettingsRow("Logs folder",
                    sublabel: "Rotated daily. Used by mp doctor and bug reports.") {
                    Button("Open logs") {
                        NSWorkspace.shared.open(Log.logsDir)
                    }
                    .buttonStyle(.mpGhost)
                }
            }

            SettingsGroup("Diagnostics") {
                SettingsToggleRow("Verbose logging",
                    sublabel: "Emit extra detail to the unified log and pass MP_VERBOSE=1 to pipeline subprocesses.",
                    isOn: $ui.verboseLogging,
                    showsDivider: false)
            } footer: {
                Text("Takes effect after restarting MeetingPipe - the env var is set at daemon launch and inherited by every subprocess spawned afterwards.")
            }

            SettingsGroup("Automation") {
                ForEach(Array(AutomationReference.rows.enumerated()), id: \.element.id) { index, row in
                    AutomationVerbRow(row: row, showsDivider: index > 0)
                }
            } footer: {
                Text("Paste one into a Shortcuts \"Open URL\" action, or into Raycast, Stream Deck, or a terminal. MeetingPipe's own Shortcuts actions are the other route, and they stay off until the app is signed with an Apple Developer ID.")
            }

            Text("MeetingPipe - config lives in `~/.config/meeting-pipe/`. Workflows live in `~/.config/meeting-pipe/workflows/`. Both are plain TOML - safe to edit by hand if you know what you're doing.")
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgSubtle))
                .padding(.top, 4)
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Automation verb row

/// One row of the AUTO4 automation reference: the URL in mono, its one-line
/// purpose under it, and a copy button. Read-only by design, and it renders
/// `AutomationReference.rows` rather than carrying any vocabulary of its own, so
/// the fence over that list is a fence over what the pane actually shows.
///
/// `SettingsFullRow` rather than `SettingsRow`: the URL is the thing you scan
/// for, so it wants the mono treatment and the full width, not the muted sublabel
/// slot a label-plus-control row would give it.
private struct AutomationVerbRow: View {
    let row: AutomationReference
    var showsDivider: Bool

    /// The copy confirmation. A button that puts something on the pasteboard and
    /// changes nothing on screen reads as a dead button, and this pane has no
    /// other place to say it worked.
    @State private var copied = false

    var body: some View {
        SettingsFullRow(showsDivider: showsDivider) {
            HStack(alignment: .top, spacing: MPSpace.s4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.template)
                        .font(.mpTextSM.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(row.purpose)
                        .font(.mpTextXS)
                        .foregroundStyle(Color(MPColors.fgMuted))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(copied ? "Copied" : "Copy") { copy() }
                    .buttonStyle(.mpGhost)
                    .accessibilityLabel(copied ? "Copied \(row.template)" : "Copy \(row.template)")
            }
        }
    }

    private func copy() {
        row.copyTemplate()
        copied = true
        // A MainActor Task, like TranscriptTab's citation flash. Deliberately not
        // generation-tracked: re-copying the same row inside the window only ends
        // its confirmation early, and the row is already reading "Copied" then.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }
}

// MARK: - Wrapping HStack
