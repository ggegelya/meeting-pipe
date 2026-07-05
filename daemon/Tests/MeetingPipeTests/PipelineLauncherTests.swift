import XCTest
@testable import MeetingPipe

final class PipelineLauncherTests: XCTestCase {

    private func writeTemp(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-\(UUID().uuidString).json")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeConfig(_ toml: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-\(UUID().uuidString).toml")
        try! toml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // AI3: the Swift side must decode exactly what `mp ask --out` writes,
    // including the snake_case `sources_considered` key and a null `error`.
    func testAskAnswerDecodesThePythonContract() throws {
        let json = #"""
        {
          "question": "what about the budget?",
          "answer": "You cut it 12%. [20260101-0900]",
          "citations": [{"stem": "20260101-0900", "title": "Budget review"}],
          "sources_considered": ["20260101-0900", "20260102-1000"],
          "backend": "local",
          "model": "mlx-community/Qwen2.5-14B-Instruct-4bit",
          "verified": true,
          "empty": false,
          "error": null
        }
        """#
        let a = try XCTUnwrap(AskAnswer.load(from: try writeTemp(json)))
        XCTAssertEqual(a.answer, "You cut it 12%. [20260101-0900]")
        XCTAssertEqual(a.citations.map(\.stem), ["20260101-0900"])
        XCTAssertEqual(a.citations.first?.title, "Budget review")
        XCTAssertEqual(a.sourcesConsidered, ["20260101-0900", "20260102-1000"])
        XCTAssertEqual(a.backend, "local")
        XCTAssertTrue(a.verified)
        XCTAssertFalse(a.empty)
        XCTAssertNil(a.error)
    }

    func testAskAnswerDecodesTheErrorAndEmptyPaths() throws {
        let err = try XCTUnwrap(AskAnswer.load(from: try writeTemp(
            #"{"question":"q","answer":"","citations":[],"sources_considered":[],"backend":null,"model":null,"verified":false,"empty":false,"error":"local model not installed"}"#
        )))
        XCTAssertEqual(err.error, "local model not installed")
        XCTAssertTrue(err.citations.isEmpty)

        let empty = try XCTUnwrap(AskAnswer.load(from: try writeTemp(
            #"{"question":"q","answer":"No searchable meetings found.","citations":[],"sources_considered":[],"backend":null,"model":null,"verified":false,"empty":true,"error":null}"#
        )))
        XCTAssertTrue(empty.empty)
        XCTAssertNil(empty.backend)
    }

    // MARK: - TECH-SEC5: fail-closed subprocess env (SEC8: tokens come from the inherited daemon env)

    func testFreshEnvironmentStripsAnthropicKeyOnly() {
        let base = ["ANTHROPIC_API_KEY": "sk-x", "NOTION_TOKEN": "nt-y"]
        let env = PipelineLauncher.freshEnvironment(
            baseEnvironment: base, stripAnthropicKey: true, stripNotionToken: false
        )
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertEqual(env["NOTION_TOKEN"], "nt-y")
    }

    func testFreshEnvironmentStripsBothTokens() {
        let base = ["ANTHROPIC_API_KEY": "sk-x", "NOTION_TOKEN": "nt-y"]
        let env = PipelineLauncher.freshEnvironment(
            baseEnvironment: base, stripAnthropicKey: true, stripNotionToken: true
        )
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNil(env["NOTION_TOKEN"])
    }

    func testFreshEnvironmentKeepsTokensByDefault() {
        let base = ["ANTHROPIC_API_KEY": "sk-x", "NOTION_TOKEN": "nt-y"]
        let env = PipelineLauncher.freshEnvironment(baseEnvironment: base)
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk-x")
        XCTAssertEqual(env["NOTION_TOKEN"], "nt-y")
    }

    func testFreshEnvironmentPassesUnrelatedKeysThrough() {
        let base = ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "sk-x"]
        let env = PipelineLauncher.freshEnvironment(baseEnvironment: base, stripAnthropicKey: true)
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
    }

    // MARK: - TECH-SEC5: cloudSecretPolicy

    func testPolicyRegulatedStripsBoth() {
        let cfg = writeConfig("[modes]\nregulated_mode = true\n")
        defer { try? FileManager.default.removeItem(at: cfg) }
        let policy = PipelineLauncher.cloudSecretPolicy(for: nil, configURL: cfg)
        XCTAssertTrue(policy.stripAnthropic)
        XCTAssertTrue(policy.stripNotion)
    }

    func testPolicyLocalBackendStripsAnthropicOnly() {
        // On-device summary, but a Notion publish is still intended: keep NOTION_TOKEN.
        let cfg = writeConfig("[summarization]\nbackend = \"local\"\n")
        defer { try? FileManager.default.removeItem(at: cfg) }
        let policy = PipelineLauncher.cloudSecretPolicy(for: nil, configURL: cfg)
        XCTAssertTrue(policy.stripAnthropic)
        XCTAssertFalse(policy.stripNotion)
    }

    func testPolicyAnthropicBackendStripsNothing() {
        let cfg = writeConfig("[summarization]\nbackend = \"anthropic\"\n")
        defer { try? FileManager.default.removeItem(at: cfg) }
        let policy = PipelineLauncher.cloudSecretPolicy(for: nil, configURL: cfg)
        XCTAssertFalse(policy.stripAnthropic)
        XCTAssertFalse(policy.stripNotion)
    }

    func testPolicyAppleIntelligenceStripsAnthropicOnly() {
        // On-device summary (Apple), but a Notion publish is still allowed. (SEC review)
        let cfg = writeConfig("[summarization]\nbackend = \"apple_intelligence\"\n")
        defer { try? FileManager.default.removeItem(at: cfg) }
        let policy = PipelineLauncher.cloudSecretPolicy(for: nil, configURL: cfg)
        XCTAssertTrue(policy.stripAnthropic)
        XCTAssertFalse(policy.stripNotion)
    }

    func testPolicyNdaSidecarStripsBoth() throws {
        let cfg = writeConfig("[summarization]\nbackend = \"anthropic\"\n")
        defer { try? FileManager.default.removeItem(at: cfg) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("20260506-1500.wav")
        let meta = dir.appendingPathComponent("20260506-1500.meta.json")
        try #"{"workflow_nda_mode": true, "workflow_backend": "local"}"#
            .data(using: .utf8)!.write(to: meta)
        let policy = PipelineLauncher.cloudSecretPolicy(for: wav, configURL: cfg)
        XCTAssertTrue(policy.stripAnthropic)
        XCTAssertTrue(policy.stripNotion)
    }

    // MARK: - progress sentinel parsing (TECH-UX5)

    func test_parseProgress_extracts_stage_and_elapsed() {
        let p = PipelineLauncher.parseProgress(#"__MP_PROGRESS__ {"stage":"summarize","elapsed_s":42,"beat":8}"#)
        XCTAssertEqual(p, PipelineProgress(stage: "summarize", elapsedSec: 42))
    }

    func test_parseProgress_rejects_non_sentinel_and_malformed_lines() {
        XCTAssertNil(PipelineLauncher.parseProgress("2026-05-29 INFO mp.run_all: summarizing"))
        XCTAssertNil(PipelineLauncher.parseProgress("__MP_PROGRESS__ not-json"))
        XCTAssertNil(PipelineLauncher.parseProgress(#"__MP_PROGRESS__ {"elapsed_s":1}"#))
    }
}
