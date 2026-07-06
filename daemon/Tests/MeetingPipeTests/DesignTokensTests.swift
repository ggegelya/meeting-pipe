import AppKit
import XCTest
@testable import MeetingPipe

/// Pins the curated workflow swatch set (TECH-DSN11) to the `MPColors` tokens it
/// mirrors, so the swatches cannot silently drift off-palette, and guards the
/// two design-system invariants: teal is the default, and Pulse-coral (the
/// recording-dot colour) is never a workflow swatch.
final class DesignTokensTests: XCTestCase {

    /// The swatches are light-canonical hexes (stored as `Workflow.color`), and
    /// `signal600` is now appearance-dynamic (DSN23: it flips bright in dark), so
    /// resolve every token hex under an explicit light appearance before comparing.
    private func lightHex(_ color: NSColor) -> String {
        var hex = ""
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            hex = HexColor.hexString(from: color)
        }
        return hex
    }

    func test_workflowSwatches_match_their_tokens() {
        let expected: [String] = [
            lightHex(MPColors.signal600),  // teal (default)
            lightHex(MPColors.signal700),  // deep teal
            lightHex(MPColors.ink600),     // slate
            lightHex(MPColors.ink500),     // mid ink
            lightHex(MPColors.success600), // green
            lightHex(MPColors.warning600), // amber
        ]
        XCTAssertEqual(MPColors.workflowSwatches, expected)
    }

    func test_default_workflow_colour_is_teal() {
        XCTAssertEqual(MPColors.defaultWorkflowHex, lightHex(MPColors.signal600))
        XCTAssertEqual(MPColors.defaultWorkflowHex, MPColors.workflowSwatches.first)
    }

    func test_no_swatch_is_pulse_coral() {
        // #E5484D is reserved exclusively for the live recording dot.
        let coral = HexColor.hexString(from: MPColors.pulse600)
        XCTAssertFalse(MPColors.workflowSwatches.contains(coral))
        XCTAssertFalse(MPColors.workflowSwatches.contains("#E5484D"))
    }
}
