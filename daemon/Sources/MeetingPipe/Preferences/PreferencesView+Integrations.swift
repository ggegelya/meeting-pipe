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
                caption: "Credentials for outbound services, stored in your macOS Keychain, and where each publish target writes. Which targets a meeting uses is per workflow; this is where they point.") {
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
                SettingsToggleRow(
                    "Include the full transcript",
                    sublabel: "Every word spoken is sent to Notion and stored on the page. Off publishes the summary and actions only; the transcript stays on this Mac.",
                    isOn: $store.notionIncludeFullTranscript
                )
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

            obsidianGroup
            filesystemGroup
            lanGroup
        }
    }

    // MARK: - Publish targets (UX45)

    /// A workflow's sink checkboxes choose WHICH destinations run; the three
    /// groups below say WHERE each one writes. Global on purpose, and recorded as
    /// such: a per-workflow vault path is a different feature, not an omission.
    ///
    /// Until UX45 all three were TOML-only with zero Swift readers, so a workflow
    /// could enable the Obsidian sink and have it silently never run, and NDA mode
    /// force-selected the one sink whose destination could not be set in-app. They
    /// sit here rather than behind a fourth heading level because the pane already
    /// owns Notion's destination, and DSN28 locks one type anchor per surface.
    ///
    /// The snapshot the shared readiness derivation reads. Same type the workflow
    /// editor's caption uses, so the two surfaces cannot disagree about whether a
    /// target is set up.
    private var targets: PublishTargets {
        PublishTargets(
            obsidianVaultPath: store.obsidianVaultPath,
            filesystemOutputDir: store.filesystemOutputDir,
            lanMountPath: store.lanMountPath
        )
    }

    private var obsidianGroup: some View {
        SettingsGroup("Obsidian") {
            SettingsStackRow("Vault folder", showsDivider: false) {
                pathField(
                    text: $store.obsidianVaultPath,
                    placeholder: "~/Documents/Obsidian/Personal",
                    prompt: "Pick your Obsidian vault's root folder."
                )
            }
            SettingsStackRow("Notes subfolder",
                sublabel: "Where inside the vault a meeting note lands.") {
                TextField("Meetings", text: $store.obsidianFolder)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsToggleRow(
                "Copy the recording into the vault",
                sublabel: "Attaches the audio beside the note. An hour of meeting is about 0.7 GB, so a synced vault feels this.",
                isOn: $store.obsidianAttachAudio
            )
            if store.obsidianAttachAudio {
                SettingsStackRow("Attachments subfolder") {
                    TextField("_attachments", text: $store.obsidianAttachmentsSubfolder)
                        .textFieldStyle(.roundedBorder)
                }
            }
            statusRow(.obsidian)
        } footer: {
            Text("Notes land at <vault>/<subfolder>/<date> <title>.md with YAML front-matter. A custom template and the daily-note backlink stay in config.toml (obsidian.template_path, obsidian.daily_note_backlink).")
        }
    }

    private var filesystemGroup: some View {
        SettingsGroup("Filesystem") {
            SettingsStackRow("Output folder", showsDivider: false) {
                pathField(
                    text: $store.filesystemOutputDir,
                    placeholder: "~/Documents/Meetings/published",
                    prompt: "Pick where published Markdown lands."
                )
            }
            statusRow(.filesystem)
        } footer: {
            Text("Three files per meeting: summary, transcript, and actions. This is where an NDA workflow publishes, and the only place it does, so it is worth setting even if you never enable the sink by hand.")
        }
    }

    private var lanGroup: some View {
        SettingsGroup("LAN share") {
            SettingsStackRow("Mount path", showsDivider: false) {
                pathField(
                    text: $store.lanMountPath,
                    placeholder: "/Volumes/meetings",
                    prompt: "Pick the target folder on an already-mounted share."
                )
            }
            SettingsStackRow("Share name",
                sublabel: "Optional. Only ever shown in the \"share unreachable\" message.") {
                TextField("files.example.lan", text: $store.lanHost)
                    .textFieldStyle(.roundedBorder)
            }
            statusRow(.lan)
        } footer: {
            Text("Mount the SMB/NFS share yourself first: the publisher never creates the mount root, so a share that is down fails loudly instead of quietly writing to local disk. A regulated or NDA meeting still publishes to the local folder only, share or no share.")
        }
    }

    /// Configured means a path is set, and no more than that. Whether the vault
    /// or the share is reachable is the publisher's question, answered at publish
    /// time, and a status pill that probed the filesystem on every render would
    /// still be stale by the time it mattered.
    private func statusRow(_ target: PublishTarget) -> some View {
        SettingsRow("Status", sublabel: targets.missingSettingHint(for: target)) {
            if targets.isConfigured(target) {
                SettingsStatusPill(tone: .granted, icon: "checkmark.circle.fill", text: "Configured")
            } else {
                SettingsStatusPill(tone: .needed, icon: "exclamationmark.triangle.fill", text: "Not configured")
            }
        }
    }

    /// A path field with a Choose… button beside it. Both halves are deliberate:
    /// the panel is how a folder gets picked without typing, and the field is how
    /// a path that is not currently mounted (the LAN case) gets set at all.
    @ViewBuilder
    private func pathField(text: Binding<String>, placeholder: String, prompt: String) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .font(.mpTextSM.monospaced())
        Button("Choose…") { choosePath(into: text, message: prompt) }
            .buttonStyle(.mpGhost)
    }

    private func choosePath(into binding: Binding<String>, message: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = message
        let current = (binding.wrappedValue as NSString).expandingTildeInPath
        if !current.isEmpty, FileManager.default.fileExists(atPath: current) {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        binding.wrappedValue = url.path
    }
}

// MARK: - Permissions
