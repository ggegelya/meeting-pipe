import XCTest
@testable import MeetingPipe

/// AI12: which widths a question may be asked at, and what the control says
/// about the one it is on.
///
/// The RAM rows here are deliberately the rows `pipeline/tests/test_ask.py` and
/// `test_resource_guard.py` pin (2000 at 8 GB, 4000 at 16 and 24, 8000 at 32,
/// 16000 at 48). There is no shared constant across the language boundary, so a
/// one-sided edit is meant to fail one of the two suites; that matters more here
/// than anywhere else, because the number is what stands between a question and
/// the hard reboot of 2026-07-29.
final class AskContextWidthTests: XCTestCase {

    private let cloud = "anthropic"
    private let local = "local"

    private func offer(
        _ backend: String,
        ramGB: Double = 32,
        regulated: Bool = false,
        selected: String = "normal"
    ) -> AskContextWidth.Offer {
        AskContextWidth.offer(
            backendID: backend, regulatedMode: regulated, ramGB: ramGB, selectedID: selected
        )
    }

    // MARK: - The table

    /// The resting position is what `mp ask` passes with no flag at all, so an
    /// owner who never touches the control sees no change whatsoever.
    func test_the_resting_position_is_todays_cli_default() {
        XCTAssertEqual(AskContextWidth.defaultTokens, 4_000)
        XCTAssertEqual(AskContextWidth.normal.tokens, 4_000)
        XCTAssertEqual(AskContextWidth.normal.id, "normal")
        XCTAssertEqual(AskContextWidth.all.first, AskContextWidth.normal)
    }

    /// The middle value is the 32 GB ceiling exactly and the widest is above
    /// every tier there is, which is what makes the widest cloud-only by
    /// construction rather than by a rule someone has to keep true.
    func test_the_widest_position_is_above_every_local_tier() {
        let widest = AskContextWidth.all.last!
        for tier in LocalModelTier.tiers {
            XCTAssertGreaterThan(widest.tokens, tier.contextTokenCeiling)
        }
        XCTAssertEqual(AskContextWidth.all[1].tokens,
                       LocalModelTier.tier(forRamGB: 32).contextTokenCeiling)
    }

    func test_the_multiple_is_the_number_worth_saying_out_loud() {
        XCTAssertEqual(AskContextWidth.multiple(AskContextWidth.all[0]), 1)
        XCTAssertEqual(AskContextWidth.multiple(AskContextWidth.all[1]), 2)
        // The owner measured ~26x the packed input at this width on 2026-07-31.
        XCTAssertEqual(AskContextWidth.multiple(AskContextWidth.all[2]), 25)
    }

    // MARK: - The cap

    /// Nothing clamps a cloud answer (`test_a_cloud_answer_is_not_clamped_by_this_macs_ram`
    /// pins the Python half deliberately), so nothing is withheld here either.
    func test_a_cloud_backend_is_offered_every_position() {
        let o = offer(cloud, ramGB: 8)
        XCTAssertEqual(o.positions, AskContextWidth.all)
        XCTAssertNil(o.reason)
        XCTAssertTrue(o.showsPicker)
        XCTAssertNil(AskContextWidth.ceiling(backendID: cloud, regulatedMode: false, ramGB: 8))
    }

    /// The same worked rows `mp.resource_guard` pins. A one-sided change to
    /// either table fails one of the two suites, which is the whole arrangement.
    func test_the_ceiling_is_the_local_model_tier_table() {
        func cap(_ ram: Double) -> Int? {
            AskContextWidth.ceiling(backendID: local, regulatedMode: false, ramGB: ram)
        }
        XCTAssertEqual(cap(8), 2_000)
        XCTAssertEqual(cap(16), 4_000)
        XCTAssertEqual(cap(24), 4_000)
        XCTAssertEqual(cap(32), 8_000)
        XCTAssertEqual(cap(48), 16_000)
    }

    /// The owner's Mac. The middle position is exactly the ceiling, so it is
    /// offered; the widest is not, and the control says why rather than
    /// accepting it and having the clamp round it down where nobody looks.
    func test_thirty_two_gb_local_offers_up_to_the_ceiling_and_not_past_it() {
        let o = offer(local, ramGB: 32)
        XCTAssertEqual(o.positions.map(\.id), ["normal", "wider"])
        XCTAssertTrue(o.showsPicker)
        XCTAssertTrue(o.reason?.contains("32 GB") == true, o.reason ?? "no reason")
        XCTAssertTrue(o.reason?.contains("Local MLX") == true, o.reason ?? "no reason")
    }

    /// A machine whose ceiling is at or under the resting width has nothing to
    /// choose. The resting position stays (it is the floor of the control, and
    /// dropping it would change nothing about what this machine already does),
    /// the picker does not, and the reason carries the whole truth.
    func test_a_smaller_mac_local_is_left_with_the_resting_position_alone() {
        for ram in [8.0, 16.0, 24.0] {
            let o = offer(local, ramGB: ram)
            XCTAssertEqual(o.positions, [AskContextWidth.normal], "ram \(ram)")
            XCTAssertFalse(o.showsPicker, "ram \(ram)")
            XCTAssertNotNil(o.reason, "ram \(ram)")
        }
    }

    /// `auto`'s fallback leg is the same local model, which is why
    /// `mp.ask.ON_DEVICE_BACKENDS` includes it. Offering a cloud-only width here
    /// would hand the fallback a pack it cannot hold.
    func test_auto_is_capped_because_its_fallback_leg_runs_here() {
        let o = offer("auto", ramGB: 32)
        XCTAssertEqual(o.positions.map(\.id), ["normal", "wider"])
        XCTAssertTrue(o.reason?.contains("fall back") == true, o.reason ?? "no reason")
    }

