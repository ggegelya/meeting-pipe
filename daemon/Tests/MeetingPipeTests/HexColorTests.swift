import AppKit
import XCTest
@testable import MeetingPipe

final class HexColorTests: XCTestCase {

    private func srgbChannels(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat) {
        let c = color.usingColorSpace(.sRGB) ?? color
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

    func test_parses_uppercase_hex() {
        let color = try XCTUnwrap(HexColor.parse("#FF6B6B"))
        let (r, g, b) = srgbChannels(color)
        XCTAssertEqual(r, 1.0, accuracy: 0.01)
        XCTAssertEqual(g, 107.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(b, 107.0 / 255.0, accuracy: 0.01)
    }

    func test_parses_without_hash_prefix() {
        XCTAssertNotNil(HexColor.parse("3478F6"))
    }

    func test_returns_nil_for_malformed_input() {
        XCTAssertNil(HexColor.parse("not a color"))
        XCTAssertNil(HexColor.parse("#FFF"))             // too short
        XCTAssertNil(HexColor.parse("#GGGGGG"))          // non-hex chars
        XCTAssertNil(HexColor.parse(""))
    }
}
