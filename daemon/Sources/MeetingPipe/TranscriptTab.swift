import AppKit
import Combine
import SwiftUI

/// Speaker-labeled transcript with click-to-seek and current-line highlight (TECH-A6). Segments from `<stem>.json` (whisperx/mlx-whisper `{start, end, text, speaker?}`). Uses the parent-owned `AudioPlaybackController` shared with the Audio tab (A7) so flipping tabs keeps the same play head.

// MARK: - Segment model

/// One parsed transcript segment.
struct TranscriptSegment: Identifiable, Hashable {
    let index: Int
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    /// Raw speaker label from the JSON (e.g. `"speaker_0"`). nil when diarization was disabled or failed.
    let speakerID: String?

    var id: Int { index }

    /// True when `time` falls within `[start, end)`. Half-open so adjacent segments don't both claim the boundary tick.
    func contains(_ time: TimeInterval) -> Bool {
        return time >= start && time < end
    }
}

enum TranscriptSegmentLookup {
    /// Index of the segment containing `time`. Gaps (silence, etc.) return the last segment before `time` so the UI keeps a row highlighted. Returns nil only when the array is empty or `time` precedes the first segment.
    static func index(at time: TimeInterval, in segments: [TranscriptSegment]) -> Int? {
        guard !segments.isEmpty else { return nil }
        if time < segments[0].start { return nil }
        // Binary search; pipeline output is sorted by start time.
        var lo = 0
        var hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segments[mid].start <= time {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }
}

/// Loads `<stem>.json` off-main and overlays transcript corrections.
enum TranscriptLoader {
    struct Result {
        let segments: [TranscriptSegment]
        let language: String?
        let speakerOrder: [String]   // speaker IDs in first-seen order
    }

