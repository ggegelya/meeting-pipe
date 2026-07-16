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
        /// Diarization clusters that carry a voiceprint in `<stem>.embeddings.json`,
        /// i.e. the labels `mp roster enroll` can actually enroll. A label absent
        /// here (a `speaker_unknown` junk-drawer line, a raw id that never clustered)
        /// has no voice to remember, so the row offers per-line assignment instead of
        /// cluster enrollment. Enrolling one used to hard-fail with "pipeline exited 2".
        var voiceprintLabels: Set<String> = []
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
            speakerOverlay: SpeakerLabelStore.read(stem: stem, in: directory),
            voiceprintLabels: MeetingStore.voiceprintLabels(stem: stem, in: directory)
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
        // The diarizer's catch-all bucket. Without this it fell through to the
        // pass-through below and rendered the raw internal id, so the transcript
        // showed literal "speaker_unknown" rows to the user.
        if id == "speaker_unknown" { return "Unknown speaker" }
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

/// A batch of segments the "New person..." label-only sheet is open for
/// (FEAT3-SEGMENT). Distinct from `NamingTarget`: this assigns a typed name to
/// specific lines through the overlay and enrolls no voiceprint, so it works for
/// `speaker_unknown` lines and people who were never diarized.
struct AssignNewTarget: Identifiable {
    let indices: [Int]
    var id: String { indices.map(String.init).joined(separator: ",") }
}

