import AppKit
import SwiftUI

/// AI4: the weekly review digests, read-only. `mp digest` writes
/// `digest-<date>.summary.json/.md` into a `digests` sibling of the library (outside the
/// scanned `raw/` tree, so they never show in the meeting list).
///
/// The list of digests lives in the Library's center column (`DigestsView`); the selected
/// digest reads in the wide detail pane (`DigestReaderView`), the same split a meeting uses.
/// A whole-library digest can carry hundreds of actions, so it needs the full reading width,
/// not the narrow list column it used to be crammed into. A derived view over files (ADR 0003),
/// not a database of record. Offers Generate now + reveal + delete.

/// Shared state for the two digest columns: the scanned files, the selection, and the
/// generate/reload lifecycle. Held as a `@StateObject` by the Library root so the center list
/// and the detail reader observe the same selection (a `NavigationSplitView` composes them as
/// siblings, so the state has to live in their common parent).
@MainActor
final class DigestListModel: ObservableObject {
    @Published fileprivate var digests: [DigestFile] = []
    @Published fileprivate var selectedStem: String?
    @Published fileprivate var loading = true
    @Published fileprivate var generating = false

    fileprivate var selected: DigestFile? {
        digests.first { $0.stem == selectedStem }
    }

    /// Rescan the digests directory off-main, then adopt the result. Keeps the current
    /// selection if it still exists, otherwise selects the newest.
    fileprivate func reload(directory: URL?) {
        guard let dir = directory else {
            digests = []
            loading = false
            return
        }
        loading = true
        Task.detached(priority: .userInitiated) {
            let files = DigestFile.scan(dir)
            await MainActor.run {
                self.digests = files
                if self.selectedStem == nil || !files.contains(where: { $0.stem == self.selectedStem }) {
                    self.selectedStem = files.first?.stem
                }
                self.loading = false
            }
        }
    }
}

/// Center column: the list of weekly digests + Generate now. Selecting a row renders it in the
/// detail pane (`DigestReaderView`), the way selecting a meeting renders its detail.
struct DigestsView: View {
    @ObservedObject var model: DigestListModel
    let libraryModel: LibraryWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { model.reload(directory: libraryModel.digestsDirectory) }
    }

    private var header: some View {
        HStack {
            Text("Weekly digests")
                .font(.mpTextXS.weight(.semibold))
                .tracking(0.08 * 10)
                .textCase(.uppercase)
                .foregroundStyle(Color(MPColors.fgMuted))
            Spacer()
            Button(action: generate) {
                if model.generating {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Generate now", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.generating)
            .help("Run mp digest over your whole library now")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if model.loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.digests.isEmpty {
            emptyState
        } else {
            List(selection: $model.selectedStem) {
                ForEach(model.digests) { d in
                    DigestRow(digest: d)
                        .tag(d.stem)
                        .contextMenu {
                            Button("Reveal in Finder") { reveal(d) }
                            Button("Move to Trash…", role: .destructive) { trash(d) }
                        }
                }
            }
            .listStyle(.inset)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .font(.mpText2XL)
                .foregroundStyle(Color(MPColors.fgSubtle))
            Text("No digests yet.")
                .foregroundStyle(Color(MPColors.fgMuted))
            Text("Generate one now, or turn on a weekly schedule in Preferences → Pipeline.")
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgSubtle))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func generate() {
        model.generating = true
        Task { @MainActor in
            _ = await libraryModel.generateDigest()
            model.generating = false
            model.reload(directory: libraryModel.digestsDirectory)
        }
    }

    private func reveal(_ d: DigestFile) {
        NSWorkspace.shared.activateFileViewerSelecting([d.jsonURL])
    }

    private func trash(_ d: DigestFile) {
        for url in [d.jsonURL, d.mdURL] {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        if model.selectedStem == d.stem { model.selectedStem = nil }
        model.reload(directory: libraryModel.digestsDirectory)
    }
}

/// Detail pane: the selected digest, rendered with the standard summary view in the wide reading
/// column. Gets the full detail width (and full height) instead of the narrow, vertically-split
/// center column the reader used to share with the list.
struct DigestReaderView: View {
    @ObservedObject var model: DigestListModel

    var body: some View {
        if let sel = model.selected {
            ScrollView {
                SummaryRenderedView(summary: sel.summary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Select a digest to read it.")
                .foregroundStyle(Color(MPColors.fgMuted))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Model

private struct DigestFile: Identifiable {
    let stem: String
    let jsonURL: URL
    let mdURL: URL
    let date: Date?
    let summary: MeetingSummary

    var id: String { stem }

    var displayDate: String {
        guard let date else { return stem }
        return DigestFile.display.string(from: date)
    }

    static func scan(_ dir: URL) -> [DigestFile] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        var out: [DigestFile] = []
        for url in items where url.lastPathComponent.hasSuffix(".summary.json") {
            let stem = url.lastPathComponent.replacingOccurrences(of: ".summary.json", with: "")
            guard let summary = MeetingSummary.load(from: url) else { continue }
            out.append(DigestFile(
                stem: stem,
                jsonURL: url,
                mdURL: dir.appendingPathComponent("\(stem).summary.md"),
                date: parseDate(stem),
                summary: summary
            ))
        }
        // Newest first, by the date encoded in the stem (digest-YYYYMMDD).
        return out.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private static func parseDate(_ stem: String) -> Date? {
        guard stem.hasPrefix("digest-") else { return nil }
        return parser.date(from: String(stem.dropFirst("digest-".count)))
    }

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.setLocalizedDateFormatFromTemplate("EEEEMMMdyyyy")
        return f
    }()
}

private struct DigestRow: View {
    let digest: DigestFile

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(digest.displayDate)
                .foregroundStyle(Color(MPColors.fg))
            HStack(spacing: 6) {
                Text("\(digest.summary.actions.count) actions")
                Text("·")
                Text("\(digest.summary.decisions.count) decisions")
            }
            .font(.mpTextXS)
            .foregroundStyle(Color(MPColors.fgSubtle))
        }
        .padding(.vertical, 2)
    }
}
