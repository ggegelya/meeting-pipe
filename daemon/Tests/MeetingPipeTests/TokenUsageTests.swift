import XCTest
@testable import MeetingPipe

/// PIPE27: the run's token spend reaches the detail header, and the split long-meeting knobs
/// read the way the pipeline reads them.
final class TokenUsageTests: XCTestCase {

    func test_the_header_label_renders_counts_from_run_json_usage() throws {
        let run = try JSONSerialization.jsonObject(with: Data(
            #"{"backend":"anthropic","usage":{"calls":2,"input_tokens":12345,"output_tokens":1234}}"#.utf8
        )) as? [String: Any]
        let usage = TokenUsage(json: run?["usage"])
        XCTAssertEqual(usage, TokenUsage(input: 12_345, output: 1_234))
        XCTAssertEqual(TokenUsage.label(usage, locale: Locale(identifier: "en_US")),
                       "12,345 tokens in, 1,234 out")
    }

    func test_a_run_without_usage_renders_nothing() {
        XCTAssertNil(TokenUsage(json: nil))
        XCTAssertNil(TokenUsage(json: ["input_tokens": 5]), "both counts or nothing")
        XCTAssertNil(TokenUsage(json: ["input_tokens": -1, "output_tokens": 2]))
        XCTAssertNil(TokenUsage.label(nil))
    }

    func test_the_store_decodes_usage_off_the_run_sidecar() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pipe27-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paid = "20260511-143110", free = "20260511-153110"
        for stem in [paid, free] {
            try Data().write(to: dir.appendingPathComponent("\(stem).wav"))
            try Data(#"{"title":"x"}"#.utf8).write(to: dir.appendingPathComponent("\(stem).summary.json"))
        }
        try Data(#"{"stem":"\#(paid)","backend":"anthropic","usage":{"input_tokens":10,"output_tokens":2}}"#.utf8)
            .write(to: dir.appendingPathComponent("\(paid).run.json"))
        try Data(#"{"stem":"\#(free)","backend":"local"}"#.utf8)
            .write(to: dir.appendingPathComponent("\(free).run.json"))
        let store = MeetingStore(recordingsDir: dir)
        let exp = expectation(description: "scan")
        var captured: [Meeting] = []
        let cancel = store.$meetings.dropFirst().sink { captured = $0; exp.fulfill() }
        store.start()
        wait(for: [exp], timeout: 2.0)
        cancel.cancel()
        let byStem = Dictionary(uniqueKeysWithValues: captured.map { ($0.stem, $0) })
        XCTAssertEqual(byStem[paid]?.tokenUsage, TokenUsage(input: 10, output: 2))
        XCTAssertNil(byStem[free]?.tokenUsage)
    }

    private func store(_ toml: String) throws -> ConfigStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pipe27-\(UUID().uuidString).toml")
        try toml.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return ConfigStore(configURL: url)
    }

    func test_local_chunking_falls_back_like_the_pipeline() throws {
        XCTAssertEqual(try store("[summarization]\nskip_above_chars = 0\n").summarizationLocalChunkAboveChars, 80_000,
                       "a zero gate no longer turns local windowing off")
        XCTAssertEqual(try store("[summarization]\nskip_above_chars = 50000\n").summarizationLocalChunkAboveChars, 50_000)
        XCTAssertEqual(try store("[summarization]\nskip_above_chars = 0\nlocal_chunk_above_chars = 30000\n")
            .summarizationLocalChunkAboveChars, 30_000)
        XCTAssertEqual(try store("").summarizationLocalChunkAboveChars, 80_000)
    }

    /// Moving the gate from Preferences pins the chunk size it was showing, or the pipeline
    /// (which derives an absent chunk key from the gate) would move local chunking with it.
    func test_moving_the_gate_pins_the_local_chunk_size_it_showed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pipe27-\(UUID().uuidString).toml")
        try "[summarization]\nskip_above_chars = 50000\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConfigStore(configURL: url)
        store.summarizationSkipAboveChars = 200_000
        try store.saveNow()
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("skip_above_chars = 200000"), raw)
        XCTAssertTrue(raw.contains("local_chunk_above_chars = 50000"), raw)
        XCTAssertEqual(ConfigStore(configURL: url).summarizationLocalChunkAboveChars, 50_000)
    }
}