/// A transcript-row click, classified by held modifiers (FEAT3-SEGMENT multi-select):
/// plain seeks, Cmd toggles the segment in the selection, Shift extends the range.
enum SegmentClick { case plain, command, shift }

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
    /// Diarization clusters with a voiceprint (FEAT3-ROSTER): the labels that can be
    /// enrolled. A label absent here gets per-line assignment, not cluster naming.
    @State private var voiceprintLabels: Set<String> = []
    /// The meeting's resolved people (FEAT3-SEGMENT), recomputed only when the
    /// segments or the overlay change. Deliberately NOT derived inside the list's
    /// `body`: that rebuilt it on every playback tick, which churned the context
    /// menu's content and stopped the "Assign to..." submenu from opening at all
    /// while audio was playing.
    @State private var cast: [CastMember] = []
    /// Pauses playback on a right-click so the context menu opens against a still
    /// list (see `installRightClickPause`).
    @State private var rightClickMonitor: Any? = nil
    @State private var loadedForStem: String? = nil
    @State private var loading: Bool = true
    /// Segment whose edit sheet is open; nil when no sheet is showing.
    @State private var editingSegment: TranscriptSegment? = nil
    /// Raw speaker label being named (FEAT3-ROSTER); nil when the sheet is closed.
    @State private var namingTarget: NamingTarget? = nil
    /// Segments being assigned to a typed-in new person (FEAT3-SEGMENT); nil when closed.
    @State private var assignNewTarget: AssignNewTarget? = nil

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
                mode: target.currentName != nil ? .rename : .enroll,
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
        .sheet(item: $assignNewTarget) { target in
            SpeakerNamingSheet(
                currentDisplay: target.indices.count == 1 ? "this line" : "these \(target.indices.count) lines",
                mode: .assignNew,
                initialName: "",
                onSave: { name in
                    reassign(indices: target.indices, toLabel: name)
                    assignNewTarget = nil
                },
                onCancel: { assignNewTarget = nil }
            )
        }
        // Hold the transcript still while a sheet is open (FEAT3): naming or editing
        // a line while playback keeps scrolling the list out from under the cursor
        // is the friction that forced a manual pause every time.
        .onChange(of: editingSegment != nil || namingTarget != nil || assignNewTarget != nil) { _, open in
            if open { playback.pause() }
        }
        .onAppear { installRightClickPause() }
        .onDisappear { removeRightClickPause() }
    }

    /// Pause playback the moment a right-click lands, so the context menu opens
    /// against a still list.
    ///
    /// The menu is built from live state, so every `playback.currentTime` tick
    /// re-evaluated it and tore down the open "Assign to..." submenu: it simply would
    /// not open while audio played. `rightMouseDown` is delivered before the menu is
    /// built, so pausing here means no ticks arrive while it is up. It also matches
    /// what the user was already doing by hand (stopping playback to name someone).
    /// The monitor only observes; it returns the event untouched so the menu still
    /// opens normally.
    private func installRightClickPause() {
        guard rightClickMonitor == nil else { return }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { event in
            if playback.isPlaying { playback.pause() }
            return event
        }
    }

    private func removeRightClickPause() {
        if let monitor = rightClickMonitor {
            NSEvent.removeMonitor(monitor)
            rightClickMonitor = nil
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
                voiceprintLabels: voiceprintLabels,
                cast: cast,
                playback: playback,
                onEdit: { seg in editingSegment = seg },
                onName: { label in namingTarget = NamingTarget(label: label) },
                onRename: { label, current in
                    namingTarget = NamingTarget(label: label, currentName: current)
                },
                onUndoName: { label, current in undoNaming(label: label, name: current) },
                onReassign: { indices, label in reassign(indices: indices, toLabel: label) },
                onAssignNew: { indices in assignNewTarget = AssignNewTarget(indices: indices) },
                onResetReassignment: { indices in resetReassignment(indices: indices) }
            )
        }
    }

    /// Reassign a batch of segments to a speaker (FEAT3-SEGMENT). Local overlay write,
    /// then reload so the rows resolve the new labels; regenerate/republish are left to
    /// the detail menu rather than auto-fired.
    private func reassign(indices: [Int], toLabel label: String) {
        _ = libraryModel.reassignSegments(stem: meeting.stem, indices: indices, toLabel: label)
        Task { await reload() }
    }

    private func resetReassignment(indices: [Int]) {
        _ = libraryModel.resetSegmentReassignment(stem: meeting.stem, indices: indices)
        Task { await reload() }
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
        // SEC14: the event log is grepped and shared in diagnostics, so it carries lengths by
        // default, not the verbatim transcript sentences. The full text lands only under verbose.
        var attributes: [String: Any] = [
            "stem": meeting.stem,
            "segment_index": segment.index,
            "original_len": pipelineOriginal.count,
            "edited_len": edited.count,
        ]
        if UISettings.shared.verboseLogging {
            attributes["original_text"] = pipelineOriginal
            attributes["edited_text"] = edited
        }
        Log.event(category: "correction", action: "transcript_correction", attributes: attributes)
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
        voiceprintLabels = result?.voiceprintLabels ?? []
        cast = MeetingCast.members(segments: segments, overlay: speakerOverlay)
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
    /// Diarization clusters that carry a voiceprint (FEAT3-ROSTER): only these offer
    /// cluster enrollment. Everything else gets per-line assignment.
    let voiceprintLabels: Set<String>
    /// The meeting's resolved people (FEAT3-SEGMENT). Passed in already computed and
    /// held in the host's state, NOT derived in `body`: rebuilding it on every
    /// `playback.currentTime` tick churned the context menu's content and tore down
    /// the open "Assign to..." submenu mid-interaction.
    let cast: [CastMember]
    @ObservedObject var playback: AudioPlaybackController
    /// Called on "Edit text" context-menu action; the host owns sheet presentation.
    let onEdit: (TranscriptSegment) -> Void
    /// Called on "Name this speaker" (FEAT3-ROSTER) with the raw speaker label.
    let onName: (String) -> Void
    /// Called on "Rename…" (FEAT3-UNDO) with the raw label and its current name.
    let onRename: (String, String) -> Void
    /// Called on "Undo naming" (FEAT3-UNDO) with the raw label and its current name.
    let onUndoName: (String, String) -> Void
    /// Called on "Assign to <existing speaker>" (FEAT3-SEGMENT) with the target segment indices and the destination label.
    let onReassign: ([Int], String) -> Void
    /// Called on "New person…" (FEAT3-SEGMENT) with the target segment indices; the host opens the label-only naming sheet.
    let onAssignNew: ([Int]) -> Void
    /// Called on "Reset to original label" (FEAT3-SEGMENT) with the target segment indices.
    let onResetReassignment: ([Int]) -> Void

    /// Index of the segment containing the playback head. Updated via `onChange` so the binary search runs at most once per tick.
    @State private var activeIndex: Int? = nil
    /// Multi-segment selection for reassignment (FEAT3-SEGMENT); layered on Cmd/Shift-click so a plain click still seeks.
    @State private var selection = SegmentSelection()

    var body: some View {
        let markerMap = TranscriptMarkerLayout.assign(markers: markers, to: segments)
        let order = segments.map(\.index)
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
                            // Enrollment is offered only for a voice that is both
                            // still anonymous and has a voiceprint to enroll. A baked
                            // name (Heorhii) or a roster match (Rana) is already a
                            // person, so "Name this speaker" would be nonsense there.
                            canEnroll: seg.speakerID.map {
                                voiceprintLabels.contains($0) && MeetingCast.isUnnamedCluster($0)
                            } ?? false,
                            isActive: seg.index == activeIndex,
                            isSelected: selection.contains(seg.index),
                            assignTargets: MeetingCast.assignTargets(
                                for: seg, cast: cast, overlay: overlay
                            ),
                            isReassigned: overlay.segments[seg.index] != nil,
                            onSelect: { kind in
                                switch kind {
                                case .plain:
                                    selection.plainClick(seg.index)
                                    playback.playFrom(seg.start)
                                case .command:
                                    selection.toggle(seg.index)
                                case .shift:
                                    selection.extendTo(seg.index, in: order)
                                }
                            },
                            onEdit: { onEdit(seg) },
                            onName: onName,
                            onRename: onRename,
                            onUndoName: onUndoName,
                            onReassignTo: { label in
                                onReassign(selection.targets(for: seg.index), label)
                                selection.clear()
                            },
                            onAssignNew: {
                                onAssignNew(selection.targets(for: seg.index))
                                selection.clear()
                            },
                            onResetSegment: {
                                onResetReassignment(selection.targets(for: seg.index))
                                selection.clear()
                            }
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
                    // Follow the play head, but not while a multi-select is being built
                    // (FEAT3-SEGMENT): auto-scrolling the rows out from under the cursor
                    // is what made reassigning a batch fight the user.
                    if playback.isPlaying, selection.isEmpty, let idx = newIdx {
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
    /// True when this segment's voice is still anonymous AND has a voiceprint, i.e.
    /// the roster can enroll it (FEAT3-ROSTER). Only then is "Name this speaker..."
    /// offered; everything else uses per-line assignment, so a voiceprint-less
    /// `speaker_unknown` no longer hard-fails on enroll and an already-named voice is
    /// not offered up for enrollment.
    let canEnroll: Bool
    let isActive: Bool
    /// Selected for a multi-segment reassignment (FEAT3-SEGMENT).
    let isSelected: Bool
    /// The other people in this meeting, for the "Assign to..." menu.
    let assignTargets: [CastMember]
    /// True when this segment carries a per-segment reassignment (offers "Reset").
    let isReassigned: Bool
    /// A modifier-classified click: plain seeks, Cmd toggles, Shift range-selects.
    let onSelect: (SegmentClick) -> Void
    let onEdit: () -> Void
    let onName: (String) -> Void
    let onRename: (String, String) -> Void
    let onUndoName: (String, String) -> Void
    /// Reassign the current selection (or just this segment) to an existing label.
    let onReassignTo: (String) -> Void
    /// Assign the current selection (or just this segment) to a typed-in new person.
    let onAssignNew: () -> Void
    /// Reset the current selection's (or this segment's) per-segment reassignment.
    let onResetSegment: () -> Void

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
        Button(action: { onSelect(Self.classifyClick()) }) {
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
        // Selected-for-reassignment outline (FEAT3-SEGMENT), distinct from the
        // playback-active fill so both can show. Non-interactive so it never eats a click.
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.mpSignal.opacity(0.7) : .clear, lineWidth: 1.5)
                .padding(.horizontal, 8)
                .allowsHitTesting(false)
        )
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
                } else if canEnroll {
                    // FEAT3-ROSTER: only an anonymous voice with a voiceprint can be
                    // enrolled. A voiceprint-less line (speaker_unknown, an unclustered
                    // id) uses the per-line assign menu below instead, which never
                    // touches the roster and so cannot fail on a missing embedding.
                    Button("Name this speaker…") { onName(raw) }
                }
            }
            assignMenu
        }
    }

    /// FEAT3-SEGMENT: assign this segment (or the whole multi-selection) to someone
    /// else in the meeting or to a typed-in new person, or reset a prior assignment.
    /// Label-only: no voiceprint is enrolled, so roster centroids are untouched, and a
    /// new name is written straight to the overlay. "New person..." is the path for
    /// someone diarization missed (a mid-meeting joiner with a line or two) or an
    /// unknown line that belongs to nobody already listed. The targets come from the
    /// resolved cast, so a person introduced by an earlier "New person" is selectable
    /// here rather than having to be retyped every time.
    @ViewBuilder
    private var assignMenu: some View {
        Divider()
        Menu("Assign to\u{2026}") {
            ForEach(assignTargets) { target in
                Button(target.displayName) { onReassignTo(target.assignKey) }
            }
            if !assignTargets.isEmpty { Divider() }
            Button("New person\u{2026}") { onAssignNew() }
        }
        if isReassigned {
            Button("Reset to original label") { onResetSegment() }
        }
    }

    /// The click kind from the current modifier flags (macOS): Cmd toggles the
    /// selection, Shift range-selects, a plain click seeks (and clears the selection).
    static func classifyClick() -> SegmentClick {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) { return .command }
        if mods.contains(.shift) { return .shift }
        return .plain
    }
}

