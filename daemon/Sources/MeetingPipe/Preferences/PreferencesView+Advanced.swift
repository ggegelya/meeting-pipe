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
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Config.defaultPath])
                    }
                }
                SettingsRow("Logs folder",
                    sublabel: "Rotated daily. Used by mp doctor and bug reports.") {
                    Button("Open logs") {
                        NSWorkspace.shared.open(Log.logsDir)
                    }
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

            Text("MeetingPipe - config lives in `~/.config/meeting-pipe/`. Workflows live in `~/.config/meeting-pipe/workflows/`. Both are plain TOML - safe to edit by hand if you know what you're doing.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Wrapping HStack
