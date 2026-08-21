import SwiftUI
import XCTest
@testable import MeetingPipe

/// AUTO3 leg 3: the Preferences control that says what an outside AI tool can
/// reach.
///
/// The counts are decoded from `mp mcp-serve --status --json`, never recomputed
/// here, so what these pin is the contract between the two trees: the field
/// names Python writes, and the fact that the switch defaults to off and
/// round-trips. The visibility rule itself is Python's and is pinned in
/// `pipeline/tests/test_visibility.py`; a second Swift implementation of it is
/// exactly what leg 0 exists to prevent.
final class MCPStatusTests: XCTestCase {

    private func makeTempConfigURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.toml")
    }

    // MARK: - The Python -> Swift payload

    func test_decodes_the_status_payload_python_writes() throws {
        let json = """
        {
          "enabled": true,
          "transport": "stdio",
          "tools": ["search_meetings", "get_meeting", "get_transcript",
                    "list_meetings", "list_actions"],
          "sdk_available": true,
          "visible": 175,
          "withheld": 42,
          "withheld_by_reason": {"nda": 3, "no_sidecar": 39}
        }
        """
        guard case .success(let status) = MCPStatusStore.decode(Data(json.utf8)) else {
            return XCTFail("the status payload did not decode")
        }
        XCTAssertTrue(status.enabled)
        XCTAssertEqual(status.transport, "stdio")
        XCTAssertEqual(status.visible, 175)
        XCTAssertEqual(status.withheld, 42)
        XCTAssertEqual(status.tools.count, 5)
        XCTAssertTrue(status.sdkAvailable)
    }

    func test_the_withheld_count_is_explained_by_reason() {
        // A bare "42 withheld" is a number a user quietly stops believing; the
        // reasons are what make a fail-closed filter legible.
        let status = MCPStatus(
            enabled: true, transport: "stdio", tools: [], sdkAvailable: true,
            visible: 175, withheld: 42,
            withheldByReason: ["nda": 3, "no_sidecar": 39]
        )
        XCTAssertEqual(
            status.withheldExplanation,
            "3 under an NDA workflow, 39 with no recorded privacy stance"
        )
    }

    func test_a_regulated_reason_reads_as_english_too() {
        let status = MCPStatus(
            enabled: false, transport: "stdio", tools: [], sdkAvailable: false,
            visible: 1, withheld: 1, withheldByReason: ["regulated": 1]
        )
        XCTAssertEqual(status.withheldExplanation, "1 recorded in regulated mode")
    }

    func test_a_malformed_payload_is_an_error_not_a_zero() throws {
        // Rendering "0 withheld" for a status read that failed would tell the
        // owner the opposite of the truth about their own privacy.
        guard case .failure = MCPStatusStore.decode(Data("not json".utf8)) else {
            return XCTFail("a malformed payload must not decode to a status")
        }
    }

    // MARK: - The config key

    func test_mcp_is_off_by_default() throws {
        let store = try ConfigStore(configURL: try makeTempConfigURL())
        XCTAssertFalse(store.mcpEnabled)
        XCTAssertFalse(ConfigDefaults.mcpEnabled)
    }

    func test_mcp_enabled_round_trips() throws {
        let url = try makeTempConfigURL()
        try """
        [mcp]
        enabled = true
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = try ConfigStore(configURL: url)
        XCTAssertTrue(store.mcpEnabled)

        store.mcpEnabled = false
        try store.saveNow()
        XCTAssertFalse(try ConfigStore(configURL: url).mcpEnabled)
    }

    func test_saving_mcp_preserves_unknown_pipeline_keys() throws {
        let url = try makeTempConfigURL()
        try """
        [summarization]
        backend = "anthropic"

        [mcp]
        enabled = false
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = try ConfigStore(configURL: url)
        store.mcpEnabled = true
        try store.saveNow()

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("enabled = true"))
        XCTAssertTrue(text.contains("anthropic"))
    }

    // MARK: - The tools row's measure

    /// Why the Tools row stacks and wraps instead of hugging the right edge.
    ///
    /// It shipped as a `SettingsRow`, whose trailing slot is fixed to its ideal
    /// width (UX43, so a ghost button stops collapsing to an ellipsis). That is
    /// right for a button or a pill and wrong for a list the server sizes: the
    /// five advertised names joined with commas are 73 characters of mono at
    /// `MPType.textXS`, about 482pt, and the row holding them is 512pt across
    /// once the 16pt column gap is taken. The 30pt left over is what squeezed
    /// the label until "Tools" wrapped one character per line.
    ///
    /// The measure is the pane's, not the window's. `PreferencesView` caps its
    /// content at 620 and pads it 32 a side, and `SettingsStackRow` pads 14 more,
    /// so the chips get 528 at the cap. Below it the split view's sidebar takes
    /// its share of the 780 minimum, down to 448 when that sidebar is dragged to
    /// its 240 maximum. Both ends are checked because the failure this replaces
    /// was a control that did not fit its row and took the label's width instead.
    ///
    /// Widths are derived from the chip's geometry rather than rendered, on the
    /// principle `FlowLayoutTests` states: pinning real glyph widths would pin
    /// the host's font metrics. What is asserted is therefore the robust half,
    /// that nothing overflows and nothing is dropped, not the row count. For the
    /// record, at SF Mono's 0.6 advance the five chips come to about 572pt, so
    /// they wrap at both measures rather than fitting either.
    func test_the_advertised_tools_wrap_within_the_card_at_every_measure() {
        let names = ["search_meetings", "get_meeting", "get_transcript",
                     "list_meetings", "list_actions"]
        // SettingsTag: 8pt of padding a side around mono text at MPType.textSM.
        let sizes = names.map { name in
            CGSize(width: 16 + CGFloat(name.count) * MPType.textSM * 0.6, height: 22)
        }

        for measure in [CGFloat(448), CGFloat(528)] {
            let rows = FlowLayout.rows(for: sizes, width: measure, spacing: 6)
            for row in rows {
                XCTAssertLessThanOrEqual(row.width, measure,
                    "no row may run past the card at \(measure)")
            }
            XCTAssertEqual(rows.flatMap(\.indices).sorted(), Array(names.indices),
                "every tool has to land in a row at \(measure), each exactly once")
        }

        // And no single name is wider than the narrowest card, so no chip is ever
        // the one that gets a row to itself and still overflows it.
        for (name, size) in zip(names, sizes) {
            XCTAssertLessThan(size.width, 448, "\(name) should fit the narrowest card on its own")
        }
    }
}