    static func load(stem: String, in directory: URL) -> Result? {
        let url = directory.appendingPathComponent("\(stem).json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let parsed = parse(obj)
        let corrections = TranscriptCorrectionStore.read(stem: stem, in: directory)
        let overlaid = TranscriptCorrectionStore.apply(
            corrections: corrections,
            to: parsed.segments
        )
        return Result(
            segments: overlaid,
            language: parsed.language,
            speakerOrder: parsed.speakerOrder
        )
    }

    /// Parses the transcript JSON payload. Internal so tests can drive it directly.
    static func parse(_ obj: [String: Any]) -> Result {
        let language = obj["language"] as? String
        var out: [TranscriptSegment] = []
        var order: [String] = []
        var seen: Set<String> = []
        if let arr = obj["segments"] as? [[String: Any]] {
            out.reserveCapacity(arr.count)
            for (i, raw) in arr.enumerated() {
                guard let start = (raw["start"] as? NSNumber)?.doubleValue,
                      let end = (raw["end"] as? NSNumber)?.doubleValue,
                      let text = raw["text"] as? String else {
                    continue
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                let speaker = raw["speaker"] as? String
                if let s = speaker, !seen.contains(s) {
                    seen.insert(s)
                    order.append(s)
                }
                out.append(TranscriptSegment(
                    index: i,
                    start: start,
                    end: max(end, start + 0.001),
                    text: trimmed,
                    speakerID: speaker
                ))
            }
        }
        return Result(
            segments: out,
            language: (language?.isEmpty == true) ? nil : language,
            speakerOrder: order
        )
    }
}

// MARK: - Display helpers

enum TranscriptDisplay {
    /// Maps `"speaker_0"` to `"Speaker 1"` (one-based for human readability).
    static func displayName(for speakerID: String?) -> String {
        guard let id = speakerID, !id.isEmpty else { return "Unknown" }
        if id.hasPrefix("speaker_"),
           let n = Int(id.dropFirst("speaker_".count)) {
            return "Speaker \(n + 1)"
        }
        return id
    }

    /// Stable tint per speaker so list reordering doesn't reshuffle colors.
    static func color(for speakerID: String?) -> Color {
        guard let id = speakerID, !id.isEmpty else { return .secondary }
        let palette: [Color] = MPColors.speakerPalette.map { Color(nsColor: $0) }
        if id.hasPrefix("speaker_"),
           let n = Int(id.dropFirst("speaker_".count)) {
            return palette[n % palette.count]
        }
        return palette[abs(id.hashValue) % palette.count]
    }

    /// `mm:ss` / `h:mm:ss` - matches the Library row duration format.
    static func timestamp(_ time: TimeInterval) -> String {
        let total = Int(time.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Transcript tab view

struct TranscriptTab: View {
    @ObservedObject var playback: AudioPlaybackController
    let meeting: Meeting

    @State private var segments: [TranscriptSegment] = []
    @State private var language: String? = nil
    @State private var loadedForStem: String? = nil
    @State private var loading: Bool = true
    /// Segment whose edit sheet is open; nil when no sheet is showing.
    @State private var editingSegment: TranscriptSegment? = nil

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            PlaybackBar(playback: playback)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .task(id: meeting.stem) {
            await reload()
            playback.load(url: meeting.wavURL)
        }
        .sheet(item: $editingSegment) { seg in
            TranscriptLineEditor(
                segment: seg,
                onSave: { newText in
                    saveCorrection(for: seg, newText: newText)
                    editingSegment = nil
                },
                onCancel: { editingSegment = nil }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading && loadedForStem != meeting.stem {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if segments.isEmpty {
            emptyState
        } else {
            TranscriptList(
                segments: segments,
                language: language,
                playback: playback,
                onEdit: { seg in editingSegment = seg }
            )
        }
    }

    /// Persists the edit and patches the in-memory segment so the row updates without a full reload.
    private func saveCorrection(for segment: TranscriptSegment, newText: String) {
        let edited = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        let pipelineOriginal = segment.text
        do {
            _ = try TranscriptCorrectionStore.upsert(
                segmentIndex: segment.index,
                pipelineOriginal: pipelineOriginal,
                edited: edited,
                stem: meeting.stem,
                in: meeting.recordingsDir
            )
        } catch {
            Log.event(category: "correction", action: "transcript_correction_failed",
                      attributes: [
                        "stem": meeting.stem,
                        "segment_index": segment.index,
                        "error": error.localizedDescription,
                      ])
            return
        }
        Log.event(category: "correction", action: "transcript_correction",
                  attributes: [
                    "stem": meeting.stem,
                    "segment_index": segment.index,
                    "original_text": pipelineOriginal,
                    "edited_text": edited,
                  ])
        // Patch in-memory list immediately. Reverting to original drops the override from the store; we apply the same resolution the loader does so the text flips back too.
        if let i = segments.firstIndex(where: { $0.index == segment.index }) {
            segments[i] = TranscriptSegment(
                index: segment.index,
                start: segment.start,
                end: segment.end,
                text: edited.isEmpty ? pipelineOriginal : edited,
                speakerID: segment.speakerID
            )
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(meeting.status == .done
                 ? "No transcript on disk for this meeting."
                 : "Transcript appears once the pipeline finishes.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    @MainActor
    private func reload() async {
        let stem = meeting.stem
        let dir = meeting.recordingsDir
        loading = true
        let result = await Task.detached(priority: .userInitiated) {
            TranscriptLoader.load(stem: stem, in: dir)
        }.value
        guard meeting.stem == stem else { return }
        segments = result?.segments ?? []
        language = result?.language
        loadedForStem = stem
        loading = false
    }
}

// MARK: - List

private struct TranscriptList: View {
    let segments: [TranscriptSegment]
    let language: String?
    @ObservedObject var playback: AudioPlaybackController
    /// Called on "Edit text" context-menu action; the host owns sheet presentation.
    let onEdit: (TranscriptSegment) -> Void

    /// Index of the segment containing the playback head. Updated via `onChange` so the binary search runs at most once per tick.
    @State private var activeIndex: Int? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if let lang = language {
                        Text("Language: \(lang)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    }
                    ForEach(segments) { seg in
                        TranscriptRow(
                            segment: seg,
                            isActive: seg.index == activeIndex,
                            onTap: { playback.playFrom(seg.start) },
                            onEdit: { onEdit(seg) }
                        )
                        .id(seg.index)
                    }
                }
                .padding(.bottom, 12)
            }
            .onChange(of: playback.currentTime) { _, t in
                let newIdx = TranscriptSegmentLookup.index(at: t, in: segments)
                if newIdx != activeIndex {
                    activeIndex = newIdx
                    if playback.isPlaying, let idx = newIdx {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
    }
}

private struct TranscriptRow: View {
    let segment: TranscriptSegment
    let isActive: Bool
    let onTap: () -> Void
    let onEdit: () -> Void

    /// Reveals the per-line Edit pencil on hover so transcript correction is
    /// discoverable without the right-click menu (TECH-UX12).
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(TranscriptDisplay.color(for: segment.speakerID))
                    .frame(width: 8, height: 8)
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(TranscriptDisplay.displayName(for: segment.speakerID))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(TranscriptDisplay.color(for: segment.speakerID))
                        Text(TranscriptDisplay.timestamp(segment.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Text(segment.text)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive
                          ? Color.mpSignal.opacity(0.18)
                          : Color.clear)
                    .padding(.horizontal, 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Hover affordance lives in the empty space beside the speaker/timestamp
        // line, so it never overlaps wrapped body text. The overlay is a sibling
        // layer over the row button, so its tap goes to Edit, not to seek.
        .overlay(alignment: .topTrailing) {
            if isHovered {
                MPGhostIconButton(
                    systemImage: "pencil",
                    help: "Edit this line",
                    action: onEdit
                )
                .padding(.trailing, 10)
            }
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Edit text…", action: onEdit)
        }
    }
}

// MARK: - Line editor sheet

private struct TranscriptLineEditor: View {
    let segment: TranscriptSegment
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String

    init(segment: TranscriptSegment, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.segment = segment
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: segment.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(TranscriptDisplay.displayName(for: segment.speakerID))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TranscriptDisplay.color(for: segment.speakerID))
                Text(TranscriptDisplay.timestamp(segment.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                )
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: { onSave(text) })
                    .keyboardShortcut(.defaultAction)
                    .disabled(text == segment.text)
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 240)
    }
}

// MARK: - Playback bar

private struct PlaybackBar: View {
    @ObservedObject var playback: AudioPlaybackController
    /// Scrubber value while dragging; committed on release. Without this the slider fights the timer tick and jumps.
    @State private var dragValue: Double? = nil

    var body: some View {
        if let err = playback.loadError {
            Label(err, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 10) {
                Button {
                    playback.togglePlayPause()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                .buttonStyle(.borderless)

                Text(TranscriptDisplay.timestamp(displayedTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { displayedTime },
                        set: { v in dragValue = v }
                    ),
                    in: 0...max(playback.duration, 0.001),
                    onEditingChanged: { editing in
                        if !editing, let v = dragValue {
                            playback.seek(to: v)
                            dragValue = nil
                        }
                    }
                )

                Text(TranscriptDisplay.timestamp(playback.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
            }
        }
    }

    private var displayedTime: Double {
        dragValue ?? playback.currentTime
    }
}
