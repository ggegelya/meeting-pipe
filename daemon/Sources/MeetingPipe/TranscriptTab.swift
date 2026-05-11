import AppKit
import Combine
import SwiftUI

/// Speaker-labeled transcript view with click-to-seek + current-line
/// highlight (TECH-A6). Pulls the segments from `<stem>.json` —
/// whisperx / mlx-whisper write `{start, end, text, speaker?}` per
/// segment — and renders them as a scrollable, speaker-grouped list
/// with a thin play/pause + scrubber bar.
///
/// The audio engine lives in `AudioPlaybackController`, owned by the
/// parent `MeetingDetailView` as a `@StateObject`. We expose it here so
/// the Audio tab (TECH-A7) can drive the same player without re-loading
/// the file when the user flips between tabs.

// MARK: - Segment model

/// One parsed transcript segment. Pure value type so the lookup logic
/// is trivially testable without spinning up SwiftUI.
struct TranscriptSegment: Identifiable, Hashable {
    let index: Int
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    /// Raw speaker label from the JSON, e.g. `"speaker_0"`. Optional —
    /// diarization may have failed or been disabled for the meeting.
    let speakerID: String?

    var id: Int { index }

    /// Returns true when `time` falls within `[start, end)`. The half-
    /// open interval avoids two adjacent segments both claiming the
    /// boundary tick.
    func contains(_ time: TimeInterval) -> Bool {
        return time >= start && time < end
    }
}

enum TranscriptSegmentLookup {
    /// Index of the segment that contains `time`. When `time` falls in a
    /// gap between segments (silence, music, etc.) we return the most
    /// recent segment that ended before `time` so the UI keeps a row
    /// highlighted instead of flicking to nothing. Returns nil only when
    /// the input is empty or `time` precedes the first segment.
    static func index(at time: TimeInterval, in segments: [TranscriptSegment]) -> Int? {
        guard !segments.isEmpty else { return nil }
        if time < segments[0].start { return nil }
        // Binary search by start time; segments come out of the pipeline
        // sorted in ascending order.
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

/// Loader for the on-disk transcript JSON. Pulled out of the view so
/// reading from disk happens on a detached task, not on the SwiftUI
/// main actor.
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
        return parse(obj)
    }

    /// Parses the dict-shaped transcript payload into typed segments.
    /// Internal so tests can drive it directly from fixtures.
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
    /// "speaker_0" -> "Speaker 1". One-based because zero-indexing makes
    /// no sense to a human reading "Speaker 0 said hello".
    static func displayName(for speakerID: String?) -> String {
        guard let id = speakerID, !id.isEmpty else { return "Unknown" }
        if id.hasPrefix("speaker_"),
           let n = Int(id.dropFirst("speaker_".count)) {
            return "Speaker \(n + 1)"
        }
        return id
    }

    /// Stable tint per speaker so re-ordering doesn't reshuffle colors.
    static func color(for speakerID: String?) -> Color {
        guard let id = speakerID, !id.isEmpty else { return .secondary }
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .brown]
        if id.hasPrefix("speaker_"),
           let n = Int(id.dropFirst("speaker_".count)) {
            return palette[n % palette.count]
        }
        return palette[abs(id.hashValue) % palette.count]
    }

    /// "1:23" / "1:02:45" - matches the rest of the Library's duration
    /// rendering at the row level.
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
                playback: playback
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

    /// Index of the segment whose `[start, end)` contains the playback
    /// head. Updated as a side effect of `playback.currentTime` changes
    /// via `onChange`, so the binary search runs at most once per tick.
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
                            isActive: seg.index == activeIndex
                        ) {
                            playback.playFrom(seg.start)
                        }
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
                          ? Color.accentColor.opacity(0.18)
                          : Color.clear)
                    .padding(.horizontal, 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Playback bar

private struct PlaybackBar: View {
    @ObservedObject var playback: AudioPlaybackController
    /// Local scrubber value while dragging — committed to the player on
    /// release. Without this, the slider fights the timer tick and
    /// jumps under the user's finger.
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
