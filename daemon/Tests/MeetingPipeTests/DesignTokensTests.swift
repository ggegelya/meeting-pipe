import AppKit
import XCTest
@testable import MeetingPipe

/// Pins the curated workflow swatch set (TECH-DSN11) to the `MPColors` tokens it
/// mirrors, so the swatches cannot silently drift off-palette, and guards the
/// two design-system invariants: teal is the default, and Pulse-coral (the
/// recording-dot colour) is never a workflow swatch.
final class DesignTokensTests: XCTestCase {

    func test_workflowSwatches_match_their_tokens() {
        let expected: [String] = [
            HexColor.hexString(from: MPColors.signal600),  // teal (default)
            HexColor.hexString(from: MPColors.signal700),  // deep teal
            HexColor.hexString(from: MPColors.ink600),     // slate
            HexColor.hexString(from: MPColors.ink500),     // mid ink
            HexColor.hexString(from: MPColors.success600), // green
            HexColor.hexString(from: MPColors.warning600), // amber
        ]
        XCTAssertEqual(MPColors.workflowSwatches, expected)
    }

    func test_default_workflow_colour_is_teal() {
        XCTAssertEqual(MPColors.defaultWorkflowHex, HexColor.hexString(from: MPColors.signal600))
        XCTAssertEqual(MPColors.defaultWorkflowHex, MPColors.workflowSwatches.first)
    }

    func test_no_swatch_is_pulse_coral() {
        // #E5484D is reserved exclusively for the live recording dot.
        let coral = HexColor.hexString(from: MPColors.pulse600)
        XCTAssertFalse(MPColors.workflowSwatches.contains(coral))
        XCTAssertFalse(MPColors.workflowSwatches.contains("#E5484D"))
    }
}
