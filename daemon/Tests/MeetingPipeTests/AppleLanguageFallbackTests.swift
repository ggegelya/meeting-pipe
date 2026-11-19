import os
import XCTest
@testable import MeetingPipe

/// PIPE25: Apple Intelligence's language refusal falls back to the local model instead of failing
/// the job, a language the system model reports unsupported skips Apple outright, and the
/// Library's notice for an old refusal leads with the local re-summarize.
final class AppleLanguageFallbackTests: XCTestCase {

    // MARK: - The launcher's fallback

    /// A run-all that leaves the Apple sentinel and exits 0, a summarize that records its argv and
    /// environment, and a publish that records it ran. `/bin/sh -c` puts the subcommand in `$0`.
    private struct Rig {
        let dir: URL
        let wav: URL
        let summarized: URL
        let summarizeEnv: URL
        let published: URL
        let appleCalls: OSAllocatedUnfairLock<Int>
        let launcher: PipelineLauncher

        var summarizeArgs: [String] {
            ((try? String(contentsOf: summarized, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        func run() -> Result<URL?, Error>? {
            let done = XCTestExpectation(description: "completed")
            var outcome: Result<URL?, Error>?
            launcher.runAll(wav: wav, summaryMode: .auto, onProgress: nil) { result in
                outcome = result
                done.fulfill()
            }
            _ = XCTWaiter().wait(for: [done], timeout: 15)
            return outcome
        }
    }

    private func rig(
        throwing appleError: Error?,
        language: String? = nil,
        supported: Set<String>? = nil,
        meta: String? = nil,
        tokens: [String: String] = [:]
    ) throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pipe25-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("20260101-090000.wav")
        try Data().write(to: wav)
        if let meta {
            try meta.write(to: dir.appendingPathComponent("20260101-090000.meta.json"), atomically: true, encoding: .utf8)
        }
        let summarized = dir.appendingPathComponent("summarized")
        let summarizeEnv = dir.appendingPathComponent("summarize-env")
        let published = dir.appendingPathComponent("published")
        let script = """
        case "$0" in
          run-all) : > "${1%.wav}.apple_pending.json"; exit 0 ;;
          summarize) printf '%s\\n' "$@" > '\(summarized.path)'; env > '\(summarizeEnv.path)'; exit 0 ;;
          publish) : > '\(published.path)'; exit 0 ;;
        esac
        exit 2
        """
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let launcher = PipelineLauncher(
            invocation: { .init(shell: "/bin/sh", args: ["-c", script]) },
            environment: ["PATH": "/usr/bin:/bin"],
            tokenSource: { tokens },
            reapOrphanedServer: {},
            appleSummarize: { _, _, _ in
                calls.withLock { $0 += 1 }
                if let appleError { throw appleError }
            },
            appleLanguage: { _ in (language, supported) }
        )
        return Rig(dir: dir, wav: wav, summarized: summarized, summarizeEnv: summarizeEnv,
                   published: published, appleCalls: calls, launcher: launcher)
    }

    func test_an_unsupported_language_refusal_runs_one_local_summarize_then_publishes() throws {
        let rig = try rig(throwing: AppleIntelligenceError.unsupportedLanguage("uk"), language: "uk")
        defer { try? FileManager.default.removeItem(at: rig.dir) }

        let outcome = rig.run()

        if case .failure(let error)? = outcome { XCTFail("the fallback should succeed: \(error)") }
        XCTAssertNotNil(outcome)
        XCTAssertEqual(rig.appleCalls.withLock { $0 }, 1)
        let args = rig.summarizeArgs
        XCTAssertEqual(args.first.map { URL(fileURLWithPath: $0).lastPathComponent }, "20260101-090000.md")
        XCTAssertEqual(Array(args.dropFirst()), [
            "--backend", "local",
            "--fallback-from", "apple_intelligence:unsupported_language",
            "--fallback-language", "uk",
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.published.path), "the publish followed")
    }

    func test_a_parse_failure_still_fails_and_runs_nothing_local() throws {
        let rig = try rig(throwing: AppleIntelligenceError.parseFailed("x"))
        defer { try? FileManager.default.removeItem(at: rig.dir) }

        let outcome = rig.run()

        guard case .failure(let error)? = outcome,
              case AppleIntelligenceError.parseFailed? = error as? AppleIntelligenceError else {
            return XCTFail("expected .parseFailed, got \(String(describing: outcome))")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.summarized.path), "no local summarize")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.published.path), "no publish")
    }

    func test_a_known_unsupported_language_skips_apple_entirely() throws {
        let rig = try rig(throwing: nil, language: "uk", supported: ["en", "de"])
        defer { try? FileManager.default.removeItem(at: rig.dir) }

        let outcome = rig.run()

        if case .failure(let error)? = outcome { XCTFail("\(error)") }
        XCTAssertEqual(rig.appleCalls.withLock { $0 }, 0, "no window spent on a language Apple refuses")
        XCTAssertTrue(rig.summarizeArgs.contains("apple_intelligence:unsupported_language"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.published.path))
    }

