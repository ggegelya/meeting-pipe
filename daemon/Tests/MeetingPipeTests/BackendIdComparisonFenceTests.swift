import XCTest
@testable import MeetingPipe

/// ARCH14: no source file decides something about a summarization backend by comparing a string
/// against one of the six ids. `SummarizationEngine` carries `locality`, `usesLocalModel` and
/// `requiredSecret`, and `SummarizationBackend` reads them for a configured id; a site that
/// restates `== "local" || == "auto"` is the drift this task removed, nine copies of it, with
/// fallbacks that disagreed. Reads the checkout, like `BundleModuleFenceTests`.
/// T7 source fence (deliberate): walks daemon/Sources and bans `==`, `!=` or `case` against a backend id in any file that names a backend, outside the vocabulary's own files and a reasoned allowlist. Missing seam: none; the claim is about the source text itself.
final class BackendIdComparisonFenceTests: XCTestCase {

    /// The vocabulary itself: the engine table and the workflow pin's raw values.
    private static let exemptFiles: Set<String> = [
        "daemon/Sources/MeetingPipe/SummarizationEngine.swift",
        "daemon/Sources/MeetingPipe/Workflow.swift",
    ]

    /// Lines that match the shape but compare something other than a backend, in a file that also
    /// happens to name one. Keyed by file and the exact trimmed line, so a new backend comparison
    /// in the same file is still caught.
    private static let allowed: [String: Set<String>] = [
        // `local` here is a publish state from `<stem>.publish.json`, not a backend.
        "daemon/Sources/MeetingPipe/MeetingRow.swift": [
            #"if meeting.publishState == "local"   { return nil }"#,
            #"case "local":"#,
        ],
        // `auto` here is a summary or transcription language, not a backend.
        "daemon/Sources/MeetingPipe/Summarization/AppleIntelligenceSummarizer.swift": [
            #"if c.isEmpty || c == "auto" || c.count != 2 {"#,
        ],
        "daemon/Sources/MeetingPipe/Transcription/FluidAudioRunner.swift": [
            #"guard let code = hint?.lowercased(), !code.isEmpty, code != "auto" else { return nil }"#,
        ],
    ]

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
            .deletingLastPathComponent()   // repo root
    }

    /// Every non-comment line comparing against a backend id, in a file that names a backend,
    /// as path -> trimmed lines.
    private func comparisons() throws -> [String: [String]] {
        let root = repoRoot()
        let ids = SummarizationEngine.all.map { NSRegularExpression.escapedPattern(for: $0.id) }.joined(separator: "|")
        let pattern = try NSRegularExpression(pattern: #"(==|!=|\bcase)\s*"(\#(ids))""#)
        var found: [String: [String]] = [:]
        var walked = 0
        for target in ["daemon/Sources/MeetingPipe", "daemon/Sources/MeetingPipeCore"] {
            let dir = root.appendingPathComponent(target)
            guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
                XCTFail("cannot walk \(target)")
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                walked += 1
                let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
                let text = try String(contentsOf: url, encoding: .utf8)
                guard text.range(of: "backend", options: .caseInsensitive) != nil else { continue }
                for line in text.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") { continue }
                    if pattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                        found[path, default: []].append(trimmed)
                    }
                }
            }
        }
        XCTAssertGreaterThan(walked, 100, "the walk found almost nothing; re-point this fence")
        return found
    }

    func test_no_source_file_compares_a_string_against_a_backend_id() throws {
        var strays: [String] = []
        for (path, lines) in try comparisons() where !Self.exemptFiles.contains(path) {
            for line in lines where !(Self.allowed[path]?.contains(line) ?? false) {
                strays.append("\(path): \(line)")
            }
        }
        XCTAssertTrue(
            strays.isEmpty,
            "string comparison against a backend id (read SummarizationEngine / SummarizationBackend instead): "
                + strays.sorted().joined(separator: "; ")
        )
    }

    /// Keeps the allowlist honest: an entry whose line is gone is an exemption nobody needs.
    func test_every_allowlisted_line_still_exists() throws {
        let found = try comparisons()
        for (path, lines) in Self.allowed {
            for line in lines {
                XCTAssertTrue(found[path]?.contains(line) ?? false, "stale allowlist entry in \(path): \(line)")
            }
        }
    }
}
