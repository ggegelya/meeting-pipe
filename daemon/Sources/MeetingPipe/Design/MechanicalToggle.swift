import SwiftUI

/// The mechanical toggle (DSN24), matching the locked `PWToggle` mockup: a 34x20
/// track (signal teal on, `ink300` off) with a 16pt white knob that snaps between
/// ends in 90ms. "Mechanical" is the motion: short, springless, ease-out, honoring
/// reduce-motion. Drop-in via `Toggle(...).toggleStyle(.mechanical)`.
///
/// Geometry follows the locked Liquid Quiet mockup (34x20), not the Instrument
/// prose's 36x21: toggles live in Preferences, which stays Liquid Quiet; DSN28
/// retunes against rendered pixels.
struct MechanicalToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Fixed geometry, exposed for tests and for the knob-travel maths.
    enum Metrics {
        static let trackWidth: CGFloat = 34
        static let trackHeight: CGFloat = 20
        static let knobSize: CGFloat = 16
        static let knobInset: CGFloat = 2

        /// Leading offset of the knob for on/off. Off rests at the inset; on rests
        /// an equal inset from the trailing edge. Pure, so tests pin the travel.
        static func knobLeadingOffset(isOn: Bool) -> CGFloat {
            isOn ? trackWidth - knobSize - knobInset : knobInset
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(on ? Color(MPColors.signal600) : Color(MPColors.ink300))
                    .frame(width: Metrics.trackWidth, height: Metrics.trackHeight)
                Circle()
                    .fill(.white)
                    .frame(width: Metrics.knobSize, height: Metrics.knobSize)
                    .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
                    .offset(x: Metrics.knobLeadingOffset(isOn: on))
            }
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: MPMotion.durSnap), value: on)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

extension ToggleStyle where Self == MechanicalToggleStyle {
    /// The design-system mechanical toggle (DSN24).
    static var mechanical: MechanicalToggleStyle { MechanicalToggleStyle() }
}