    func test_a_supported_language_goes_to_apple_and_never_spawns_a_summarize() throws {
        let rig = try rig(throwing: nil, language: "en", supported: ["en"])
        defer { try? FileManager.default.removeItem(at: rig.dir) }

        _ = rig.run()

        XCTAssertEqual(rig.appleCalls.withLock { $0 }, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.summarized.path))
    }

    func test_a_regulated_meetings_fallback_strips_both_tokens() throws {
        let rig = try rig(
            throwing: AppleIntelligenceError.unsupportedLanguage("uk"),
            meta: #"{"schema_version": 6, "regulated_mode": true}"#,
            tokens: ["ANTHROPIC_API_KEY": "sk-a", "NOTION_TOKEN": "ntn-n"]
        )
        defer { try? FileManager.default.removeItem(at: rig.dir) }

        _ = rig.run()

        let env = try String(contentsOf: rig.summarizeEnv, encoding: .utf8)
        XCTAssertFalse(env.contains("ANTHROPIC_API_KEY="), "the local fallback never carries the Anthropic key")
        XCTAssertFalse(env.contains("NOTION_TOKEN="), "regulated strips Notion too")
    }

    // MARK: - The pre-check, pure

    func test_the_precheck_skips_apple_only_for_a_known_unsupported_language() {
        XCTAssertEqual(AppleLanguageRoute.decide(language: "uk", supported: ["en", "de"]), .skipToLocal(language: "uk"))
        XCTAssertEqual(AppleLanguageRoute.decide(language: "en-US", supported: ["en"]), .tryApple)
        XCTAssertEqual(AppleLanguageRoute.decide(language: nil, supported: ["en"]), .tryApple, "unknown tries Apple")
        XCTAssertEqual(AppleLanguageRoute.decide(language: "auto", supported: ["en"]), .tryApple)
        XCTAssertEqual(AppleLanguageRoute.decide(language: "uk", supported: nil), .tryApple, "no list tries Apple")
        XCTAssertEqual(AppleLanguageRoute.decide(language: "uk", supported: []), .tryApple)
    }

    func test_the_meeting_language_prefers_a_pinned_asr_language_over_the_detected_one() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pipe25-lang-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = dir.appendingPathComponent("m.json")
        try #"{"language": "uk", "segments": []}"#.write(to: json, atomically: true, encoding: .utf8)
        XCTAssertEqual(AppleLanguageRoute.meetingLanguage(pinned: "auto", transcriptJSON: json), "uk")
        XCTAssertEqual(AppleLanguageRoute.meetingLanguage(pinned: "ru", transcriptJSON: json), "ru")
        XCTAssertNil(AppleLanguageRoute.meetingLanguage(pinned: "", transcriptJSON: dir.appendingPathComponent("none.json")))
    }

    // MARK: - The Library notice

    private static let refusal = AppleIntelligenceError.unsupportedLanguage("uk").errorDescription!

    func test_the_refusal_marker_presents_as_its_own_cause() {
        let problem = FailurePresentation(diagnostics: Self.refusal, operation: .summary)
        XCTAssertEqual(problem.metadata.cause, .unsupportedLanguage)
        XCTAssertEqual(problem.title, "Apple Intelligence can't summarize this language")
        XCTAssertTrue(problem.explanation.hasSuffix("Re-summarize it on this Mac with \(SummarizationEngine.local.name)."),
                      problem.explanation)
        XCTAssertEqual(FailurePresentation(diagnostics: "network timeout", operation: .summary).metadata.cause, .unknown)
    }

    func test_the_swift_only_cause_is_never_decoded_from_a_sidecar() {
        let data = Data(#"{"schema_version":1,"cause":"unsupported_language","operation":"summary"}"#.utf8)
        XCTAssertNil(FailureMetadata.decode(data))
    }

    func test_the_notice_leads_with_re_summarize_and_withholds_retry_while_still_apple() {
        let base = FailureNoticeAction.Inputs(
            cause: .unsupportedLanguage, hasSettings: true, canDownloadModel: true,
            canRetry: true, canReSummarizeLocal: true
        )
        XCTAssertEqual(FailureNoticeAction.decide(base), [.reSummarizeLocal])

        var missing = base
        missing.localModelCached = false
        XCTAssertEqual(FailureNoticeAction.decide(missing), [.downloadModel, .reSummarizeLocal])

        var moved = base
        moved.resolvesToApple = false
        XCTAssertEqual(FailureNoticeAction.decide(moved), [.reSummarizeLocal, .retry])
    }

    func test_other_causes_keep_their_order() {
        let credits = FailureNoticeAction.Inputs(cause: .credits, hasBilling: true, canRetry: true)
        XCTAssertEqual(FailureNoticeAction.decide(credits), [.billing, .retry])
        let model = FailureNoticeAction.Inputs(cause: .modelMissing, hasSettings: true, canDownloadModel: true, canRetry: true)
        XCTAssertEqual(FailureNoticeAction.decide(model), [.downloadModel, .retry])
        let held = FailureNoticeAction.Inputs(cause: .unknown, canShowRecording: true, canReSummarizeLocal: true)
        XCTAssertEqual(FailureNoticeAction.decide(held), [.showRecording], "re-summarize belongs to the refusal only")
    }

    // MARK: - Provenance

    func test_the_provenance_clause_names_the_refused_language() {
        XCTAssertEqual(
            SummarizationEngine.fallbackClause(from: "apple_intelligence", cause: "unsupported_language", language: "uk"),
            "because Apple Intelligence does not support Ukrainian"
        )
        XCTAssertEqual(
            SummarizationEngine.fallbackClause(from: "apple_intelligence", cause: "unsupported_language"),
            "because Apple Intelligence does not support this language"
        )
    }
}
