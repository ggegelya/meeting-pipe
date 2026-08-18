import SwiftUI

extension View {
    /// Make this window a stage the tutorial can run in (FEAT15).
    ///
    /// Applied at a surface's root. It does three things: declares the
    /// coordinate space the anchors inside report into, forwards those frames to
    /// the session, and overlays the tour while this is the surface the current
    /// step points at.
    ///
    /// Deliberately an overlay inside the window rather than a floating panel
    /// above it. A panel would need the window's frame, the title-bar inset, and
    /// a child-window relationship kept in step with every move and resize, to
    /// arrive at coordinates the probes already report directly. It would also
    /// put a second window in `WindowActivationManager`'s way (UX39). The cost is
    /// that the title bar is never dimmed, which is the right trade anyway: the
    /// reader can still move or close the window mid-tour.
    func tutorialStage(_ window: TutorialWindow) -> some View {
        modifier(TutorialStage(window: window))
    }
}

struct TutorialStage: ViewModifier {
    let window: TutorialWindow
    @ObservedObject private var session = TutorialSession.shared

    init(window: TutorialWindow) { self.window = window }

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: TutorialStageSpace.name)
            .onPreferenceChange(TutorialAnchorFrames.self) { frames in
                TutorialSession.shared.report(frames, on: window)
            }
            .overlay {
                if session.isStaged(window) {
                    TutorialOverlay(window: window, session: session)
                }
            }
            .onDisappear { session.windowDisappeared(window) }
    }
}

/// The dimmed window, the ring around the control, and the card beside it.
private struct TutorialOverlay: View {
    let window: TutorialWindow
    @ObservedObject var session: TutorialSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The card's resting size. Fixed, because `TutorialSpotlight.card` has to
    /// know how much room the card needs *before* deciding which side of the
    /// control it goes on, and a card that measures itself first would have to
    /// place itself twice per step. Clamped to the window below, so a narrow
    /// window gets a smaller card rather than one hanging off the edge.
    private static let cardSize = CGSize(width: 360, height: 280)

    var body: some View {
        GeometryReader { geo in
            let viewport = geo.size
            let focus = resolvedFocus(in: viewport)
            let hole = focus.flatMap { $0.rect }
            let placed = TutorialSpotlight.card(
                for: hole,
                in: viewport,
                size: clampedCardSize(in: viewport)
            )

            ZStack(alignment: .topLeading) {
                scrim(hole: hole)
                if let hole { ring(hole) }
                if let step = session.step {
                    TutorialCard(
                        step: step,
                        progress: session.run?.progress ?? "",
                        isFirst: session.run?.isFirst ?? true,
                        isLast: session.run?.isLast ?? true,
                        isMissing: focus == .missing,
                        onBack: { session.rewind() },
                        onNext: { session.advance() },
                        onClose: { session.dismiss() }
                    )
                    .frame(width: placed.frame.width, height: placed.frame.height)
                    .offset(x: placed.frame.minX, y: placed.frame.minY)
                }
            }
            .animation(motion, value: hole)
            .animation(motion, value: placed.frame)
            .onChange(of: focus, initial: true) { _, resolved in
                if let resolved { session.note(focus: resolved) }
            }
        }
        .ignoresSafeArea()
    }

    private func resolvedFocus(in viewport: CGSize) -> TutorialSpotlight.Focus? {
        guard let step = session.step else { return nil }
        return TutorialSpotlight.focus(
            step.anchor,
            frames: session.frames[window] ?? [:],
            viewport: viewport
        )
    }

    private func clampedCardSize(in viewport: CGSize) -> CGSize {
        CGSize(
            width: min(Self.cardSize.width, max(0, viewport.width - 2 * TutorialSpotlight.margin)),
            height: min(Self.cardSize.height, max(0, viewport.height - 2 * TutorialSpotlight.margin))
        )
    }

    /// The one flourish, and it is deliberately the quiet kind: the hole and the
    /// card travel from one control to the next instead of cutting, at the
    /// design system's own ease-out with no spring and no overshoot
    /// (`design/README.md`: "short, snappy, no bounce"). Reduce Motion drops it
    /// to instant, which is the same treatment the panel fade and the row pulse
    /// already get.
    private var motion: Animation? {
        reduceMotion ? nil : .easeOut(duration: MPMotion.durSlow)
    }

