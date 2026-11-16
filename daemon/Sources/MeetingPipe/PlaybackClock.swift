import Foundation
import SwiftUI

/// The playback head as its own `ObservableObject` (PERF12), so the ~15 Hz tick re-renders only
/// the views that observe it (the transport bar, the scrubber, the play head, the active-row
/// highlighter) and not every view that holds the `AudioPlaybackController`.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0

    /// Only the controller moves the head.
    func set(_ time: TimeInterval) {
        currentTime = time
    }
}

/// An invisible view that watches the clock and calls `onTick` with each new time. It lets a
/// host (the transcript list, the waveform) react to the play head without observing the clock
/// itself, so the host's own body does not re-evaluate on every tick.
struct PlaybackClockObserver: View {
    @ObservedObject var clock: PlaybackClock
    let onTick: (TimeInterval) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: clock.currentTime) { _, t in onTick(t) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
