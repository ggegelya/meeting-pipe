import XCTest
import os
@testable import MeetingPipe

/// PIPE52: one resolver of a meeting's summarization engine, read by both the spawn's key policy
/// (`PipelineLauncher.cloudSecretPolicy`) and the Library's dispatch, and the on-device preview's
/// gate over it.
final class EffectiveBackendTests: XCTestCase {

    private func meta(_ json: String) -> MeetingMetaRead {
        .loaded(try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])
    }

    func test_the_resolution_order_is_regulated_nda_override_sidecar_global() {
        let pinnedApple = meta(#"{"workflow_backend": "apple_intelligence"}"#)
        let cases: [(MeetingMetaRead, Bool, String, String?, String, String)] = [
            (.absent, false, "anthropic", nil, "anthropic", "global"),
            (pinnedApple, false, "anthropic", nil, "apple_intelligence", "sidecar"),
            (pinnedApple, false, "anthropic", "local", "local", "override"),
            (meta(#"{"workflow_nda_mode": true, "workflow_backend": "anthropic"}"#), false, "anthropic", "anthropic", "local", "nda"),
            (.unreadable(kind: .parse, domain: "x", code: 1), false, "apple_intelligence", nil, "local", "nda"),
            (pinnedApple, true, "apple_intelligence", "anthropic", "local", "regulated"),
            (meta(#"{"regulated_mode": true}"#), false, "apple_intelligence", nil, "local", "regulated"),
        ]
        for (meta, regulated, global, override, backend, source) in cases {
            let r = EffectiveBackend.resolve(meta: meta, globalRegulated: regulated, globalBackend: global, override: override)
            XCTAssertEqual(r.backend, backend, "\(meta) \(regulated) \(global) \(String(describing: override))")
            XCTAssertEqual(r.source, source)
        }
    }

    /// The A16 preview is on-device only: the meeting's engine when that is on-device, else the
    /// global one when that is, else not offered. Never a cloud backend.
    func test_the_local_preview_engine_never_names_a_cloud_backend() {
        let cases: [(resolved: String, global: String, engine: String?)] = [
            ("local", "anthropic", "local"),               // a workflow pinned local
            ("anthropic", "local", "local"),               // a cloud pin under a local global
            ("apple_intelligence", "local", "apple_intelligence"),
            ("anthropic", "apple_intelligence", "apple_intelligence"),
            ("anthropic", "anthropic", nil),
            ("auto", "auto", nil),
            ("openai", "claude_cli", nil),
        ]
        for c in cases {
            XCTAssertEqual(EffectiveBackend.localPreviewEngine(resolved: c.resolved, global: c.global), c.engine,
                           "\(c.resolved) / \(c.global)")
        }
    }

    /// `cloudSecretPolicy` and the Library read the same function, so the launcher's view of a
    /// meeting on disk equals `EffectiveBackend.resolve` over the same inputs.
    func test_the_launcher_resolves_through_the_same_function() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pipe52-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cfg = dir.appendingPathComponent("config.toml")
        try "[summarization]\nbackend = \"local\"\n".write(to: cfg, atomically: true, encoding: .utf8)
        let wav = dir.appendingPathComponent("m.wav")
        try Data(#"{"workflow_backend": "anthropic"}"#.utf8).write(to: dir.appendingPathComponent("m.meta.json"))

        for override in [nil, "local", "apple_intelligence"] as [String?] {
            let launcher = PipelineLauncher.expectedBackend(for: wav, backendOverride: override, configURL: cfg)
            let pure = EffectiveBackend.resolve(
                meta: MeetingMetaRead.load(stem: "m", in: dir), globalRegulated: false,
                globalBackend: "local", override: override
            )
            XCTAssertEqual(launcher.backend, pure.backend)
            XCTAssertEqual(launcher.source, pure.source)
        }
        // The on-device preview of this anthropic-pinned meeting passes `--backend local`, and
        // that override is what strips the Anthropic key from its spawn.
        XCTAssertFalse(PipelineLauncher.cloudSecretPolicy(for: wav, configURL: cfg).stripAnthropic)
        XCTAssertTrue(PipelineLauncher.cloudSecretPolicy(for: wav, backendOverride: "local", configURL: cfg).stripAnthropic)
    }

    func test_the_preview_spawn_carries_its_backend() {
        let md = URL(fileURLWithPath: "/tmp/m.md")
        XCTAssertEqual(PipelineLauncher.previewArgs(transcriptMD: md, backend: "local"),
                       ["summarize", "/tmp/m.md", "--candidate", "--backend", "local"])
        XCTAssertEqual(PipelineLauncher.previewArgs(transcriptMD: md, backend: nil),
                       ["summarize", "/tmp/m.md", "--candidate"])
    }

    /// The Library's Apple re-summarize runs the injected summarizer over the transcript, writes the
    /// run sidecar, and spawns nothing: the publish is the regenerate chain's, not this call's.
    /// No audio on disk, so it is driven by the transcript alone.
    func test_the_library_apple_resummarize_writes_the_run_sidecar_and_spawns_nothing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pipe52-apple-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let md = dir.appendingPathComponent("m.md")
        try "transcript".write(to: md, atomically: true, encoding: .utf8)
        let spawned = dir.appendingPathComponent("spawned")
        let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
        let launcher = PipelineLauncher(
            invocation: { .init(shell: "/bin/sh", args: ["-c", ": > '\(spawned.path)'; exit 0"]) },
            environment: ["PATH": "/usr/bin:/bin"],
            appleSummarize: { anchor, transcript, _ in
                seen.withLock { $0 = [MeetingStore.stem(of: anchor), transcript.lastPathComponent] }
            }
        )
        let done = expectation(description: "summarized")
        var outcome: Result<Void, Error>?
        launcher.summarizeViaAppleIntelligence(transcriptMD: md) { outcome = $0; done.fulfill() }
        wait(for: [done], timeout: 10)

        if case .failure(let error)? = outcome { XCTFail("\(error)") }
        XCTAssertEqual(seen.withLock { $0 }, ["m", "m.md"])
        let run = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("m.run.json"))) as? [String: Any]
        )
        XCTAssertEqual(run["backend"] as? String, "apple_intelligence")
        XCTAssertFalse(FileManager.default.fileExists(atPath: spawned.path), "no mp spawned")
    }

    func test_a_failed_library_apple_resummarize_writes_no_run_sidecar() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pipe52-apple-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let md = dir.appendingPathComponent("m.md")
        try "transcript".write(to: md, atomically: true, encoding: .utf8)
        let launcher = PipelineLauncher(
            invocation: { nil },
            appleSummarize: { _, _, _ in throw AppleIntelligenceError.unavailable("model not ready") }
        )
        let done = expectation(description: "failed")
        var outcome: Result<Void, Error>?
        launcher.summarizeViaAppleIntelligence(transcriptMD: md) { outcome = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        guard case .failure? = outcome else { return XCTFail("expected failure") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("m.run.json").path))
    }
}
