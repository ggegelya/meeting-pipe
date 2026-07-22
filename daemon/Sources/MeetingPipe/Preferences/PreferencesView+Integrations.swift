import AppKit
import SwiftUI

struct IntegrationsSectionView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var secrets: SecretsStore
    var onRunDoctor: () -> Void

    /// Notion DB list for the picker (UX22): the same component the workflow
    /// editor and onboarding use, so a database is chosen from a list here too
    /// instead of pasting a 32-char id. Held at view level so it is populated
    /// from cache on open.
    @StateObject private var notionDBs = NotionDatabaseList()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader("Integrations",
                caption: "Credentials for outbound services. Stored securely in your macOS Keychain.") {
                Button {
                    onRunDoctor()
                } label: {
                    Label("Run doctor…", systemImage: "stethoscope")
                }
                .buttonStyle(.mpGhost)
            }

            SettingsGroup("Anthropic") {
                SettingsStackRow("API key", showsDivider: false) {
                    SettingsSecretField(text: $secrets.anthropicAPIKey, placeholder: "sk-ant-…")
                }
                SettingsRow("Status") {
                    if !secrets.anthropicAPIKey.isEmpty {
                        SettingsStatusPill(tone: .granted, icon: "checkmark.circle.fill", text: "Configured")
                    } else {
                        SettingsStatusPill(tone: .needed, icon: "exclamationmark.triangle.fill", text: "Not configured")
                    }
                }
            } footer: {
                Text("Used to summarize transcripts. Get a key at console.anthropic.com. Local MLX backend doesn't need this.")
            }

            SettingsGroup("OpenAI") {
                SettingsStackRow("API key", showsDivider: false) {
                    SettingsSecretField(text: $secrets.openaiAPIKey, placeholder: "sk-…")
                }
                SettingsRow("Status") {
                    if !secrets.openaiAPIKey.isEmpty {
                        SettingsStatusPill(tone: .granted, icon: "checkmark.circle.fill", text: "Configured")
                    } else {
                        SettingsStatusPill(tone: .needed, icon: "exclamationmark.triangle.fill", text: "Not configured")
                    }
                }
            } footer: {
                Text("Only needed for the OpenAI summarization backend. Get a key at platform.openai.com. Anthropic, local, and Claude CLI backends don't need this.")
            }

            SettingsGroup("Notion") {
                SettingsStackRow("Integration token", showsDivider: false) {
                    SettingsSecretField(text: $secrets.notionToken, placeholder: "ntn_…")
                }
                SettingsStackRow("Database") {
                    NotionDatabasePicker(
                        databaseID: $store.notionDatabaseId,
                        list: notionDBs,
                        disableFetch: store.regulatedMode
                    )
                }
                SettingsRow("Status") {
                    if !secrets.notionToken.isEmpty && !store.notionDatabaseId.isEmpty {
                        SettingsStatusPill(tone: .granted, icon: "checkmark.circle.fill", text: "Configured")
                    } else {
                        SettingsStatusPill(tone: .needed, icon: "exclamationmark.triangle.fill", text: "Not configured")
                    }
                }
            } footer: {
                Text("Create the integration at notion.so/profile/integrations and share your Meetings database with it. Fetch pulls your databases to pick from; paste a database ID if it is not listed.")
            }
        }
    }
}

// MARK: - Permissions
