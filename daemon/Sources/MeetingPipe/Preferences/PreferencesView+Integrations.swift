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

    /// AUTO3 leg 3. Held at view level like `notionDBs`, and refreshed on
    /// `.onAppear` rather than per render: `refresh()` spawns `mp mcp-serve
    /// --status`, and UX67 is the incident that says a `Process` on a hot path
    /// in this pane wedges every control in it.
    @StateObject private var mcp = MCPStatusStore()

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
            mcpGroup
        }
        // Once per appearance, never per render. The counts follow the library,
        // not the switch beside them, and `store.mcpEnabled` renders itself, so
        // there is nothing here to re-read when the toggle moves; watching it
        // would also race `ConfigStore`'s 500 ms save debounce and read back the
        // value the owner just changed away from.
        .onAppear { Task { await mcp.refresh() } }
    }

    // MARK: - Model Context Protocol (AUTO3)

    /// The one place the owner can see what an outside AI tool can reach.
    ///
    /// Every other integration here answers "where does meeting-pipe write?".
    /// This one answers the inverse and harder question: an MCP client decides
    /// what to *pull*, so the app is no longer the party choosing what leaves.
    /// The control therefore leads with the two counts rather than with the
    /// switch: a fail-closed filter is only trustworthy if the number it
    /// withholds is a number you can read, and it comes from `mp.visibility`,
    /// the same function the server enforces, rather than a Swift recount.
    private var mcpGroup: some View {
        SettingsGroup("Model Context Protocol") {
            SettingsToggleRow(
                "Let AI tools read your meetings",
                sublabel: "Runs a read-only server on standard input and output when a tool you configured launches it. No port is opened and nothing on your network can reach it.",
                isOn: $store.mcpEnabled,
                showsDivider: false
            )
            SettingsRow("Reachable", sublabel: mcpVisibleSublabel) {
                if let status = mcp.status {
                    SettingsStatusPill(
                        tone: status.visible > 0 ? .granted : .neutral,
                        icon: "books.vertical.fill",
                        text: "\(status.visible) meeting\(status.visible == 1 ? "" : "s")"
                    )
                } else {
                    SettingsStatusPill(tone: .neutral, icon: "ellipsis", text: mcpPlaceholder)
                }
            }
            SettingsRow("Withheld", sublabel: mcpWithheldSublabel) {
                if let status = mcp.status {
                    SettingsStatusPill(
                        tone: status.withheld > 0 ? .needed : .neutral,
                        icon: "lock.fill",
                        text: "\(status.withheld) meeting\(status.withheld == 1 ? "" : "s")"
                    )
                } else {
                    SettingsStatusPill(tone: .neutral, icon: "ellipsis", text: mcpPlaceholder)
                }
            }
            // Stacked, not inline. `SettingsRow`'s trailing slot is fixed to its
            // ideal width by UX43, which is right for a button or a pill and wrong
            // for a list whose length the server decides: the five real tool names
            // joined with commas are 73 characters of mono, about 482pt, in a row
            // 512pt across, and the 30pt left over is where "Tools" started
            // wrapping one character per line. Chips through the shared `FlowLayout`,
            // the same treatment the auto-record allowlist gives bundle ids, so
            // identifiers read alike across the pane and any number of tools wraps
            // rather than riding off the edge of the card.
            SettingsStackRow("Tools", sublabel: "Read-only. There is no tool that can change, publish, or delete anything.") {
                if let tools = mcp.status?.tools, !tools.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(tools, id: \.self) { SettingsTag($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // The same placeholder the two count rows above use. The old
                    // fallback here hardcoded "search, read, list", three names the
                    // server does not have, copied from the design kit's stand-in.
                    SettingsStatusPill(tone: .neutral, icon: "ellipsis", text: mcpPlaceholder)
                }
            }
        } footer: {
            if let error = mcp.error {
                FailureNotice(failure: FailurePresentation(diagnostics: error, operation: .integrations, title: "Couldn't read the server status"))
            } else { Text(mcpFooter) }
        }
    }

    private var mcpPlaceholder: String {
        mcp.isLoading ? "Counting…" : "Unknown"
    }

    private var mcpVisibleSublabel: String {
        "What a connected tool can search and read."
    }

    private var mcpWithheldSublabel: String {
        guard let status = mcp.status, status.withheld > 0 else {
            return "NDA meetings, and meetings recorded before workflows existed, are never exposed."
        }
        return "\(status.withheldExplanation). To a connected tool these look like meetings that do not exist."
    }

    private var mcpFooter: String {
        if let status = mcp.status, !status.sdkAvailable {
            return "The MCP package is not installed, so the server cannot start yet. Run `cd pipeline && uv sync --extra mcp`, or re-run scripts/install.sh."
        }
        return "Point your AI tool at `mp mcp-serve` to connect it. Anything it reads has left this Mac and reached that tool's provider, which is why this is off until you turn it on, and why the withheld meetings stay withheld with no override."
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
