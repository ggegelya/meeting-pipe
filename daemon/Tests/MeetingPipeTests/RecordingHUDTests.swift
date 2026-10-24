import AppKit
import XCTest
@testable import MeetingPipe

/// Pins the pure dBFS -> normalized-level mapping the DSN25 HUD port uses to drive
/// the shared `LEDMeterView`. The old bespoke `HUDLevelMeter` did this fraction math
/// inline; extracting it makes the mapping testable without the 10 Hz poll timer,
/// and documents the -60..0 dBFS window the meter reads.
final class RecordingHUDTests: XCTestCase {

    func test_normalizedLevel_maps_dbfs_window_to_unit_interval() {
        XCTAssertEqual(RecordingHUDWindow.normalizedLevel(db: 0), 1, accuracy: 0.0001)     // full scale
        XCTAssertEqual(RecordingHUDWindow.normalizedLevel(db: -60), 0, accuracy: 0.0001)   // floor = silence
        XCTAssertEqual(RecordingHUDWindow.normalizedLevel(db: -30), 0.5, accuracy: 0.0001) // midpoint
    }

    func test_normalizedLevel_clamps_out_of_range_input() {
        XCTAssertEqual(RecordingHUDWindow.normalizedLevel(db: 12), 1, accuracy: 0.0001)    // above 0 clamps high
        XCTAssertEqual(RecordingHUDWindow.normalizedLevel(db: -120), 0, accuracy: 0.0001)  // below the floor clamps low
    }

    /// The mapping composes with the meter's stepping: a mid level lights about half
    /// of the 10 segments (LEDMeterView rounds to the nearest segment).
    func test_normalizedLevel_feeds_led_segment_count() {
        let mid = RecordingHUDWindow.normalizedLevel(db: -30)
        XCTAssertEqual(LEDMeterView.litCount(forLevel: mid, segments: 10), 5)
    }

    // HYG1: the meter poll runs only while the panel is visible and a provider is set.
    func test_shouldMeterTick_only_when_visible_and_provider_set() {
        XCTAssertTrue(RecordingHUDWindow.shouldMeterTick(occlusionVisible: true, hasProvider: true))
        XCTAssertFalse(RecordingHUDWindow.shouldMeterTick(occlusionVisible: false, hasProvider: true))
        XCTAssertFalse(RecordingHUDWindow.shouldMeterTick(occlusionVisible: true, hasProvider: false))
        XCTAssertFalse(RecordingHUDWindow.shouldMeterTick(occlusionVisible: false, hasProvider: false))
    }
}

/// UX35: the pill is one width for both the recording and the off-the-record state, so toggling
/// off the record never resizes the HUD. The width decision lives on `HUDPanelGeometry` precisely
/// so that is a test rather than a code-reading exercise; a reintroduced per-state width fails here.
final class HUDPanelGeometryTests: XCTestCase {

    /// The load-bearing one. Off-the-record is an input to the decision and changes nothing.
    func test_off_the_record_does_not_change_the_pill_size() {
        XCTAssertEqual(
            HUDPanelGeometry.size(offRecord: false, degraded: false),
            HUDPanelGeometry.size(offRecord: true, degraded: false)
        )
    }

    /// It does not move the degraded card either: that state owns the geometry outright, and a
    /// span opened before the banner appeared must not shift it.
    func test_off_the_record_does_not_change_the_degraded_card_size() {
        XCTAssertEqual(
            HUDPanelGeometry.size(offRecord: false, degraded: true),
            HUDPanelGeometry.size(offRecord: true, degraded: true)
        )
    }

    /// Clearing the banner mid-span returns to the shared pill, not to a narrower recording-only
    /// width. That is what stops the pre-UX35 shrink under a label the pill could not fit.
    func test_clearing_degraded_returns_to_the_shared_pill_width() {
        XCTAssertEqual(HUDPanelGeometry.size(offRecord: true, degraded: false).width, HUDPanelGeometry.pillWidth)
        XCTAssertEqual(HUDPanelGeometry.size(offRecord: false, degraded: false).width, HUDPanelGeometry.pillWidth)
    }

    /// The degraded card is the only state that resizes, and it keeps its own 232pt width plus the
    /// banner's height on top of the pill's.
    func test_degraded_card_is_the_only_resize() {
        let pill = HUDPanelGeometry.size(offRecord: false, degraded: false)
        let card = HUDPanelGeometry.size(offRecord: false, degraded: true)
        XCTAssertEqual(pill, CGSize(width: HUDPanelGeometry.pillWidth, height: HUDPanelGeometry.height))
        XCTAssertEqual(card, CGSize(width: HUDPanelGeometry.cardWidth, height: HUDPanelGeometry.height + HUDPanelGeometry.bannerHeight))
        XCTAssertGreaterThan(card.width, pill.width)
    }

