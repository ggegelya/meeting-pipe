import XCTest

/// SEC23: the daemon must not put a managed token into its own process environment, where every `Process`
/// it starts inherits it. `PipelineLauncher.runMP` hands a spawn its tokens, and nothing else may.
final class SecretsEnvironmentFenceTests: XCTestCase {
    func test_no_source_file_setenvs_a_managed_token() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "found no sources under \(sources.path)")
        let forbidden = ["setenv(\"ANTHROPIC_API_KEY\"", "setenv(\"NOTION_TOKEN\"", "setenv(\"OPENAI_API_KEY\"", "setenv(key",
                         "environment[\"NOTION_TOKEN\"]", "environment[\"ANTHROPIC_API_KEY\"]", "environment[\"OPENAI_API_KEY\"]"]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for needle in forbidden {
                XCTAssertFalse(text.contains(needle), "\(file.lastPathComponent) contains \(needle)")
            }
        }
    }
}
