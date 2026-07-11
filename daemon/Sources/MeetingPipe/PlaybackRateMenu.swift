import SwiftUI

/// Shared pitch-corrected playback-speed menu (UX17). Bound to the controller both
/// Library detail tabs share, so a rate set in one applies in the other and
/// survives a tab switch.
struct PlaybackRateMenu: View {
    @ObservedObject var playback: AudioPlaybackController

    var body: some View {
        Picker("Speed", selection: $playback.playbackRate) {
            ForEach(AudioPlaybackController.rateOptions, id: \.self) { rate in
                Text(AudioPlaybackController.rateLabel(rate)).tag(rate)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help("Playback speed, pitch-corrected. Applies live and is shared with the Transcript and Audio tabs.")
    }
}