/// Name-entry sheet for the three speaker-naming flows: enrolling a diarized voice
/// into the roster (FEAT3-ROSTER), renaming an already-named one (FEAT3-UNDO), and
/// assigning specific lines to a typed-in new person (FEAT3-SEGMENT). The copy is
/// mode-specific because the enroll flow persists a cross-meeting voiceprint and the
/// line-assign flow deliberately does not.
enum SpeakerNamingMode { case enroll, rename, assignNew }

private struct SpeakerNamingSheet: View {
    let currentDisplay: String
    let mode: SpeakerNamingMode
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String

    init(
        currentDisplay: String,
        mode: SpeakerNamingMode = .enroll,
        initialName: String = "",
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.currentDisplay = currentDisplay
        self.mode = mode
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: initialName)
    }

    private var title: String {
        switch mode {
        case .enroll:    return "Name \(currentDisplay)"
        case .rename:    return "Rename \(currentDisplay)"
        case .assignNew: return "Assign \(currentDisplay) to a new person"
        }
    }

    private var explanation: String {
        switch mode {
        case .enroll, .rename:
            // FEAT3-UNDO name-time honesty: state plainly that this enrolls a
            // persistent voiceprint affecting future meetings, reversibly.
            return "Enrolls this voice into your roster, so this person is named automatically in future meetings. You can undo the naming or remove them from your roster later from the speaker's right-click menu; the original diarization label is kept either way."
        case .assignNew:
            // FEAT3-SEGMENT: label-only, so be honest that it does NOT learn the voice.
            return "Labels the selected lines in this meeting only. No voiceprint is learned, so this person is not recognised automatically in other meetings. Use it for someone diarization missed, or a line that belongs to nobody already listed. Reversible from the same menu."
        }
    }

    private var saveTitle: String {
        switch mode {
        case .enroll:    return "Save"
        case .rename:    return "Rename"
        case .assignNew: return "Assign"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            Text(explanation)
                .font(.caption)
                .foregroundStyle(Color(MPColors.fgMuted))
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle, action: submit)
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

                PlaybackRateMenu(playback: playback)
            }
        }
    }

    private var displayedTime: Double {
        dragValue ?? playback.currentTime
    }
}
