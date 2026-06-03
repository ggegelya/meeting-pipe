import AppKit
import SwiftUI

/// Corrections tab (TECH-A8). Renders the on-disk correction record (verdict, edits, notes). Re-edit hands control back to the Summary tab (which owns the field surface). Revert restores `<stem>.summary.json` from `original_summary` and deletes the correction file; the Summary tab picks up the change on the next debounce tick.

struct CorrectionsTab: View {
    let meeting: Meeting
    /// Invoked by "Re-edit" to hand control back to the Summary tab's editor.
    /// The parent (a sheet off the "..." menu) closes the sheet and switches tab.
    var onReedit: () -> Void

    @State private var record: [String: Any]? = nil
    @State private var loadedForStem: String? = nil
    @State private var loading: Bool = true
    @State private var confirmingRevert: Bool = false
    @State private var revertError: String? = nil

    var body: some View {
        content
            .task(id: meeting.stem) { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if loading && loadedForStem != meeting.stem {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let rec = record {
            scrollBody(record: rec)
        } else {
            emptyState
        }
    }

    private func scrollBody(record: [String: Any]) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(record: record)
                    if let notes = (record["notes"] as? String), !notes.isEmpty {
                        section(title: "Notes", systemImage: "note.text") {
                            Text(notes)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    summarySections(record: record)
                }
                .padding(20)
            }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .alert(
            "Revert this summary?",
            isPresented: $confirmingRevert,
            actions: {
                Button("Revert", role: .destructive) { performRevert() }
                Button("Cancel", role: .cancel) { }
            },
            message: {
                Text("Restores the original LLM summary and deletes the correction record. The published page in Notion is not changed.")
            }
        )
    }

    // MARK: Header

    private func header(record: [String: Any]) -> some View {
        let verdict = (record["verdict"] as? String) ?? "edited"
        let backend = (record["backend"] as? String) ?? "?"
        let model = (record["model_id"] as? String) ?? "?"
        let ts = (record["ts"] as? String) ?? ""
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            verdictBadge(verdict)
            VStack(alignment: .leading, spacing: 2) {
                if !ts.isEmpty {
                    Text(prettyTimestamp(ts))
                        .font(.callout.weight(.medium))
                }
                HStack(spacing: 6) {
                    Text("\(backend) · \(model)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let err = revertError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    private func verdictBadge(_ verdict: String) -> some View {
        let (icon, tint, label): (String, Color, String)
        switch verdict {
        case "good":   (icon, tint, label) = ("hand.thumbsup.fill", .green, "Good")
        case "bad":    (icon, tint, label) = ("hand.thumbsdown.fill", .red, "Bad")
        case "edited": (icon, tint, label) = ("pencil.circle.fill", .blue, "Edited")
        default:       (icon, tint, label) = ("circle", .secondary, verdict.capitalized)
        }
        return HStack(spacing: 4) {
            Image(systemName: icon)
            Text(label).font(.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(tint.opacity(0.15))
        )
    }

    // MARK: Summary diff

    @ViewBuilder
    private func summarySections(record: [String: Any]) -> some View {
        let original = (record["original_summary"] as? [String: Any])
            .flatMap(MeetingSummary.init(jsonObject:)) ?? MeetingSummary()
        let corrected = (record["corrected_summary"] as? [String: Any])
            .flatMap(MeetingSummary.init(jsonObject:))
        if let corrected = corrected {
            HStack(alignment: .top, spacing: 16) {
                summaryPane(title: "Original", summary: original)
                Divider()
                summaryPane(title: "Corrected", summary: corrected)
            }
        } else {
            summaryPane(title: "Original", summary: original)
        }
    }

    private func summaryPane(title: String, summary: MeetingSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            CorrectionSummaryPreview(summary: summary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Revert…", role: .destructive) {
                confirmingRevert = true
            }
            Button("Re-edit in Summary tab") {
                onReedit()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Helpers

    private var correctionPath: URL? {
        try? CorrectionStore.path(forStem: meeting.stem)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "pencil")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No corrections yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Editing the Summary tab writes a record here so the LoRA training set has a paper trail.")
                .multilineTextAlignment(.center)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    @ViewBuilder
    private func section<C: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)
            content()
        }
    }

    @MainActor
    private func reload() async {
        let stem = meeting.stem
        loading = true
        revertError = nil
        let payload = await Task.detached(priority: .userInitiated) {
            CorrectionStore.read(stem: stem)
        }.value
        guard meeting.stem == stem else { return }
        record = payload
        loadedForStem = stem
        loading = false
    }

    private func performRevert() {
        guard let rec = record,
              let original = rec["original_summary"] as? [String: Any] else {
            revertError = "Nothing to revert - record is missing the original summary."
            return
        }
        let summaryURL = meeting.recordingsDir
            .appendingPathComponent("\(meeting.stem).summary.json")
        guard JSONSerialization.isValidJSONObject(original),
              let data = try? JSONSerialization.data(
                  withJSONObject: original,
                  options: [.prettyPrinted, .sortedKeys]
              ) else {
            revertError = "Original summary couldn't be re-serialized."
            return
        }
        do {
            try data.write(to: summaryURL, options: .atomic)
        } catch {
            revertError = "Couldn't write summary back: \(error.localizedDescription)"
            return
        }
        if let url = correctionPath {
            _ = try? FileManager.default.removeItem(at: url)
        }
        Log.event(category: "library", action: "correction_reverted", attributes: [
            "stem": meeting.stem,
        ])
        record = nil
    }

    private func prettyTimestamp(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let date = f.date(from: iso) {
            return MeetingFormatters.fullDateTime.string(from: date)
        }
        return iso
    }
}

// MARK: - Compact preview

/// Compact read-only summary preview for the original/corrected side-by-side panes. Full markdown rendering is in the Summary tab.
struct CorrectionSummaryPreview: View {
    let summary: MeetingSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !summary.title.isEmpty {
                Text(summary.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !nonEmpty(summary.summary).isEmpty {
                preview(label: "Summary", items: nonEmpty(summary.summary))
            }
            if !nonEmpty(summary.decisions).isEmpty {
                preview(label: "Decisions", items: nonEmpty(summary.decisions))
            }
            if !actionStrings.isEmpty {
                preview(label: "Actions", items: actionStrings)
            }
            if !nonEmpty(summary.questions).isEmpty {
                preview(label: "Open questions", items: nonEmpty(summary.questions))
            }
            if isEmpty {
                Text("(no content)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func nonEmpty(_ items: [String]) -> [String] {
        items.filter { !$0.isEmpty }
    }

    private var actionStrings: [String] {
        summary.actions.compactMap { a in
            guard !a.task.isEmpty else { return nil }
            let owner = a.owner ?? ""
            return owner.isEmpty ? a.task : "\(a.task) (\(owner))"
        }
    }

    private var isEmpty: Bool {
        summary.title.isEmpty
            && nonEmpty(summary.summary).isEmpty
            && nonEmpty(summary.decisions).isEmpty
            && actionStrings.isEmpty
            && nonEmpty(summary.questions).isEmpty
    }

    private func preview(label: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(.tertiary)
                    Text(item)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
