import AppKit
import SwiftUI

/// Right-pane detail view: editable header + three tabs (Summary TECH-A5, Transcript A6, Audio A7). Corrections (A8) is a sheet off the "..." menu and Raw files (A9) was dropped in the DSN2 IA pass.
struct MeetingDetailView: View {
    @EnvironmentObject var libraryModel: LibraryWindowModel
    /// UX53: observed for the same reason `SummaryTab` and `TranscriptTab` observe
    /// it. The header's two Open buttons are the one thing in this pane read off
    /// disk rather than off `Meeting`, so without a subscription here a finished
    /// republish refreshed the publish-state line (rebuilt by the scan) and left
    /// the buttons beside it a run behind. Reaching through
    /// `libraryModel.meetingStore` reads the value without subscribing to it.
    @ObservedObject var store: MeetingStore
    let meeting: Meeting

    /// Loaded off-main via `.task(id:)`. Caching avoids `Data(contentsOf:)` on the main thread on every observable change, which beach-balled the UI during recording.
    @State var cachedNotionURL: URL? = nil
    @State var cachedObsidianURL: URL? = nil
    /// UX62: the filesystem or LAN note this run published, off
    /// `<stem>.publish.json`. The default workflow is filesystem-only, so for
    /// most meetings this is the *only* Open affordance there is.
    @State var cachedLocalNote: (sink: PublishSink, url: URL)? = nil
    @State var publishURLsLoadedForStem: String? = nil
    /// Sidecar modification dates the cached URLs were read from (UX53), so a store
    /// revision bump caused by another meeting's write costs two `stat` calls
    /// instead of two JSON parses.
    @State var loadedPublishFingerprint: [Date?]? = nil

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

    /// FEAT10: a transcript time the Summary tab asked us to reveal, set when an
    /// evidence chip is clicked. Lives here because the jump crosses tabs: the
    /// Summary tab raises it, the tab switch happens, and the Transcript tab
    /// consumes it once its segments are loaded.
    @State var pendingTranscriptSeek: Double? = nil

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
            chromeBand
            Divider().overlay(Color(MPColors.borderStrong))
            tabContent
        }
        .frame(minWidth: LibraryLayout.detailMinWidth)
        .onAppear {
            syncEditingTitle(force: true)
            consumeTranscriptJump()
        }
        .onChange(of: meeting.stem) { _, _ in
            syncEditingTitle(force: true)
            consumeTranscriptJump()
        }
        .onChange(of: libraryModel.pendingTranscriptJump) { _, _ in consumeTranscriptJump() }
        .onChange(of: meeting.displayTitle) { _, _ in syncEditingTitle(force: false) }
        .task(id: PublishURLsReloadKey(stem: meeting.stem, revision: store.revision)) {
            await reloadPublishURLs()
        }
        .sheet(isPresented: $showCorrectionsSheet) { correctionsSheet }
    }

    /// AUTO2: a `meetingpipe://open?stem=&t=` citation link from a published note
    /// that the root view resolved to this meeting. Consumed here, not there,
    /// because the seek and the tab both live in this view; the stem guard is
    /// what keeps a request meant for another meeting from seeking in this one.
    private func consumeTranscriptJump() {
        guard let jump = libraryModel.pendingTranscriptJump, jump.stem == meeting.stem else { return }
        libraryModel.pendingTranscriptJump = nil
        // Same order the evidence chip uses: raise the request first, then switch
        // tabs, so the Transcript tab already sees it in its `onAppear`.
        pendingTranscriptSeek = jump.seek
        selectedTab = Tab.transcript.rawValue
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

    // MARK: Chrome band

    /// Title, metadata, provenance and the tab strip, banded together as the
    /// pane's chrome rather than as its first content (UX36).
    ///
    /// The band is *recessed* (`bgSunk`), not raised. It shipped on `bgRaised`
    /// first, an 11-of-255 step off the dark canvas that could not be found in
    /// the owner's screenshot, and a band nobody can see licenses nothing. A
    /// toolbar that sinks is also the direction the mac's own chrome takes, and
    /// it leaves `bgRaised` free to mean content surfaces. Its bottom hairline
    /// is the `Divider` under the tabs, drawn `borderStrong` so the step reads
    /// as an edge rather than a smudge.
    ///
    /// The alternative, putting the header on the Summary body's reading column,
    /// was rejected after tracing the other two tabs: `TranscriptTab` and
    /// `AudioTab` are full-width, so a header indented to the summary's measure
    /// would be misaligned against them the moment the tab changed. Instead the
    /// chrome spans, and the *content* now shares one left edge on every tab,
    /// which `LibraryLayout.detailMaxWidth` is what makes affordable.
    private var chromeBand: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            tabStrip
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(MPColors.bgSunk))
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
            // The underline is an overlay on the label, not a sibling in a
            // `VStack`. As a sibling it was a bare `Rectangle`, which is a greedy
            // shape: with no width constraint it took every point offered, which
            // made each tab button greedy, which let the three of them divide the
            // whole pane and starved the trailing `Spacer`. The strip read as
            // left-aligned in source and rendered as three tabs spread across
            // 1230pt with an underline far wider than its word (UX36). As an
            // overlay it sizes to the text, which is what a tab underline means.
            Text(tab.label)
                .font(.mpTextSM.weight(.medium))
                .foregroundStyle(isActive ? Color(MPColors.fg) : Color(MPColors.fgMuted))
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isActive ? Color(MPColors.signal600) : Color.clear)
                        .frame(height: 1.5)
                        .cornerRadius(0.75)
                }
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
        SummaryTab(
            store: libraryModel.meetingStore,
            meeting: meeting,
            editToken: summaryEditToken,
            onJumpToTranscript: { time in
                // Order matters: raise the request first, then switch, so the
                // Transcript tab already sees it in its `onAppear`.
                pendingTranscriptSeek = time
                selectedTab = Tab.transcript.rawValue
            }
        )
        .environmentObject(libraryModel)
    }

    private var transcriptTab: some View {
        // UX52: the store is handed down like `SummaryTab`'s, so a rescan (the
        // signal a finished re-transcribe publishes) re-runs the transcript's
        // reload rather than waiting for a tab switch to rebuild the pane.
        TranscriptTab(
            playback: playback,
            store: libraryModel.meetingStore,
            meeting: meeting,
            pendingSeek: $pendingTranscriptSeek
        )
    }

    private var audioTab: some View {
        AudioTab(playback: playback, meeting: meeting)
    }

    // MARK: Publish-target URLs

    /// Identity for the publish-URL reload task (UX53): re-read when the stem
    /// changes OR when the store re-scanned, so a republish that just wrote
    /// `<stem>.notion.json` puts the Open button on the header the reader is
    /// already looking at. Keyed on the stem alone it never re-ran, and the
    /// publish-state line beside it did refresh (the scan rebuilds `Meeting`), so
    /// the header said "published" while offering nothing to open. Same shape as
    /// `SummaryTab.SummaryReloadKey` and `TranscriptTab.TranscriptReloadKey`; the
    /// fingerprint guard in `reloadPublishURLs` makes an unrelated rescan a no-op.
    private struct PublishURLsReloadKey: Equatable {
        let stem: String
        let revision: Int
    }

    @MainActor
    private func reloadPublishURLs() async {
        let stem = meeting.stem
        let dir = meeting.recordingsDir
        let fingerprint = PublishURLs.fingerprint(stem: stem, in: dir)
        // Already showing this stem's sidecars as they are on disk, so a revision
        // bump from another meeting's write changes nothing and must not re-parse.
        if publishURLsLoadedForStem == stem, loadedPublishFingerprint == fingerprint { return }
        let notionPath = PublishURLs.notionPath(stem: stem, in: dir)
        let obsidianPath = PublishURLs.obsidianPath(stem: stem, in: dir)

        let (notion, obsidian, local) = await Task.detached(priority: .userInitiated) {
            (
                PublishURLs.notion(at: notionPath),
                PublishURLs.obsidian(at: obsidianPath),
                PublishURLs.localNote(stem: stem, in: dir)
            )
        }.value

        if meeting.stem == stem {
            cachedNotionURL = notion
            cachedObsidianURL = obsidian
            cachedLocalNote = local
            publishURLsLoadedForStem = stem
            loadedPublishFingerprint = fingerprint
        }
    }
}