    /// UX46's arithmetic, read off the constants the layout actually uses rather than off the
    /// numbers the spec quoted: Stop plus the two icon controls beside it is 102pt, and the pill
    /// has to hold it. This is the piece UX35 could not settle, since it shipped against two
    /// controls and left the third's width to whichever task landed second.
    func test_the_control_row_fits_inside_the_pill() {
        XCTAssertEqual(HUDPanelGeometry.controlRowWidth, 102)  // 34 + 8 + 26 + 8 + 26
        XCTAssertGreaterThan(
            HUDPanelGeometry.pillWidth, HUDPanelGeometry.controlRowWidth,
            "the control row is what sizes the pill now; a control added without widening it clips"
        )
        // And with a real margin either side, not a squeeze that only technically fits.
        XCTAssertGreaterThanOrEqual((HUDPanelGeometry.pillWidth - HUDPanelGeometry.controlRowWidth) / 2, 6)
    }

    /// Stop is shifted left by exactly enough that the whole row reads as centred: its two outer
    /// edges are mirror images about the pill's centreX. A third control added without moving the
    /// offset would show up as a group drifting off-centre, so pin the property, not the number.
    func test_the_stop_offset_centres_the_whole_control_row() {
        let leading = HUDPanelGeometry.stopCenterXOffset - RecordKey.Geometry.side / 2
        let trailing = leading + HUDPanelGeometry.controlRowWidth
        XCTAssertEqual(leading, -trailing, accuracy: 0.001, "the control row must sit centred on the pill")
        XCTAssertEqual(HUDPanelGeometry.stopCenterXOffset, -34, "-17 with one icon control, -34 with two")
    }

    /// The number itself: the pill has to fit the widest state label it can show. Measured the way
    /// the HUD lays it out, dot 8 + stack spacing 5 + the label's intrinsic width at 10pt medium,
    /// so a font or copy change that outgrows the constant fails here instead of clipping on screen.
    func test_pill_width_fits_both_state_labels() {
        for label in ["Recording", "Off the record"] {
            XCTAssertGreaterThan(
                HUDPanelGeometry.pillWidth,
                HUDPanelGeometryTests.dotRowWidth(label),
                "\(label) does not fit the shared pill width"
            )
        }
    }

    /// Reproduces `makeContentView`'s dot row: an 8pt dot and the state label in a 5pt-spaced
    /// horizontal stack.
    private static func dotRowWidth(_ text: String) -> CGFloat {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: MPType.medium)
        return 8 + 5 + label.intrinsicContentSize.width
    }
}

/// UX46: the flag control on the HUD. What matters is not that a button exists but that both of its
/// entry points reach the *same* session call the flag-moment hotkey makes, since a second marker
/// writer is exactly the failure this task exists to avoid. So these assert on the delegate the HUD
/// calls, which is the only thing either control does. The content view is built directly rather
/// than presented, so nothing here needs a panel or a window server.
@MainActor
final class HUDControlRowTests: XCTestCase {

    private final class SpyHUDDelegate: RecordingHUDDelegate {
        var stops = 0
        var retries = 0
        var offRecords = 0
        var flags = 0
        func recordingHUDDidRequestStop(_ hud: RecordingHUDWindow) { stops += 1 }
        func recordingHUDDidRequestRetrySystemAudio(_ hud: RecordingHUDWindow) { retries += 1 }
        func recordingHUDDidRequestToggleOffTheRecord(_ hud: RecordingHUDWindow) { offRecords += 1 }
        func recordingHUDDidRequestFlagMoment(_ hud: RecordingHUDWindow) { flags += 1 }
    }

    /// The delegate is weak, so the spy has to outlive the call; returned together for that reason.
    private func makeHUD() -> (RecordingHUDWindow, SpyHUDDelegate, NSView) {
        let hud = RecordingHUDWindow()
        let spy = SpyHUDDelegate()
        hud.delegate = spy
        return (hud, spy, hud.makeContentView(source: nil, workflow: nil))
    }

    /// Found by its VoiceOver label, which makes the lookup itself the accessibility fence: an
    /// unlabelled button fails here before a word is asserted about the wiring.
    private func flagButton(in content: NSView) throws -> NSButton {
        try XCTUnwrap(
            content.subviews.compactMap { $0 as? NSButton }
                .first { $0.accessibilityLabel() == "Flag this moment" },
            "no control on the HUD carries a VoiceOver label naming the flag action"
        )
    }

    private func rightClick() throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    private func fire(_ target: AnyObject?, _ action: Selector?) throws {
        let object = try XCTUnwrap(target as? NSObject, "the control has no target")
        _ = object.perform(try XCTUnwrap(action, "the control has no action"))
    }