    private func scrim(hole: CGRect?) -> some View {
        Rectangle()
            .fill(Color(MPColors.ink900).opacity(0.55))
            .mask(
                ZStack(alignment: .topLeading) {
                    Rectangle()
                    if let hole {
                        RoundedRectangle(cornerRadius: MPRadius.sm, style: .continuous)
                            .frame(width: hole.width, height: hole.height)
                            .offset(x: hole.minX, y: hole.minY)
                            .blendMode(.destinationOut)
                    }
                }
                .compositingGroup()
            )
            // Swallows clicks rather than letting them through the hole. A tour
            // narrates; it does not ask the reader to press Record on a control
            // that would start a real capture.
            .contentShape(Rectangle())
            .onTapGesture { }
            .accessibilityHidden(true)
    }

    private func ring(_ hole: CGRect) -> some View {
        RoundedRectangle(cornerRadius: MPRadius.sm, style: .continuous)
            .strokeBorder(Color(MPColors.signal600), lineWidth: 2)
            .frame(width: hole.width, height: hole.height)
            .offset(x: hole.minX, y: hole.minY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// What the tour says about the control it is pointing at.
///
/// The control's name is read off the anchor and rendered once, in the chip. The
/// step's own prose never repeats it, which is what makes a rename a one-line
/// edit in `TutorialAnchor` (`TutorialFenceTests` holds both halves of that).
private struct TutorialCard: View {
    let step: TutorialStep
    let progress: String
    let isFirst: Bool
    let isLast: Bool
    /// The anchor reported no usable frame. Said out loud rather than shown as a
    /// dimmed window with no hole in it.
    let isMissing: Bool
    let onBack: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MPSpace.s2) {
            header
            Text(step.headline)
                .font(.mpTextLG.weight(.semibold))
                .foregroundStyle(Color(MPColors.fg))
                .fixedSize(horizontal: false, vertical: true)
            chip
            Text(step.body)
                .font(.mpTextBase)
                .foregroundStyle(Color(MPColors.fg))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: MPSpace.s2)
            controls
        }
        .padding(MPSpace.s5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mpSurface(radius: MPRadius.md)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tutorial, \(progress)")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(progress)
                .font(.mpTextXS.weight(.semibold))
                .tracking(MPType.trackingCaps * MPType.textXS)
                .textCase(.uppercase)
                .foregroundStyle(Color(MPColors.fgMuted))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.mpIcon)
            .keyboardShortcut(.cancelAction)
            .help("Close the tutorial")
            .accessibilityLabel("Close the tutorial")
        }
    }

    /// The control's name, exactly as the window spells it. Teal wash rather than
    /// a second heading, so the card reads as "this points at that" without
    /// competing with the headline above it.
    @ViewBuilder
    private var chip: some View {
        Text(step.anchor.control)
            .font(.mpTextSM.weight(.medium))
            .foregroundStyle(isMissing ? Color.mpWarning : Color.mpSignal)
            .padding(.horizontal, MPSpace.s2)
            .padding(.vertical, MPSpace.s1)
            .background(
                Capsule(style: .continuous)
                    .fill(isMissing ? Color.mpOverlayFaint : Color.mpSelectionWash)
            )
            .fixedSize(horizontal: false, vertical: true)
        if isMissing {
            Text("Not on screen right now, so there is nothing to point at.")
                .font(.mpTextSM)
                .foregroundStyle(Color.mpWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Two ghost capsules rather than a filled primary beside a secondary. The
    /// SwiftUI button language deliberately ships no filled small button
    /// (`MPButtonStyle.swift`), and one caller is not the second caller that
    /// promotes a primitive. The default-action shortcut carries the emphasis
    /// instead, which is the quieter reading anyway.
    private var controls: some View {
        HStack(spacing: MPSpace.s2) {
            Button("Back", action: onBack)
                .buttonStyle(.mpGhost)
                .disabled(isFirst)
            Spacer()
            Button(isLast ? "Done" : "Next", action: onNext)
                .buttonStyle(.mpGhost)
                .keyboardShortcut(.defaultAction)
        }
    }
}

private extension TutorialSpotlight.Focus {
    /// The hole to cut, or nil when there is no control to cut one around.
    var rect: CGRect? {
        switch self {
        case .control(let rect): return rect
        case .missing: return nil
        }
    }
}
