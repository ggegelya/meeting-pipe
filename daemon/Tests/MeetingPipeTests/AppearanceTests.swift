import AppKit
import XCTest
@testable import MeetingPipe

/// Pins the dark/light decision the HUD chrome reads to choose between a resting fill
/// (dark material) and a de-boxed resting state (light material). The prompt's close,
/// chevron, workflow chip, and ghost buttons all branch on `mpIsDark`.
final class AppearanceTests: XCTestCase {

    func test_dark_variants_report_dark() {
        XCTAssertTrue(NSAppearance(named: .darkAqua)!.mpIsDark)
        XCTAssertTrue(NSAppearance(named: .vibrantDark)!.mpIsDark)
    }

    func test_light_variants_report_light() {
        XCTAssertFalse(NSAppearance(named: .aqua)!.mpIsDark)
        XCTAssertFalse(NSAppearance(named: .vibrantLight)!.mpIsDark)
    }
}