    func test_the_flag_button_reaches_the_flag_entry_and_nothing_else() throws {
        let (hud, spy, content) = makeHUD()
        let button = try flagButton(in: content)

        XCTAssertEqual(button.toolTip, "Flag this moment", "the .help tooltip names the same action")
        XCTAssertNotNil(button.image, "the flag glyph has to resolve; a mistyped symbol name is an invisible button")
        try fire(button.target, button.action)

        XCTAssertEqual(spy.flags, 1)
        XCTAssertEqual(spy.stops, 0, "a flag must never reach Stop; it is the control next to it")
        XCTAssertEqual(spy.offRecords, 0)
        _ = hud
    }

    func test_the_right_click_item_is_the_same_path_as_the_button() throws {
        let (hud, spy, content) = makeHUD()
        let button = try flagButton(in: content)
        let menu = try XCTUnwrap(content.menu(for: rightClick()))
        let item = try XCTUnwrap(menu.items.first { $0.title == "Flag this moment" })

        // One path, pinned structurally as well as behaviourally: the menu item is not allowed to
        // grow a second route into the session.
        XCTAssertEqual(item.action, button.action)
        XCTAssertTrue(item.target === button.target)

        try fire(item.target, item.action)
        XCTAssertEqual(spy.flags, 1)
        XCTAssertEqual(spy.stops, 0)
        _ = hud
    }

    /// The new item does not disturb the menu's ordering rule: the destructive one stays last,
    /// alone behind the separator.
    func test_the_menu_keeps_stop_last_behind_its_separator() throws {
        let (hud, _, content) = makeHUD()
        let menu = try XCTUnwrap(content.menu(for: rightClick()))
        XCTAssertEqual(
            menu.items.map(\.title),
            ["Flag this moment", "Go off the record", "", "Stop recording"]
        )
        _ = hud
    }

    // MARK: - UX73: the acknowledgement is on the control, and it counts

    /// UX46 pinned that both controls reach one delegate hop. UX73 depends on that being the *only*
    /// route, because the count is computed session-side and pushed back to one button: if either
    /// control acknowledged locally the two would drift apart the moment one of them was used. So
    /// assert the property directly, on the control the acknowledgement lands on.
    func test_both_entry_points_acknowledge_the_same_control() throws {
        let (hud, _, content) = makeHUD()
        let button = try flagButton(in: content)
        let menu = try XCTUnwrap(content.menu(for: rightClick()))
        let item = try XCTUnwrap(menu.items.first { $0.title == "Flag this moment" })

        // Neither control renders anything on its own; both leave it to the session's callback.
        try fire(button.target, button.action)
        XCTAssertEqual(button.accessibilityLabel(), "Flag this moment", "the button must not self-acknowledge")
        try fire(item.target, item.action)
        XCTAssertEqual(button.accessibilityLabel(), "Flag this moment", "nor may the menu item")

        // And one callback moves the one control, whichever was pressed.
        hud.acknowledgeFlag(count: 1)
        XCTAssertEqual(button.accessibilityLabel(), "Flag this moment, 1 flagged")
    }

    /// The count has to be readable after the fact, which is the whole complaint: a user watching
    /// the call window rather than the HUD could not tell a press that registered from one that did
    /// not, because the old acknowledgement was over before they looked.
    func test_the_count_persists_on_the_button_and_resets_with_the_recording() throws {
        let (hud, _, content) = makeHUD()
        let button = try flagButton(in: content)

        hud.acknowledgeFlag(count: 1)
        XCTAssertEqual(button.accessibilityLabel(), "Flag this moment, 1 flagged")
        hud.acknowledgeFlag(count: 2)
        XCTAssertEqual(button.accessibilityLabel(), "Flag this moment, 2 flagged")

        hud.resetFlagCount()
        XCTAssertEqual(
            button.accessibilityLabel(), "Flag this moment",
            "a fresh recording shows the resting control, not the last meeting's total"
        )
    }

    /// The acknowledgement is not allowed to resize the pill. UX35's contract is that the panel has
    /// exactly two shapes, and a badge that grew the control row would break it silently at the
    /// point a user flagged a tenth moment rather than at build time.
    func test_the_badge_does_not_change_the_control_size() throws {
        let (hud, _, content) = makeHUD()
        let button = try flagButton(in: content)
        let resting = button.intrinsicContentSize

        hud.acknowledgeFlag(count: 999)
        XCTAssertEqual(button.intrinsicContentSize, resting, "the count must live inside the 26pt control")
        XCTAssertEqual(HUDPanelGeometry.controlRowWidth, 102, "and the row it sits in is unchanged")
    }
}

