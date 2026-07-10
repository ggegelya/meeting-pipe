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

/// Anchors flagged-moment markers (FEAT8) to the transcript segments they fall
/// in, so the tab can render a chip inline at each moment. Pure so it is unit
/// testable without the view.
enum TranscriptMarkerLayout {
    /// Map a segment's stable `.index` -> sorted marker offsets anchored to it.
    /// A marker before the first segment (or into a gap) anchors to the nearest
    /// segment at or before it, falling back to the first segment. Keyed by the
    /// segment id (not array position) so it composes with the row's `seg.index`
    /// even when empty segments were filtered out.
    static func assign(markers: [Double], to segments: [TranscriptSegment]) -> [Int: [Double]] {
        guard !segments.isEmpty else { return [:] }
        var out: [Int: [Double]] = [:]
        for t in markers.sorted() {
            let pos = TranscriptSegmentLookup.index(at: t, in: segments) ?? 0
            out[segments[pos].index, default: []].append(t)
        }
        return out
    }
}

/// Loads `<stem>.json` off-main and overlays transcript corrections.
enum TranscriptLoader {
    struct Result {
        let segments: [TranscriptSegment]
        let language: String?
        let speakerOrder: [String]   // speaker IDs in first-seen order
        /// Reversible speaker-label overrides (FEAT3-UNDO / FEAT3-SEGMENT). Resolved
        /// at display time, not baked into `segments`, so the raw diarization label
        /// stays recoverable. `.empty` from `parse` (no sidecar in a raw payload).
        var speakerOverlay: SpeakerLabelStore.Overlay = .empty
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
            speakerOrder: parsed.speakerOrder,
            speakerOverlay: SpeakerLabelStore.read(stem: stem, in: directory)
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
        if id.hasPrefix("THEM-") {
            let letter = id.dropFirst("THEM-".count)
            return letter.isEmpty ? "Unknown" : "Unknown \(letter)"
        }
        return id
    }

    /// True for the unnamed speakers the roster naming affordance can enroll:
    /// FEAT3-ROSTER unknown clusters (`THEM-A`) and raw diarization ids.
    static func isNameable(_ speakerID: String?) -> Bool {
        guard let id = speakerID, !id.isEmpty else { return false }
        return id.hasPrefix("THEM-") || id.hasPrefix("speaker_")
    }

