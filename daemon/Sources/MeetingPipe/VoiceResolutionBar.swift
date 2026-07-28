import SwiftUI

/// The meeting's cast, above the transcript, saying who is resolved and who is not
/// (FEAT11). Renders `VoiceResolution.Outcome`; every decision lives in that pure
/// type, so this file is presentation only.
///
/// It sits above the list rather than inside it because the whole point is answering
/// "did roster matching work here" without reading the transcript, and a strip that
/// scrolls away with the rows answers it only if you are already at the top.
struct VoiceResolutionBar: View {
    let outcome: VoiceResolution.Outcome
    /// Open the enroll flow for an unresolved cluster (the existing TranscriptTab sheet).
    let onName: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(outcome.headline)
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgMuted))
                if let detail = outcome.detail {
                    Text(detail)
                        .font(.mpTextXS)
                        .foregroundStyle(Color(MPColors.fgSubtle))
                }
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(outcome.voices) { voice in
                        chip(voice)
                    }
                }
                .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voices in this meeting")
    }

    @ViewBuilder
    private func chip(_ voice: VoiceResolution.Voice) -> some View {
        if voice.offersNaming {
            Button {
                onName(voice.assignKey)
            } label: {
                chipBody(voice)
            }
            .buttonStyle(.plain)
            .help("This voice was not matched to anyone. Click to name it and remember it for later meetings.")
            .accessibilityLabel("\(voice.displayName), not named. Name this voice.")
        } else {
            chipBody(voice)
                .help(Self.help(for: voice))
                .accessibilityLabel("\(voice.displayName), \(Self.state(for: voice))")
        }
    }

    private func chipBody(_ voice: VoiceResolution.Voice) -> some View {
        HStack(spacing: 4) {
            Image(systemName: Self.glyph(for: voice.origin))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Self.tint(for: voice))
            Text(voice.displayName)
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fg))
                .lineLimit(1)
            if voice.offersNaming {
                Text("Name")
                    .font(.mpTextXS.weight(.medium))
                    .foregroundStyle(Color(MPColors.signalAccent))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(MPColors.bgSunk))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color(MPColors.border), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    static func glyph(for origin: VoiceResolution.Origin) -> String {
        switch origin {
        case .you:           return "person.fill"
        case .roster:        return "person.crop.circle.badge.checkmark"
        case .namedHere:     return "pencil"
        case .unresolved:    return "questionmark.circle"
        case .unattributed:  return "waveform"
        }
    }

    private static func tint(for voice: VoiceResolution.Voice) -> Color {
        switch voice.origin {
        case .unresolved:  return Color(MPColors.warningAccent)
        case .roster:      return Color(MPColors.signalAccent)
        default:           return Color(MPColors.fgMuted)
        }
    }

    /// The plain-language state, also the VoiceOver value. Kept beside the glyph map so
    /// a new origin cannot get an icon and no words.
    static func state(for voice: VoiceResolution.Voice) -> String {
        switch voice.origin {
        case .you:          return "you"
        case .roster:       return "matched from your named voices"
        case .namedHere:    return "named in this meeting"
        case .unattributed: return "speech the diarizer credited to nobody"
        case .unresolved:
            return voice.canEnroll
                ? "not named"
                : "not named, and there is no voiceprint to remember it by"
        }
    }

    private static func help(for voice: VoiceResolution.Voice) -> String {
        switch voice.origin {
        case .you:
            return "Your own voice, from the display name in Preferences ▸ Pipeline."
        case .roster:
            return "Matched against your named voices, so this name came from the roster."
        case .namedHere:
            return "Named in this meeting. The name lives in this meeting's speaker overlay."
        case .unattributed:
            return "Speech the diarizer could not credit to any one voice. Reassign individual lines from the transcript."
        case .unresolved:
            return "Not matched to anyone, and there is no voiceprint for it, so it can only be named line by line from the transcript."
        }
    }
}
