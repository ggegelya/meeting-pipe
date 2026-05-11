import AVFoundation
import Combine
import Foundation

/// Local-file audio playback for the Library detail tabs (TECH-A6 +
/// TECH-A7). Wraps `AVAudioPlayer` so SwiftUI views can observe
/// `currentTime` / `isPlaying` / `duration` without owning the underlying
/// player. One instance is held by `MeetingDetailView` as a `@StateObject`
/// and shared between the Transcript and Audio tabs so seeking from one
/// affects the other.
///
/// Threading: `AVAudioPlayer` callbacks land on whichever thread invoked
/// `play()`. All public mutations and the polling tick run on the main
/// queue, which matches the SwiftUI consumers. Polling at 15 Hz is the
/// minimum that keeps the line-highlight latency below the spec's ±200 ms
/// budget without spinning the CPU when no one is watching.
@MainActor
final class AudioPlaybackController: ObservableObject {

    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying: Bool = false
    /// The wav we last loaded. Tracked so callers can avoid re-loading
    /// when the user re-opens the same meeting.
    @Published private(set) var loadedURL: URL? = nil
    /// Set when `AVAudioPlayer` initialization throws (corrupt wav,
    /// missing file, sandbox denial). The UI shows a friendly message
    /// rather than dropping to a silent placeholder.
    @Published private(set) var loadError: String? = nil

    private var player: AVAudioPlayer?
    private var tickTimer: Timer?

    private static let tickInterval: TimeInterval = 1.0 / 15.0

    deinit {
        tickTimer?.invalidate()
    }

    /// Load the wav at `url` into the player. No-op when `url` is already
    /// loaded, so swapping tabs on the same meeting doesn't reset
    /// playback position.
    func load(url: URL) {
        if loadedURL == url && player != nil { return }
        stopTimer()
        player?.stop()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            player = p
            loadedURL = url
            duration = p.duration
            currentTime = 0
            isPlaying = false
            loadError = nil
        } catch {
            player = nil
            loadedURL = nil
            duration = 0
            currentTime = 0
            isPlaying = false
            loadError = error.localizedDescription
        }
    }

    /// Tear down the player so it can be reloaded for a different
    /// meeting. Called when the detail view switches stems.
    func unload() {
        stopTimer()
        player?.stop()
        player = nil
        loadedURL = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        loadError = nil
    }

    func play() {
        guard let p = player else { return }
        if p.currentTime >= p.duration - 0.05 {
            // Replaying after the file naturally ended; rewind so play
            // doesn't no-op.
            p.currentTime = 0
            currentTime = 0
        }
        if p.play() {
            isPlaying = true
            startTimer()
        }
    }

    func pause() {
        guard let p = player else { return }
        p.pause()
        isPlaying = false
        currentTime = p.currentTime
        stopTimer()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    /// Jump to `time` (seconds). Clamped to the loaded file's bounds so
    /// out-of-range seeks (a click on a stale transcript whose audio was
    /// truncated) don't push AVAudioPlayer into a stuck state.
    func seek(to time: TimeInterval) {
        guard let p = player else { return }
        let clamped = max(0, min(time, p.duration))
        p.currentTime = clamped
        currentTime = clamped
    }

    /// `seek(to:)` and immediately resume playback. The transcript tab
    /// uses this for click-to-seek so the user hears the line they
    /// tapped.
    func playFrom(_ time: TimeInterval) {
        guard let p = player else { return }
        let clamped = max(0, min(time, p.duration))
        p.currentTime = clamped
        currentTime = clamped
        if p.play() {
            isPlaying = true
            startTimer()
        }
    }

    // MARK: Timer

    private func startTimer() {
        stopTimer()
        let t = Timer.scheduledTimer(
            withTimeInterval: Self.tickInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Allow the UI to keep ticking during sheet/menu interactions.
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    private func stopTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        guard let p = player else { return }
        currentTime = p.currentTime
        if !p.isPlaying {
            // File ended on its own; surface that as a paused state so
            // the UI's play button comes back without a manual stop.
            if isPlaying {
                isPlaying = false
                stopTimer()
            }
        }
    }
}