    /// Stable tint per speaker so list reordering doesn't reshuffle colors.
    static func color(for speakerID: String?) -> Color {
        guard let id = speakerID, !id.isEmpty else { return Color(MPColors.fgMuted) }
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

/// A speaker label the roster naming sheet is open for (FEAT3-ROSTER). `currentName`
/// is set when re-opening to rename an already-named speaker (FEAT3-UNDO); nil for a
/// first naming.
struct NamingTarget: Identifiable {
    let label: String
    var currentName: String? = nil
    var id: String { label }
}

struct TranscriptTab: View {
    @ObservedObject var playback: AudioPlaybackController
    @EnvironmentObject private var libraryModel: LibraryWindowModel
    let meeting: Meeting

    @State private var segments: [TranscriptSegment] = []
    @State private var language: String? = nil
    /// Reversible speaker-label overrides (FEAT3-UNDO). Resolved at display time so
    /// the diarization label in `<stem>.json` is never overwritten.
    @State private var speakerOverlay: SpeakerLabelStore.Overlay = .empty
    /// Flagged-moment offsets (FEAT8) from `<stem>.markers.json`, rendered as
    /// anchor chips in the transcript.
    @State private var markers: [Double] = []
    @State private var loadedForStem: String? = nil
    @State private var loading: Bool = true
    /// Segment whose edit sheet is open; nil when no sheet is showing.
    @State private var editingSegment: TranscriptSegment? = nil
    /// Raw speaker label being named (FEAT3-ROSTER); nil when the sheet is closed.
    @State private var namingTarget: NamingTarget? = nil

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
            if let audio = meeting.audioURL {
                playback.load(url: audio)
            }
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
        .sheet(item: $namingTarget) { target in
            SpeakerNamingSheet(
                currentDisplay: target.currentName ?? TranscriptDisplay.displayName(for: target.label),
                isRename: target.currentName != nil,
                initialName: target.currentName ?? "",
                onSave: { name in
                    if let old = target.currentName {
                        renameSpeaker(label: target.label, oldName: old, newName: name)
                    } else {
                        nameSpeaker(label: target.label, name: name)
                    }
                },
                onCancel: { namingTarget = nil }
            )
        }
    }

    /// Enroll a speaker into the roster under `name` (FEAT3-ROSTER). Enrolls the
    /// voiceprint but leaves `<stem>.json` untouched, recording the name in the
    /// reversible overlay instead (FEAT3-UNDO); a reload then resolves the display.
    private func nameSpeaker(label: String, name: String) {
        namingTarget = nil
        Task {
            let result = await libraryModel.nameSpeaker(stem: meeting.stem, label: label, name: name)
            if case .success = result {
                await reload()
            }
        }
    }

    /// Undo a naming (FEAT3-UNDO): drop the overlay so the cluster reverts to its
    /// diarization label, and un-enroll the voiceprint so it no longer auto-names
    /// the voice in later meetings.
    private func undoNaming(label: String, name: String) {
        Task {
            _ = await libraryModel.undoSpeakerNaming(stem: meeting.stem, label: label, name: name)
            await reload()
        }
    }

    /// Rename an already-named speaker (FEAT3-UNDO): re-enroll under the new name,
    /// forget the old, and update the overlay.
    private func renameSpeaker(label: String, oldName: String, newName: String) {
        namingTarget = nil
        guard oldName != newName else { return }
        Task {
            _ = await libraryModel.renameSpeaker(
                stem: meeting.stem, label: label, oldName: oldName, newName: newName
            )
            await reload()
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
                markers: markers,
                overlay: speakerOverlay,
                playback: playback,
                onEdit: { seg in editingSegment = seg },
                onName: { label in namingTarget = NamingTarget(label: label) },
                onRename: { label, current in
                    namingTarget = NamingTarget(label: label, currentName: current)
                },
                onUndoName: { label, current in undoNaming(label: label, name: current) }
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
                .foregroundStyle(Color(MPColors.fgSubtle))
            Text(meeting.status == .done
                 ? "No transcript on disk for this meeting."
                 : "Transcript appears once the pipeline finishes.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(Color(MPColors.fgMuted))
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
        speakerOverlay = result?.speakerOverlay ?? .empty
        // Small sidecar; a synchronous read on main is fine, like the corrections overlay.
        markers = MarkerFile.read(stem: stem, in: dir)?.markers.map(\.tSeconds) ?? []
        loadedForStem = stem
        loading = false
    }
}

// MARK: - List

private struct TranscriptList: View {
    let segments: [TranscriptSegment]
    let language: String?
    /// Flagged-moment offsets (FEAT8), anchored to their segments for chips.
    let markers: [Double]
    /// Reversible speaker-label overrides (FEAT3-UNDO), resolved per row for display.
    let overlay: SpeakerLabelStore.Overlay
    @ObservedObject var playback: AudioPlaybackController
    /// Called on "Edit text" context-menu action; the host owns sheet presentation.
    let onEdit: (TranscriptSegment) -> Void
    /// Called on "Name this speaker" (FEAT3-ROSTER) with the raw speaker label.
    let onName: (String) -> Void
    /// Called on "Rename…" (FEAT3-UNDO) with the raw label and its current name.
    let onRename: (String, String) -> Void
    /// Called on "Undo naming" (FEAT3-UNDO) with the raw label and its current name.
    let onUndoName: (String, String) -> Void

    /// Index of the segment containing the playback head. Updated via `onChange` so the binary search runs at most once per tick.
    @State private var activeIndex: Int? = nil

    var body: some View {
        let markerMap = TranscriptMarkerLayout.assign(markers: markers, to: segments)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if let lang = language {
                        Text("Language: \(lang)")
                            .font(.caption)
                            .foregroundStyle(Color(MPColors.fgSubtle))
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    }
                    // Discoverability caption (DSN22 #10): the rows are clickable to
                    // edit or seek, which is not otherwise obvious.
                    Text("Click a line to edit or seek.")
                        .font(.mpTextXS)
                        .foregroundStyle(Color(MPColors.fgSubtle))
                        .padding(.horizontal, 16)
                        .padding(.top, language == nil ? 12 : 2)
                        .padding(.bottom, 4)
                    ForEach(segments) { seg in
                        if let times = markerMap[seg.index] {
                            MarkerChipsRow(times: times, onSeek: { playback.playFrom($0) })
                        }
                        TranscriptRow(
                            segment: seg,
                            overlay: overlay,
                            isActive: seg.index == activeIndex,
                            onTap: { playback.playFrom(seg.start) },
                            onEdit: { onEdit(seg) },
                            onName: onName,
                            onRename: onRename,
                            onUndoName: onUndoName
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

/// Inline flag chips (FEAT8) for the moments anchored to a transcript segment.
/// Each chip shows the moment's timestamp and seeks to it on click, reusing the
/// same `playFrom` path as a row tap.
private struct MarkerChipsRow: View {
    let times: [Double]
    let onSeek: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(times, id: \.self) { t in
                Button {
                    onSeek(t)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 9))
                        Text(TranscriptDisplay.timestamp(t))
                            .font(.caption.monospacedDigit())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.mpSignal.opacity(0.18)))
                    .foregroundStyle(Color.mpSignal)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Flagged moment at \(TranscriptDisplay.timestamp(t)). Click to play.")
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
}

private struct TranscriptRow: View {
    let segment: TranscriptSegment
    /// Reversible speaker-label overrides (FEAT3-UNDO); resolved for display + menu.
    let overlay: SpeakerLabelStore.Overlay
    let isActive: Bool
    let onTap: () -> Void
    let onEdit: () -> Void
    let onName: (String) -> Void
    let onRename: (String, String) -> Void
    let onUndoName: (String, String) -> Void

    /// Reveals the per-line Edit pencil on hover so transcript correction is
    /// discoverable without the right-click menu (TECH-UX12).
    @State private var isHovered = false

    /// The name shown for this speaker, resolved through the overlay so an in-app
    /// naming appears without rewriting `<stem>.json`.
    private var displayName: String {
        TranscriptDisplay.displayName(for: SpeakerLabelStore.displayLabel(for: segment, using: overlay))
    }

    /// The whole-cluster name assigned in-app (FEAT3-UNDO), or nil. Drives the menu:
    /// a named cluster offers rename/undo, an unnamed nameable one offers naming.
    private var clusterName: String? {
        segment.speakerID.flatMap { overlay.labels[$0] }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(TranscriptDisplay.color(for: segment.speakerID))
                    .frame(width: 8, height: 8)
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(TranscriptDisplay.color(for: segment.speakerID))
                        Text(TranscriptDisplay.timestamp(segment.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color(MPColors.fgSubtle))
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
        .onHover { hovering in
            isHovered = hovering
            // Pointer cursor so the line reads as clickable (DSN22 #10). macOS 14
            // floor rules out `.pointerStyle`, so push/pop the AppKit cursor.
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .contextMenu {
            Button("Edit text…", action: onEdit)
            if let raw = segment.speakerID {
                if let name = clusterName {
                    // FEAT3-UNDO: an in-app-named cluster is reversible.
                    Button("Rename…") { onRename(raw, name) }
                    Button("Undo naming", role: .destructive) { onUndoName(raw, name) }
                } else if TranscriptDisplay.isNameable(raw) {
                    Button("Name this speaker…") { onName(raw) }
                }
            }
        }
    }
}

/// Name-entry sheet for enrolling a diarized speaker into the roster (FEAT3-ROSTER),
/// reused for renaming an already-named speaker (FEAT3-UNDO).
private struct SpeakerNamingSheet: View {
    let currentDisplay: String
    let isRename: Bool
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String

    init(
        currentDisplay: String,
        isRename: Bool = false,
        initialName: String = "",
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.currentDisplay = currentDisplay
        self.isRename = isRename
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isRename ? "Rename \(currentDisplay)" : "Name \(currentDisplay)")
                .font(.headline)
            // FEAT3-UNDO name-time honesty: state plainly that this enrolls a
            // persistent voiceprint affecting future meetings, and that it is now
            // reversible from the same menu.
            Text("Enrolls this voice into your roster, so this person is named automatically in future meetings. You can undo the naming or remove them from your roster later from the speaker's right-click menu; the original diarization label is kept either way.")
                .font(.caption)
                .foregroundStyle(Color(MPColors.fgMuted))
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isRename ? "Rename" : "Save", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
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
                    .foregroundStyle(Color(MPColors.fgSubtle))
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
                .foregroundStyle(Color(MPColors.fgMuted))
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
                    .foregroundStyle(Color(MPColors.fgMuted))
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
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .frame(width: 48, alignment: .leading)
            }
        }
    }

    private var displayedTime: Double {
        dragValue ?? playback.currentTime
    }
}
