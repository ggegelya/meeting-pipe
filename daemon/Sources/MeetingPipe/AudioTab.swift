import AppKit
import Foundation
import SwiftUI

/// Audio tab (TECH-A7). Two-channel waveform (mic top, system audio bottom) from `WaveformPeaks`. Click/drag seeks the shared `AudioPlaybackController` so flipping to the Transcript tab keeps the same play head.

struct AudioTab: View {
    @ObservedObject var playback: AudioPlaybackController
    let meeting: Meeting

    enum LoadState {
        case loading
        /// Peaks plus the recording they came from, so the drag source never has
        /// to re-resolve an extension the retention policy may have changed.
        case ready(WaveformPeaks, URL)
        case empty
        case failed(String)
    }

    @State private var state: LoadState = .loading
    /// Zoom level. Discrete steps keep re-bin cost flat (we always render the same peak count; the view stretches them).
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
            if let audio = meeting.audioURL {
                playback.load(url: audio)
            }
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
        case .ready(let peaks, let audio):
            WaveformContainer(peaks: peaks, zoom: zoom, playback: playback)
                .draggable(audio)
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
            .help("Play or pause. The Space bar also toggles.")

            Text(WaveformTimecode.format(playback.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color(MPColors.fgMuted))
                .frame(width: 56, alignment: .trailing)
            Text("/")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color(MPColors.fgSubtle))
            Text(WaveformTimecode.format(playback.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color(MPColors.fgMuted))
                .frame(width: 56, alignment: .leading)

            Spacer()

            Picker("Channels", selection: $playback.channelMode) {
                Text("Mono").tag(PlaybackChannelMode.monoMixdown)
                Text("Stereo").tag(PlaybackChannelMode.stereoOriginal)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Hug the two labels instead of a fixed width, so the footer stays
            // narrow enough to fit the detail-column floor (TECH-UX11).
            .fixedSize()
            .help(
                "Mono mixes the mic (left) and system audio (right) into both ears. "
                + "Stereo plays the original channels. The on-disk WAV is never modified."
            )

            // Waveform zoom only (TECH-UI-10): Fit shows the whole recording,
            // 1x to 8x expand it horizontally for fine seeking. This control
            // does not change playback speed. A compact menu (not segmented)
            // keeps the footer inside the detail-column floor (TECH-UX11).
            Picker("Zoom", selection: $zoom) {
                ForEach(ZoomLevel.allCases) { z in
                    Text(z.label).tag(z)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Waveform zoom. Fit shows the whole recording; 1x to 8x expand it horizontally for fine seeking. Playback speed is unaffected.")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 32))
                .foregroundStyle(Color(MPColors.fgSubtle))
            Text("No audio for this meeting.")
                .font(.callout)
                .foregroundStyle(Color(MPColors.fgMuted))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    @ViewBuilder
    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.mpWarning)
            Text("Couldn't read the waveform.")
                .font(.callout)
                .foregroundStyle(Color(MPColors.fgMuted))
            Text(msg)
                .font(.caption)
                .foregroundStyle(Color(MPColors.fgSubtle))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    @MainActor
    private func reload() async {
        let stem = meeting.stem
        // No recording: retention dropped it, or it was never written. The empty
        // state already says "No audio for this meeting."
        guard let audioURL = meeting.audioURL,
              FileManager.default.fileExists(atPath: audioURL.path) else {
            state = .empty
            return
        }
        state = .loading
        let result: Result<WaveformPeaks, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let peaks = try WaveformPeaksLoader.load(audioURL: audioURL)
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
            state = .ready(peaks, audioURL)
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

    /// Nudges the scroll position to keep the play head visible when zoomed. `ScrollViewReader.scrollTo` is the only programmatic scroll SwiftUI provides.
    private func autoFollow(
        _ time: Double,
        width: CGFloat,
        viewport: CGFloat,
        proxy: ScrollViewProxy
    ) {
        guard playback.isPlaying, peaks.durationSec > 0, width > viewport else {
            return
        }
        // No-op today: ScrollViewReader has no "scroll to fraction" primitive on AppKit; that would need an NSScrollView bridge. Left as the seam for that bridge. Manual scroll and click-to-seek are the load-bearing interactions.
        let fraction = time / peaks.durationSec
        _ = fraction
        _ = proxy
    }
}

// MARK: - Waveform body (Canvas)

/// Composes the static waveform with a thin moving play head. `playback` is a plain
/// reference here (not `@ObservedObject`) so this view does not re-evaluate on the
/// ~15 Hz `currentTime` tick: only `PlayheadOverlay` observes playback, and the
/// expensive per-column stroking lives in `StaticWaveform` behind an `.equatable()`
/// gate (TECH-A13 waveform redraw budget).
private struct WaveformBody: View {
    let peaks: WaveformPeaks
    let width: CGFloat
    let playback: AudioPlaybackController

    var body: some View {
        StaticWaveform(peaks: peaks, width: width)
            .equatable()
            .frame(minHeight: 220, maxHeight: .infinity)
            .overlay {
                PlayheadOverlay(playback: playback, durationSec: peaks.durationSec)
            }
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
}

/// The two-channel envelope. Equatable (synthesized over `peaks` + `width`) so SwiftUI
/// skips the per-column path stroking unless the zoom width or the underlying peaks
/// actually change. Comparing the full peak content (not a binCount/duration proxy)
/// keeps it correct when switching between two same-duration meetings.
private struct StaticWaveform: View, Equatable {
    let peaks: WaveformPeaks
    let width: CGFloat

    var body: some View {
        Canvas { ctx, size in
            drawChannel(
                ctx: ctx,
                peaks: peaks.left,
                rect: CGRect(x: 0, y: 0, width: size.width, height: size.height / 2),
                tint: .mpSignal,
                label: "Mic"
            )
            drawChannel(
                ctx: ctx,
                peaks: peaks.right,
                rect: CGRect(
                    x: 0, y: size.height / 2,
                    width: size.width, height: size.height / 2
                ),
                tint: Color(MPColors.fgMuted),
                label: "System"
            )
        }
        .frame(width: width)
    }

    private func drawChannel(
        ctx: GraphicsContext,
        peaks: [Float],
        rect: CGRect,
        tint: Color,
        label: String
    ) {
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
        let mid = rect.midY
        var zero = Path()
        zero.move(to: CGPoint(x: rect.minX, y: mid))
        zero.addLine(to: CGPoint(x: rect.maxX, y: mid))
        ctx.stroke(
            zero,
            with: .color(.secondary.opacity(0.25)),
            lineWidth: 0.5
        )
        // One vertical bar per pixel column; sub-samples when binCount > pixels, stretches when binCount < pixels.
        guard !peaks.isEmpty, rect.width > 1 else { return }
        let half = rect.height / 2 - 4
        var path = Path()
        let columns = Int(rect.width.rounded(.down))
        for col in 0..<columns {
            let fraction = Double(col) / Double(max(columns - 1, 1))
            let binIdx = Int(fraction * Double(peaks.count - 1))
            let p = CGFloat(peaks[binIdx])
            // Cube-root scale keeps loud/clipped meetings from washing out quiet ones.
            let scaled = CGFloat(pow(Double(p), 1.0 / 1.7)) * half
            let x = rect.minX + CGFloat(col) + 0.5
            path.move(to: CGPoint(x: x, y: mid - scaled))
            path.addLine(to: CGPoint(x: x, y: mid + scaled))
        }
        ctx.stroke(path, with: .color(tint), lineWidth: 1)
    }
}

/// Just the play head: a 1.5 pt signal-teal line at the current-time fraction. The only view
/// in the waveform stack that observes `playback`, so the ~15 Hz tick redraws one line
/// rather than the whole canvas.
private struct PlayheadOverlay: View {
    @ObservedObject var playback: AudioPlaybackController
    let durationSec: Double

    var body: some View {
        GeometryReader { geo in
            let fraction = durationSec > 0
                ? min(max(playback.currentTime / durationSec, 0), 1)
                : 0
            let x = CGFloat(fraction) * geo.size.width
            Path { p in
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: geo.size.height))
            }
            .stroke(Color.mpSignal, lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Timecode helper

enum WaveformTimecode {
    /// `mm:ss` / `h:mm:ss` - matches the Transcript tab's formatting.
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