    func test_apple_intelligence_is_capped_too() {
        XCTAssertEqual(offer("apple_intelligence", ramGB: 32).positions.map(\.id),
                       ["normal", "wider"])
    }

    /// Regulated mode is the wider clamp: `effective_backend` forces the local
    /// path whatever backend is configured, so reading the backend id alone
    /// would offer a cloud-only width to a machine about to answer locally.
    func test_regulated_mode_caps_a_cloud_backend_too() {
        let o = offer(cloud, ramGB: 32, regulated: true)
        XCTAssertEqual(o.positions.map(\.id), ["normal", "wider"])
        XCTAssertTrue(o.reason?.contains("Regulated mode") == true, o.reason ?? "no reason")
    }

    /// And it does not point at a door that opens onto a wall: under regulated
    /// mode every backend is clamped, so "switch to a cloud backend" would be
    /// advice that cannot be taken (`ReSummarizeMenu.offersWorkflowChange`).
    func test_the_regulated_reason_offers_no_escape_hatch() {
        let o = offer(cloud, ramGB: 32, regulated: true)
        XCTAssertFalse(o.reason?.contains("Preferences") == true, o.reason ?? "no reason")
        XCTAssertTrue(offer(local, ramGB: 32).reason?.contains("Preferences") == true)
    }

    /// A hand-edited backend id this build cannot resolve is capped. Python errs
    /// the other way for its own job (it must not refuse to answer); here the
    /// cost of guessing wrong is a wide local pack.
    func test_an_unknown_backend_is_capped_rather_than_trusted() {
        let o = offer("something_new", ramGB: 32)
        XCTAssertEqual(o.positions.map(\.id), ["normal", "wider"])
        XCTAssertNotNil(o.reason)
    }

    // MARK: - The selection

    func test_an_offered_selection_is_kept() {
        XCTAssertEqual(offer(cloud, selected: "widest").selection.id, "widest")
        XCTAssertEqual(offer(cloud, selected: "widest").contextTokens, 100_000)
    }

    /// The case the whole resolution exists for: a width chosen on Anthropic,
    /// then the backend switched to Local in Preferences. The selection cannot
    /// survive as a width, and it does not.
    func test_a_width_the_backend_can_no_longer_take_falls_back_to_resting() {
        let o = offer(local, ramGB: 32, selected: "widest")
        XCTAssertEqual(o.selection, AskContextWidth.normal)
        XCTAssertEqual(o.contextTokens, AskContextWidth.defaultTokens)
    }

    func test_an_id_nothing_pins_reads_as_the_resting_position() {
        XCTAssertEqual(AskContextWidth.position(forID: "__gone").id, "normal")
        XCTAssertEqual(offer(cloud, selected: "__gone").selection, AskContextWidth.normal)
    }

    // MARK: - What it says

    /// The cloud warning is about spend, and says the multiple rather than a
    /// token count: "100000 tokens" is not a thing anyone can price.
    func test_the_cloud_sublabel_names_the_cost_and_the_multiple() {
        let o = offer(cloud, selected: "widest")
        XCTAssertTrue(o.sublabel.contains("25x"), o.sublabel)
        XCTAssertTrue(o.sublabel.contains("cost"), o.sublabel)
        XCTAssertTrue(o.sublabel.contains("Anthropic"), o.sublabel)
        XCTAssertFalse(o.sublabel.contains("100000"), o.sublabel)
    }

    /// And the local one is not about money, because money is not the risk on
    /// this Mac; the wait is.
    func test_the_local_sublabel_is_about_time_not_money() {
        let o = offer(local, ramGB: 32, selected: "wider")
        XCTAssertTrue(o.sublabel.contains("2x"), o.sublabel)
        XCTAssertTrue(o.sublabel.contains("longer"), o.sublabel)
        XCTAssertFalse(o.sublabel.contains("cost"), o.sublabel)
    }

    /// The resting position carries no warning at all. A control that shouts on
    /// its own default teaches the user to stop reading it.
    func test_the_resting_position_warns_about_nothing() {
        for backend in [cloud, local, "auto"] {
            let o = offer(backend, ramGB: 32)
            XCTAssertFalse(o.sublabel.contains("cost"), backend)
            XCTAssertFalse(o.sublabel.contains("x the"), backend)
        }
    }

    /// Auto is the one backend that can bill *and* wait, so it says both rather
    /// than picking whichever currency reads better.
    func test_the_auto_sublabel_names_both_currencies() {
        let o = offer("auto", ramGB: 32, selected: "wider")
        XCTAssertTrue(o.sublabel.contains("cost"), o.sublabel)
        XCTAssertTrue(o.sublabel.contains("falls back"), o.sublabel)
    }

    func test_no_line_this_control_shows_carries_an_em_dash() {
        for backend in [cloud, local, "auto", "apple_intelligence", "something_new"] {
            for ram in [8.0, 32.0, 48.0] {
                for position in AskContextWidth.all {
                    let o = offer(backend, ramGB: ram, selected: position.id)
                    XCTAssertFalse(o.sublabel.contains("\u{2014}"), o.sublabel)
                    XCTAssertFalse(o.reason?.contains("\u{2014}") == true, o.reason ?? "")
                }
            }
        }
    }
}
