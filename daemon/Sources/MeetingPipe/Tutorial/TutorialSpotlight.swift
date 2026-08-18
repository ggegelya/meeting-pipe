import CoreGraphics

/// Where the spotlight and its card go, given what the anchors reported
/// (FEAT15).
///
/// All of it is pure and explicitly fed, in the `GuideDocument.currentSection`
/// idiom: geometry decided in a view body is geometry nothing can test, and the
/// interesting cases here (a control scrolled out of the window, a control near
/// an edge, a card that would cover the thing it describes) are exactly the ones
/// that are painful to reproduce by hand.
enum TutorialSpotlight {

    /// Gap between the hole and the card, and the margin the card keeps from the
    /// window edge. Both on the 4pt grid (`MPSpace.s3` / `s4`), restated as plain
    /// numbers so this file stays free of AppKit and can be reasoned about as
    /// geometry.
    static let gap: CGFloat = 12
    static let margin: CGFloat = 16
    /// How far the hole is grown past the control, so the ring reads as
    /// surrounding it rather than as a border on it.
    static let padding: CGFloat = 6

    /// What the overlay can draw for a step.
    enum Focus: Equatable {
        /// The anchor reported a usable frame; this is the hole to cut.
        case control(CGRect)
        /// The anchor reported nothing usable. Either the control is not on
        /// screen right now, or it is gone and the source fences have not been
        /// run. The overlay says so out loud rather than dimming the window over
        /// an invisible hole.
        case missing
    }

    /// Which side of the hole the card sits on.
    enum Placement: Equatable {
        case below
        case above
        case trailing
        case leading
        /// No side had room, or there is no hole. The card takes the middle.
        case centered
    }

    /// Resolve an anchor's reported frame into something drawable.
    ///
    /// A frame is unusable when it was never reported, when it collapsed to
    /// nothing (a control inside a hidden branch still reports, at zero size),
    /// or when it lies wholly outside the window the overlay covers (scrolled
    /// away, or in a pane that is not selected). All three read the same to a
    /// person watching a tour highlight nothing, so they resolve the same way.
    static func focus(
        _ anchor: TutorialAnchor,
        frames: [TutorialAnchor: CGRect],
        viewport: CGSize
    ) -> Focus {
        guard let frame = frames[anchor] else { return .missing }
        guard frame.width > 1, frame.height > 1 else { return .missing }
        let window = CGRect(origin: .zero, size: viewport)
        guard window.intersects(frame) else { return .missing }
        return .control(hole(around: frame, in: viewport))
    }

    /// The control's frame, grown by `padding` and clipped to the window.
    static func hole(around frame: CGRect, in viewport: CGSize) -> CGRect {
        let grown = frame.insetBy(dx: -padding, dy: -padding)
        return grown.intersection(CGRect(origin: .zero, size: viewport))
    }

    /// Where the card goes for a given hole.
    ///
    /// Below first, then above, then to the side, because a card under the thing
    /// it describes is how every annotation in this app already reads (a
    /// `SettingsRow` sublabel, the prompt panel's explanation line). The one rule
    /// that is not preference: it may never overlap the hole, since a tour that
    /// covers the control it is pointing at is worse than no tour.
    static func card(
        for hole: CGRect?,
        in viewport: CGSize,
        size: CGSize
    ) -> (frame: CGRect, placement: Placement) {
        guard let hole else {
            return (centeredFrame(size, in: viewport), .centered)
        }

        if hole.maxY + gap + size.height + margin <= viewport.height {
            let x = clampedX(centeredOn: hole.midX, width: size.width, in: viewport)
            return (CGRect(x: x, y: hole.maxY + gap, width: size.width, height: size.height), .below)
        }
        if hole.minY - gap - size.height - margin >= 0 {
            let x = clampedX(centeredOn: hole.midX, width: size.width, in: viewport)
            return (CGRect(x: x, y: hole.minY - gap - size.height, width: size.width, height: size.height), .above)
        }
        if hole.maxX + gap + size.width + margin <= viewport.width {
            let y = clampedY(centeredOn: hole.midY, height: size.height, in: viewport)
            return (CGRect(x: hole.maxX + gap, y: y, width: size.width, height: size.height), .trailing)
        }
        if hole.minX - gap - size.width - margin >= 0 {
            let y = clampedY(centeredOn: hole.midY, height: size.height, in: viewport)
            return (CGRect(x: hole.minX - gap - size.width, y: y, width: size.width, height: size.height), .leading)
        }
        return (centeredFrame(size, in: viewport), .centered)
    }

    // MARK: - Clamping

    private static func centeredFrame(_ size: CGSize, in viewport: CGSize) -> CGRect {
        CGRect(
            x: (viewport.width - size.width) / 2,
            y: (viewport.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Centre on `midX`, then pull back inside the window. `max` runs last so a
    /// card wider than the window pins to the leading margin rather than to a
    /// negative x, which is the case a narrow window actually produces.
    private static func clampedX(centeredOn midX: CGFloat, width: CGFloat, in viewport: CGSize) -> CGFloat {
        let ideal = midX - width / 2
        return max(margin, min(ideal, viewport.width - width - margin))
    }

    private static func clampedY(centeredOn midY: CGFloat, height: CGFloat, in viewport: CGSize) -> CGFloat {
        let ideal = midY - height / 2
        return max(margin, min(ideal, viewport.height - height - margin))
    }
}