/// UX73: the pure half of the acknowledgement, pinned the way `HUDPanelGeometry` is. What the
/// control shows is a decision with two inputs and no AppKit in it, so it is asserted here rather
/// than by reading an animation block and hoping.
final class HUDFlagAcknowledgementTests: XCTestCase {

    /// Before the first flag the control is exactly what UX46 shipped: no badge, no state.
    func test_zero_shows_no_badge() {
        let ack = HUDFlagAcknowledgement.decide(count: 0, reduceMotion: false)
        XCTAssertFalse(ack.showsBadge)
        XCTAssertEqual(ack.badgeText, "")
        XCTAssertEqual(ack.accessibilityLabel(base: "Flag this moment"), "Flag this moment")
    }

    func test_a_count_shows_and_reads_out() {
        let ack = HUDFlagAcknowledgement.decide(count: 3, reduceMotion: false)
        XCTAssertTrue(ack.showsBadge)
        XCTAssertEqual(ack.badgeText, "3")
        XCTAssertEqual(
            ack.accessibilityLabel(base: "Flag this moment"), "Flag this moment, 3 flagged",
            "a badge only a sighted user can read is not an acknowledgement for everyone"
        )
    }

    /// Reduced motion collapses the press the way `blink()` did, and this is the seam that has to
    /// keep covering it: the spec's rule is one implementation that degrades, not a second design.
    func test_reduced_motion_keeps_the_acknowledgement_and_drops_only_the_motion() {
        let still = HUDFlagAcknowledgement.decide(count: 2, reduceMotion: true)
        let moving = HUDFlagAcknowledgement.decide(count: 2, reduceMotion: false)

        XCTAssertFalse(still.animated)
        XCTAssertTrue(moving.animated)
        // What is acknowledged is identical; only how it plays differs.
        XCTAssertEqual(still.badgeText, moving.badgeText)
        XCTAssertEqual(still.showsBadge, moving.showsBadge)
    }

    /// Defensive, because the count arrives from the session rather than from this file.
    func test_a_negative_count_cannot_render_a_badge() {
        let ack = HUDFlagAcknowledgement.decide(count: -1, reduceMotion: false)
        XCTAssertEqual(ack.count, 0)
        XCTAssertFalse(ack.showsBadge)
    }
}

/// UX73's regression fence. The old acknowledgement was a whole-panel `alphaValue` dip, and the
/// thing that made it wrong is invisible to every behavioural test above: they would all still pass
/// if `blink()` came back alongside the badge. So assert its absence on the checkout, the way
/// `TutorialFenceTests` asserts the tour's claims.
/// T7 source fence (deliberate): asserts SessionHUDPresenting and RecordingHUDWindow no longer declare blink(), and the flag count is read as markerSeconds.count in MeetingSessionController. Missing seam: none for the blink ban; the count wants a flag test over FakeSessionHost.
final class HUDFlagAcknowledgementFenceTests: XCTestCase {

    private func repoFile(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
            .deletingLastPathComponent()   // repo root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The HUD protocol is the whole surface the session can reach, so a `blink` requirement here is
    /// the only way the panel dip could be driven again.
    func test_the_hud_protocol_no_longer_offers_a_blink() throws {
        let source = try repoFile("daemon/Sources/MeetingPipe/SessionHost.swift")
        XCTAssertFalse(
            source.contains("func blink("),
            "SessionHUDPresenting must not offer blink(); UX73 replaced it with acknowledgeFlag(count:)"
        )
        XCTAssertTrue(source.contains("func acknowledgeFlag(count: Int)"))
        XCTAssertTrue(source.contains("func resetFlagCount()"))
    }

    func test_the_hud_no_longer_implements_a_blink() throws {
        let source = try repoFile("daemon/Sources/MeetingPipe/RecordingHUDWindow.swift")
        XCTAssertFalse(
            source.contains("func blink("),
            "RecordingHUDWindow must not implement blink(); the acknowledgement is on the flag control"
        )
    }

    /// AC: the acknowledgement state is derived from the same `markerSeconds` the marker sidecar is
    /// written from. Two counters kept in step would satisfy every behavioural test and still drift,
    /// so pin the single expression that makes drift impossible.
    func test_the_count_is_read_off_the_markers_the_sidecar_is_written_from() throws {
        let source = try repoFile("daemon/Sources/MeetingPipe/MeetingSessionController.swift")
        XCTAssertTrue(
            source.contains("acknowledgeFlag(count: markerSeconds.count)"),
            "the acknowledgement must count markerSeconds itself, not a separate tally"
        )
        XCTAssertTrue(
            source.contains("MarkerFile.write(seconds: self.markerSeconds, forFinal: file)"),
            "and the sidecar must still be written from that same array"
        )
        XCTAssertFalse(source.contains("hud.blink()"))
    }
}
