import XCTest
@testable import MeetingPipe

final class PipelineLauncherTests: XCTestCase {
    private var secretsURL: URL!

    override func setUp() {
        super.setUp()
        secretsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("secrets-\(UUID().uuidString).env")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: secretsURL)
        super.tearDown()
    }

    private func writeSecrets(_ contents: String) {
        try! contents.write(to: secretsURL, atomically: true, encoding: .utf8)
    }

    func testOverlaysSecretsOnBaseEnv() {
        writeSecrets("""
        ANTHROPIC_API_KEY=sk-ant-fresh
        NOTION_TOKEN=ntn-fresh
        HF_TOKEN=hf-fresh
        """)
        let base = ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "sk-ant-stale"]
        let env = PipelineLauncher.freshEnvironment(secretsURL: secretsURL, baseEnvironment: base)

        // Secrets file wins over the base environment.
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk-ant-fresh")
        XCTAssertEqual(env["NOTION_TOKEN"], "ntn-fresh")
        XCTAssertEqual(env["HF_TOKEN"], "hf-fresh")
        // Base env keys we didn't override survive.
        XCTAssertEqual(env["PATH"], "/usr/bin")
    }

    func testStripsQuotesAroundValues() {
        writeSecrets(#"""
        ANTHROPIC_API_KEY="sk-ant-quoted"
        NOTION_TOKEN=ntn-bare
        """#)
        let env = PipelineLauncher.freshEnvironment(secretsURL: secretsURL, baseEnvironment: [:])
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk-ant-quoted")
        XCTAssertEqual(env["NOTION_TOKEN"], "ntn-bare")
    }

    func testIgnoresCommentsAndBlankLines() {
        writeSecrets("""

        # This is a comment
        ANTHROPIC_API_KEY=sk-ant-x

        # Another comment
        NOTION_TOKEN=ntn-y
        """)
        let env = PipelineLauncher.freshEnvironment(secretsURL: secretsURL, baseEnvironment: [:])
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk-ant-x")
        XCTAssertEqual(env["NOTION_TOKEN"], "ntn-y")
    }

    func testMissingFilePassesBaseEnvThrough() {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).env")
        let base = ["PATH": "/bin", "ALREADY_SET": "yes"]
        let env = PipelineLauncher.freshEnvironment(secretsURL: bogus, baseEnvironment: base)
        XCTAssertEqual(env["PATH"], "/bin")
        XCTAssertEqual(env["ALREADY_SET"], "yes")
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
    }

    func testRewriteIsObservedOnSecondCall() {
        // The whole point: rotate keys without restarting the daemon.
        writeSecrets("ANTHROPIC_API_KEY=v1")
        let first = PipelineLauncher.freshEnvironment(secretsURL: secretsURL, baseEnvironment: [:])
        XCTAssertEqual(first["ANTHROPIC_API_KEY"], "v1")

        writeSecrets("ANTHROPIC_API_KEY=v2")
        let second = PipelineLauncher.freshEnvironment(secretsURL: secretsURL, baseEnvironment: [:])
        XCTAssertEqual(second["ANTHROPIC_API_KEY"], "v2")
    }

    func testValueWithEqualsSignSurvives() {
        // Some secrets contain '=' (e.g. base64 padding). Only split on the FIRST '='.
        writeSecrets("WEIRD_KEY=foo=bar=baz")
        let env = PipelineLauncher.freshEnvironment(secretsURL: secretsURL, baseEnvironment: [:])
        XCTAssertEqual(env["WEIRD_KEY"], "foo=bar=baz")
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