/// Publish-target sidecar parsers. Kept outside the View so they aren't inferred as main-actor-isolated; the loader calls them from a detached Task.
enum PublishURLs {
    static func notionPath(stem: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(stem).notion.json")
    }

    static func obsidianPath(stem: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(stem).obsidian.json")
    }

    /// UX62: the third Open button's source. Unlike the two above it this is the
    /// run's own publish sidecar, which is what makes a filesystem or LAN publish
    /// openable at all.
    static func publishPath(stem: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(stem).publish.json")
    }

    /// Modification dates of every sidecar the header's Open buttons are built
    /// from (UX53), in a fixed order, absent entries included as nil.
    ///
    /// All three of them, not one: the buttons are independent, a workflow can
    /// publish to any of these sinks or several, and a guard watching only the
    /// Notion sidecar would skip the reload for an Obsidian-only publish, which
    /// is the stale button UX53 removed. `<stem>.publish.json` joined the list in
    /// UX62, when it stopped being a file "nothing here reads": the local-note
    /// button is built from it, so a filesystem publish landing while the header
    /// is open has to invalidate this or that button never appears.
    static func fingerprint(stem: String, in directory: URL) -> [Date?] {
        [
            notionPath(stem: stem, in: directory),
            obsidianPath(stem: stem, in: directory),
            publishPath(stem: stem, in: directory),
        ].map { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
    }

    /// The local or LAN note this run published, for the header's third Open
    /// button (UX62). Off `<stem>.publish.json` via `PublishResult.load`, the
    /// read `daemon/CLAUDE.md` names, never a per-sink sidecar.
    static func localNote(stem: String, in directory: URL) -> (sink: PublishSink, url: URL)? {
        PublishLanding.localNote(publish: PublishResult.load(stem: stem, in: directory))
    }

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
