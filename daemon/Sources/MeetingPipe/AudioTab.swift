import AppKit
import Foundation
import SwiftUI

/// Audio tab (TECH-A7). Two-channel waveform (mic on top, system audio
/// on bottom) backed by the cached peaks in `WaveformPeaks`. Click /
/// drag in the waveform seeks the shared `AudioPlaybackController`;
/// the same controller drives the highlight on the Transcript tab so
/// flipping between tabs keeps a single play head.

struct AudioTab: View {
    @ObservedObject var playback: AudioPlaybackController
    let meeting: Meeting

    enum LoadState {
        case loading
        case ready(WaveformPeaks)
        case empty
        case failed(String)
    }

    @State private var state: LoadState = .loading
    /// Pixels per second of audio. Drives the rendered width; the
    /// container wraps in a horizontal scroll view when the total width
    /// exceeds the visible area. Discrete steps mean re-bin cost is
    /// flat regardless of the zoom level — we always render the same
    /// number of peaks, the view just stretches them.
    @State private var zoom: ZoomLevel = .fit

    enum ZoomLevel: Int, CaseIterable, Identifiable {
        case fit = 0
        case x1 = 1
        case x2 = 2
        case x4 = 4
        case x8 = 8

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .fit: return "Fit"
            case .x1: return "1×"
            case .x2: return "2×"
            case .x4: return "4×"
            case .x8: return "8×"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
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
        switch state {
        case .loading:
            ProgressView("Loading waveform…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            emptyState
        case .failed(let msg):
            errorState(msg)
        case .ready(let peaks):
            WaveformContainer(peaks: peaks, zoom: zoom, playback: playback)
                .draggable(meeting.wavURL)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .keyboardShortcut(.space, modifiers: [])
            .buttonStyle(.borderless)

            Text(WaveformTimecode.format(playback.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            Text("/")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Text(WaveformTimecode.format(playback.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            Spacer()

            Picker("Zoom", selection: $zoom) {
                ForEach(ZoomLevel.allCases) { z in
                    Text(z.label).tag(z)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No audio for this meeting.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    @ViewBuilder
    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("Couldn't read the waveform.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(msg)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    @MainActor
    private func reload() async {
        let stem = meeting.stem
        let wavURL = meeting.wavURL
        guard FileManager.default.fileExists(atPath: wavURL.path) else {
            state = .empty
            return
        }
        state = .loading
        let result: Result<WaveformPeaks, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let peaks = try WaveformPeaksLoader.load(wavURL: wavURL)
                return .success(peaks)
            } catch {
                return .failure(error)
            }
        }.value
        guard meeting.stem == stem else { return }
        switch result {
        case .success(let peaks) where peaks.binCount == 0:
            state = .empty
        case .success(let peaks):
            state = .ready(peaks)
        case .failure(let err):
            state = .failed(err.localizedDescription)
        }
    }
}

// MARK: - Waveform container (handles zoom + scroll)

private struct WaveformContainer: View {
    let peaks: WaveformPeaks
    let zoom: AudioTab.ZoomLevel
    @ObservedObject var playback: AudioPlaybackController

    var body: some View {
        GeometryReader { geo in
            let fitWidth = max(geo.size.width - 32, 100)
            let baseWidth = computeWidth(zoom: zoom, fitWidth: fitWidth)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: zoom != .fit) {
                    WaveformBody(
                        peaks: peaks,
                        width: baseWidth,
                        playback: playback
                    )
                    .frame(width: baseWidth)
                    .id("wf")
                }
                .onChange(of: playback.currentTime) { _, t in
                    autoFollow(t, width: baseWidth, viewport: geo.size.width, proxy: proxy)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func computeWidth(zoom: AudioTab.ZoomLevel, fitWidth: CGFloat) -> CGFloat {
        switch zoom {
        case .fit, .x1: return fitWidth
        case .x2:       return fitWidth * 2
        case .x4:       return fitWidth * 4
        case .x8:       return fitWidth * 8
        }
    }

    /// When zoomed in, keep the play head inside the visible portion of
    /// the scroll view by nudging the scroll position as playback
    /// crosses the right edge. ScrollViewReader's `scrollTo` is the
    /// only programmatic scroll API SwiftUI gives us, so we anchor on
    /// the playhead position by fraction.
    private func autoFollow(
        _ time: Double,
        width: CGFloat,
        viewport: CGFloat,
        proxy: ScrollViewProxy
    ) {
        guard playback.isPlaying, peaks.durationSec > 0, width > viewport else {
            return
        }
        // Only re-anchor every ~0.5 s of audio to avoid jitter at 15 Hz.
        let fraction = time / peaks.durationSec
        _ = fraction
        _ = proxy
        // Intentionally a noop today: native ScrollViewReader has no
        // "scroll to fraction" primitive on AppKit and adding one would
        // require an NSScrollView bridge. Left in as the seam where
        // that bridge would plug in. Manual horizontal scroll still
        // works; the click-to-seek is the load-bearing interaction.
    }
}

// MARK: - Waveform body (Canvas)

private struct WaveformBody: View {
    let peaks: WaveformPeaks
    let width: CGFloat
    @ObservedObject var playback: AudioPlaybackController

    var body: some View {
        Canvas { ctx, size in
            drawChannel(
                ctx: ctx,
                peaks: peaks.left,
                rect: CGRect(x: 0, y: 0, width: size.width, height: size.height / 2),
                tint: .accentColor,
                label: "Mic"
            )
            drawChannel(
                ctx: ctx,
                peaks: peaks.right,
                rect: CGRect(
                    x: 0, y: size.height / 2,
                    width: size.width, height: size.height / 2
                ),
                tint: .purple,
                label: "System"
            )
            drawPlayhead(ctx: ctx, size: size)
        }
        .frame(width: width)
        .frame(minHeight: 220, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    seekFromLocation(v.location.x, width: width)
                }
        )
    }

    private func seekFromLocation(_ x: CGFloat, width: CGFloat) {
        guard width > 0, peaks.durationSec > 0 else { return }
        let clamped = max(0, min(x, width))
        let t = peaks.durationSec * Double(clamped / width)
        playback.seek(to: t)
    }

    private func drawChannel(
        ctx: GraphicsContext,
        peaks: [Float],
        rect: CGRect,
        tint: Color,
        label: String
    ) {
        // Background fill so each channel reads as a distinct row even
        // when the file is silent.
        ctx.fill(
            Path(rect),
            with: .color(tint.opacity(0.05))
        )
        // Channel label, top-left of the row.
        let labelText = Text(label)
            .font(.caption.weight(.semibold))
            .foregroundColor(tint)
        ctx.draw(
            labelText,
            at: CGPoint(x: rect.minX + 6, y: rect.minY + 10),
            anchor: .leading
        )
        // Zero-line.
        let mid = rect.midY
        var zero = Path()
        zero.move(to: CGPoint(x: rect.minX, y: mid))
        zero.addLine(to: CGPoint(x: rect.maxX, y: mid))
        ctx.stroke(
            zero,
            with: .color(.secondary.opacity(0.25)),
            lineWidth: 0.5
        )
        // Peaks: one vertical bar per pixel column. When binCount >
        // pixels we sub-sample by stride; when binCount < pixels we
        // stretch (rare for the file lengths we work with).
        guard !peaks.isEmpty, rect.width > 1 else { return }
        let half = rect.height / 2 - 4
        var path = Path()
        let columns = Int(rect.width.rounded(.down))
        for col in 0..<columns {
            let fraction = Double(col) / Double(max(columns - 1, 1))
            let binIdx = Int(fraction * Double(peaks.count - 1))
            let p = CGFloat(peaks[binIdx])
            // Cube-root keeps loud-but-clipped meetings from washing
            // out quiet ones; mostly a perceptual nicety.
            let scaled = CGFloat(pow(Double(p), 1.0 / 1.7)) * half
            let x = rect.minX + CGFloat(col) + 0.5
            path.move(to: CGPoint(x: x, y: mid - scaled))
            path.addLine(to: CGPoint(x: x, y: mid + scaled))
        }
        ctx.stroke(path, with: .color(tint), lineWidth: 1)
    }

    private func drawPlayhead(ctx: GraphicsContext, size: CGSize) {
        guard peaks.durationSec > 0 else { return }
        let fraction = min(max(playback.currentTime / peaks.durationSec, 0), 1)
        let x = CGFloat(fraction) * size.width
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        ctx.stroke(line, with: .color(.red), lineWidth: 1.5)
    }
}

// MARK: - Timecode helper

enum WaveformTimecode {
    /// `mm:ss` for short files, `h:mm:ss` past the hour. Matches the
    /// transcript tab's row-level formatting so the two surfaces line
    /// up visually.
    static func format(_ time: TimeInterval) -> String {
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
