import AppKit
import SwiftUI

/// AI4: the weekly review digests, read-only. `mp digest` writes
/// `digest-<date>.summary.json/.md` into a `digests` sibling of the library (outside the
/// scanned `raw/` tree, so they never show in the meeting list). This lists them, renders
/// the selected one with the standard summary view, and offers Generate now + reveal +
/// delete. A derived view over files (ADR 0003), not a database of record. Rendered in the
/// Library's center column when the `.digests` rail scope is active.
struct DigestsView: View {
    @ObservedObject var model: LibraryWindowModel

    @State private var digests: [DigestFile] = []
    @State private var selectedStem: String?
    @State private var loading = true
    @State private var generating = false

    private var selected: DigestFile? {
        digests.first { $0.stem == selectedStem }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear(perform: reload)
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
                if generating {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Generate now", systemImage: "arrow.clockwise")
                }
            }
            .disabled(generating)
            .help("Run mp digest over your whole library now")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if digests.isEmpty {
            emptyState
        } else {
            VSplitView {
                List(selection: $selectedStem) {
                    ForEach(digests) { d in
                        DigestRow(digest: d)
                            .tag(d.stem)
                            .contextMenu {
                                Button("Reveal in Finder") { reveal(d) }
                                Button("Move to Trash…", role: .destructive) { trash(d) }
                            }
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 120, idealHeight: 180)

                if let sel = selected {
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
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 32))
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
        generating = true
        Task { @MainActor in
            _ = await model.generateDigest()
            generating = false
            reload()
        }
    }

    private func reveal(_ d: DigestFile) {
        NSWorkspace.shared.activateFileViewerSelecting([d.jsonURL])
    }

    private func trash(_ d: DigestFile) {
        for url in [d.jsonURL, d.mdURL] {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        if selectedStem == d.stem { selectedStem = nil }
        reload()
    }

    private func reload() {
        guard let dir = model.digestsDirectory else {
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
