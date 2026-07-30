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
    /// Re-open that same sheet in `.rename` for a voice named in this meeting, carrying
    /// its current name so the mode resolves to rename rather than a second enroll
    /// (`assignKey`, `currentName`).
    let onRename: (String, String) -> Void
    /// Drop this meeting's naming and un-enroll the voice (`assignKey`, `currentName`),
    /// the same undo the transcript row menu runs.
    let onUnname: (String, String) -> Void
    /// Rename a roster person everywhere, through `RosterRename` (`currentName`).
    let onRenameEverywhere: (String) -> Void

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
        // Horizontal inset comes from the caller: TranscriptTab (the single
        // consumer) puts this bar on the shared reading measure with the gutter
        // outside, so an internal 16 here would double-pad and shift the chips
        // off the rows' text edge (UX36).
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voices in this meeting")
    }

    /// One chip, plus whatever its origin licenses on right-click (UX40). A voice with
    /// no actions gets no menu at all rather than an empty one.
    @ViewBuilder
    private func chip(_ voice: VoiceResolution.Voice) -> some View {
        let actions = Self.actions(for: voice)
        if actions.isEmpty {
            chipFace(voice)
        } else {
            chipFace(voice).contextMenu { menu(voice, actions) }
        }
    }

    @ViewBuilder
    private func chipFace(_ voice: VoiceResolution.Voice) -> some View {
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

    /// The chip's menu, rendered straight off the pure list rather than re-deciding per
    /// origin here, so what ships is exactly what `actions(for:)` says and the tests pin.
    @ViewBuilder
    private func menu(_ voice: VoiceResolution.Voice, _ actions: [ChipAction]) -> some View {
        ForEach(actions, id: \.self) { action in
            switch action {
            case .name:
                Button(Self.title(for: action)) { onName(voice.assignKey) }
            case .rename:
                Button(Self.title(for: action)) { onRename(voice.assignKey, voice.displayName) }
            case .unname:
                Button(Self.title(for: action), role: .destructive) {
                    onUnname(voice.assignKey, voice.displayName)
                }
            case .renameEverywhere:
                Button(Self.title(for: action)) { onRenameEverywhere(voice.displayName) }
                    .accessibilityLabel(Self.accessibilityLabel(for: action))
                if let caption = Self.caption(for: action) {
                    // The one item here that writes outside the meeting on screen, so it
                    // says how far it reaches under itself rather than in a dialog after
                    // the fact (the UX29 idiom).
                    Text(caption)
                        .font(.mpTextXS)
                        .foregroundStyle(Color(MPColors.fgSubtle))
                }
            }
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

    // MARK: - What a chip offers (UX40)

    /// One item in a chip's context menu. Every case routes into a flow that already
    /// existed (the FEAT3 naming sheet, its undo, `RosterRename`); the strip grew no
    /// naming machinery of its own, it just stopped being the one surface that could
    /// reach none of them.
    enum ChipAction: Hashable {
        /// Enroll an unresolved voice under a name (the sheet in `.enroll`).
        case name
        /// Re-open that sheet in `.rename`, carrying the current name.
        case rename
        /// Drop this meeting's naming and un-enroll the voice.
        case unname
        /// The roster rename: the roster entry plus the carry across every meeting.
        case renameEverywhere
    }

    /// What this chip's menu offers, in order. Empty means no menu.
    ///
    /// Each gate is the one the flow behind it already enforces, so a chip cannot offer
    /// an action the service would quietly turn into a no-op:
    ///
    /// - a voice named in this meeting is renameable and un-nameable only when the name
    ///   sits in the overlay under a **cluster** label, which is the transcript row
    ///   menu's own gate (`overlay.labels[speakerID]`). A `.namedHere` voice whose key is
    ///   a literal name is a per-segment "New person" instead: no entry in the overlay's
    ///   `labels` map holds it, so "Un-name" would drop something that is not there and
    ///   the chip would not move. That one is undone per line, from the row menu's
    ///   "Reset to original label".
    /// - a roster-matched name is baked into `<stem>.json` by the pipeline's finalize, so
    ///   no per-meeting overlay write reaches it. The roster's rename is the only one
    ///   that does, and it is global by nature, which is why the item says so.
    /// - an unresolved voice keeps the `Name` affordance the chip already had, as a menu
    ///   item too, so every chip that does anything does it the same way.
    static func actions(for voice: VoiceResolution.Voice) -> [ChipAction] {
        switch voice.origin {
        case .namedHere:
            return MeetingCast.isUnnamedCluster(voice.assignKey) ? [.rename, .unname] : []
        case .roster:
            return [.renameEverywhere]
        case .unresolved:
            return voice.canEnroll ? [.name] : []
        case .you, .unattributed:
            return []
        }
    }

    /// The menu wording. An item that opens something further carries the ellipsis; the
    /// un-name acts on the spot, so it does not.
    static func title(for action: ChipAction) -> String {
        switch action {
        case .name:             return "Name this voice\u{2026}"
        case .rename:           return "Rename\u{2026}"
        case .unname:           return "Un-name"
        case .renameEverywhere: return "Rename everywhere\u{2026}"
        }
    }

    /// The quiet line under an item whose reach is wider than the meeting on screen.
    /// Only the roster rename has one: it is the only action here that writes outside
    /// this meeting, and "everywhere" is a claim the reader should be able to check
    /// before clicking rather than discover afterwards.
    static func caption(for action: ChipAction) -> String? {
        switch action {
        case .renameEverywhere:
            return "Renames this person in your roster and in every meeting they are in."
        case .name, .rename, .unname:
            return nil
        }
    }

    /// VoiceOver label for a menu item. A caption row is visible but never reaches
    /// VoiceOver's reading order, so the reach rides in the label (PRODUCT.md's a11y
    /// floor: nothing meaningful visible-only), the way UX29's clamped engine does.
    static func accessibilityLabel(for action: ChipAction) -> String {
        guard let caption = caption(for: action) else { return title(for: action) }
        return "\(title(for: action)). \(caption)"
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
            return "Matched against your named voices, so this name came from the roster. Right-click to rename this person everywhere."
        case .namedHere:
            // The two named-here shapes want opposite instructions, and a right-click
            // hint on the one with no menu would send the reader nowhere (UX40).
            return MeetingCast.isUnnamedCluster(voice.assignKey)
                ? "Named in this meeting. The name lives in this meeting's speaker overlay. Right-click to rename or un-name."
                : "Named line by line in this meeting, not as a whole voice. Undo it from a line's right-click menu, with Reset to original label."
        case .unattributed:
            return "Speech the diarizer could not credit to any one voice. Reassign individual lines from the transcript."
        case .unresolved:
            return "Not matched to anyone, and there is no voiceprint for it, so it can only be named line by line from the transcript."
        }
    }
}
