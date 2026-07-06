import AppKit
import SwiftUI

/// Right-pane detail view: editable header + three tabs (Summary TECH-A5, Transcript A6, Audio A7). Corrections (A8) is a sheet off the "..." menu and Raw files (A9) was dropped in the DSN2 IA pass.
struct MeetingDetailView: View {
    @EnvironmentObject var libraryModel: LibraryWindowModel
    let meeting: Meeting

    /// Loaded off-main via `.task(id:)`. Caching avoids `Data(contentsOf:)` on the main thread on every observable change, which beach-balled the UI during recording.
    @State var cachedNotionURL: URL? = nil
    @State var cachedObsidianURL: URL? = nil
    @State var publishURLsLoadedForStem: String? = nil

    /// Persisted so reopening the window keeps the user's tab. A stem-keyed default would be over-engineered for a personal product.
    @AppStorage("MeetingDetailSelectedTab") var selectedTab: String = Tab.summary.rawValue

    @State var editingTitle: String = ""
    @State var lastSyncedStem: String = ""

    /// TECH-UI-5: click-to-rename. The title shows as static text until clicked
    /// (or Return is pressed with nothing else focused), then swaps to a field.
    @State var isRenamingTitle = false
    @FocusState var titleFieldFocused: Bool
    /// Bumped by the toolbar menu's "Edit summary" to ask `SummaryTab` to enter
    /// edit mode, since that edit state lives inside the child tab.
    @State var summaryEditToken = 0

    /// Corrections moved from a tab to a sheet off the "..." menu (DSN2).
    @State var showCorrectionsSheet = false

    /// Shared across Transcript (A6) and Audio (A7) so click-to-seek keeps the same play head when flipping tabs. Re-attached on stem change via `.task(id:)`.
    @StateObject var playback = AudioPlaybackController()

    enum Tab: String, CaseIterable {
        case summary
        case transcript
        case audio

        var label: String {
            switch self {
            case .summary:     return "Summary"
            case .transcript:  return "Transcript"
            case .audio:       return "Audio"
            }
        }

        var systemImage: String {
            switch self {
            case .summary:     return "text.alignleft"
            case .transcript:  return "text.bubble"
            case .audio:       return "waveform"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            tabStrip
            Divider().overlay(Color(MPColors.borderFaint))
            tabContent
        }
        .frame(minWidth: LibraryLayout.detailMinWidth)
        .onAppear { syncEditingTitle(force: true) }
        .onChange(of: meeting.stem) { _, _ in syncEditingTitle(force: true) }
        .onChange(of: meeting.displayTitle) { _, _ in syncEditingTitle(force: false) }
        .task(id: meeting.stem) { await reloadPublishURLs() }
        .sheet(isPresented: $showCorrectionsSheet) { correctionsSheet }
    }

    /// Corrections surface, presented as a sheet from the "..." menu (DSN2). The
    /// "Re-edit" action closes the sheet and jumps to the Summary tab's editor.
    private var correctionsSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Corrections").font(.headline)
                Spacer()
                Button("Done") { showCorrectionsSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            CorrectionsTab(meeting: meeting) {
                showCorrectionsSheet = false
                selectedTab = Tab.summary.rawValue
                summaryEditToken += 1
            }
            .environmentObject(libraryModel)
        }
        .frame(width: 720, height: 560)
    }

    // MARK: Tab strip

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.rawValue) { tab in
                tabButton(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    private func tabButton(_ tab: Tab) -> some View {
        let isActive = selectedTab == tab.rawValue
        return Button {
            selectedTab = tab.rawValue
        } label: {
            VStack(spacing: 0) {
                Text(tab.label)
                    .font(.mpTextSM.weight(.medium))
                    .foregroundStyle(isActive ? Color(MPColors.fg) : Color(MPColors.fgMuted))
                    .padding(.vertical, 9)
                Rectangle()
                    .fill(isActive ? Color(MPColors.signal600) : Color.clear)
                    .frame(height: 1.5)
                    .cornerRadius(0.75)
            }
            .padding(.horizontal, 0)
            .padding(.trailing, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case Tab.summary.rawValue:     summaryTab
        case Tab.transcript.rawValue:  transcriptTab
        case Tab.audio.rawValue:       audioTab
        default:                       summaryTab
        }
    }

    // MARK: Tabs

    private var summaryTab: some View {
        SummaryTab(store: libraryModel.meetingStore, meeting: meeting, editToken: summaryEditToken)
            .environmentObject(libraryModel)
    }

    private var transcriptTab: some View {
        TranscriptTab(playback: playback, meeting: meeting)
    }

    private var audioTab: some View {
        AudioTab(playback: playback, meeting: meeting)
    }

    // MARK: Publish-target URLs

    @MainActor
    private func reloadPublishURLs() async {
        let stem = meeting.stem
        let notionPath = meeting.recordingsDir.appendingPathComponent("\(stem).notion.json")
        let obsidianPath = meeting.recordingsDir.appendingPathComponent("\(stem).obsidian.json")

        let (notion, obsidian) = await Task.detached(priority: .userInitiated) {
            (PublishURLs.notion(at: notionPath), PublishURLs.obsidian(at: obsidianPath))
        }.value

        if meeting.stem == stem {
            cachedNotionURL = notion
            cachedObsidianURL = obsidian
            publishURLsLoadedForStem = stem
        }
    }
}

/// Publish-target sidecar parsers. Kept outside the View so they aren't inferred as main-actor-isolated; the loader calls them from a detached Task.
enum PublishURLs {
    static func notion(at path: URL) -> URL? {
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = obj["page_url"] as? String else {
            return nil
        }
        return URL(string: s)
    }

    /// Builds `obsidian://open?vault=...&file=...` from `<stem>.obsidian.json`. Returns nil when the sidecar is missing or the vault relationship can't be resolved.
    static func obsidian(at path: URL) -> URL? {
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let notePath = obj["note_path"] as? String,
              let vault = obj["vault"] as? String else {
            return nil
        }
        let vaultURL = URL(fileURLWithPath: vault)
        let noteURL = URL(fileURLWithPath: notePath)
        guard let rel = relativePath(of: noteURL, from: vaultURL) else { return nil }
        let vaultName = vaultURL.lastPathComponent
        var comps = URLComponents()
        comps.scheme = "obsidian"
        comps.host = "open"
        comps.queryItems = [
            URLQueryItem(name: "vault", value: vaultName),
            URLQueryItem(name: "file", value: rel),
        ]
        return comps.url
    }

    static func relativePath(of file: URL, from base: URL) -> String? {
        let fileComps = file.standardizedFileURL.pathComponents
        let baseComps = base.standardizedFileURL.pathComponents
        guard fileComps.count > baseComps.count else { return nil }
        guard Array(fileComps.prefix(baseComps.count)) == baseComps else { return nil }
        return fileComps.suffix(from: baseComps.count).joined(separator: "/")
    }
}

// MARK: - Summary tab (TECH-A5)
