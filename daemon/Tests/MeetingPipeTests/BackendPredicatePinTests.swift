import XCTest
@testable import MeetingPipe

/// ARCH14: what each consumer of the configured summarization backend decides, for every id the
/// product ships plus an empty and an unknown one, pinned before the backend stopped being a
/// `String` and kept after. Each table is the decision as it stood on `main` the day the field was
/// typed, so a refactor that moves a predicate cannot also quietly move its answer.
///
/// The unknown id matters as much as the six: a `config.toml` written by a newer pipeline can name a
/// backend this build has never heard of, and today every site treats it as a cloud engine that
/// needs nothing (keeps every token, clamps under zero egress, prefetches nothing).
final class BackendPredicatePinTests: XCTestCase {

    /// The six shipped ids, an empty value, and one this build does not know.
    private static let ids = [
        "anthropic", "local", "auto", "apple_intelligence", "claude_cli", "openai", "", "some_future_vendor",
    ]

    /// The one adapter between the pinned tables and the field's type: the raw id on `main` before
    /// the refactor, the typed value after it. Every expectation stays a raw string.
    private func backend(_ id: String) -> SummarizationBackend { SummarizationBackend(rawValue: id) }

    private var cleanup: [URL] = []

    override func tearDown() {
        for url in cleanup { try? FileManager.default.removeItem(at: url) }
        cleanup = []
        super.tearDown()
    }

    private func config(_ toml: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("arch14-\(UUID().uuidString).toml")
        try toml.write(to: url, atomically: true, encoding: .utf8)
        cleanup.append(url)
        return url
    }

    // MARK: - PipelineLauncher.cloudSecretPolicy

    /// (stripAnthropic, stripNotion, stripOpenAI, zeroEgress). Only the two on-device engines strip
    /// the summarizer keys; nothing strips Notion outside zero egress.
    private static let secretPolicy: [String: [Bool]] = [
        "anthropic": [false, false, false, false],
        "local": [true, false, true, false],
        "auto": [false, false, false, false],
        "apple_intelligence": [true, false, true, false],
        "claude_cli": [false, false, false, false],
        "openai": [false, false, false, false],
        "": [false, false, false, false],
        "some_future_vendor": [false, false, false, false],
    ]

    private func flags(_ p: PipelineLauncher.CloudSecretPolicy) -> [Bool] {
        [p.stripAnthropic, p.stripNotion, p.stripOpenAI, p.zeroEgress]
    }

    func test_secret_policy_for_each_configured_backend() throws {
        for id in Self.ids {
            let cfg = try config("[summarization]\nbackend = \"\(id)\"\n")
            XCTAssertEqual(flags(PipelineLauncher.cloudSecretPolicy(for: nil, configURL: cfg)), Self.secretPolicy[id], id)
        }
    }

    func test_secret_policy_for_each_override_over_a_cloud_config() throws {
        let cfg = try config("[summarization]\nbackend = \"anthropic\"\n")
        for id in Self.ids {
            XCTAssertEqual(
                flags(PipelineLauncher.cloudSecretPolicy(for: nil, backendOverride: id, configURL: cfg)),
                Self.secretPolicy[id], id
            )
        }
    }

    func test_secret_policy_for_each_workflow_pin_in_a_sidecar() throws {
        let cfg = try config("[summarization]\nbackend = \"anthropic\"\n")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arch14-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cleanup.append(dir)
        for (n, id) in Self.ids.enumerated() {
            let stem = "20261126-10\(String(format: "%02d", n))"
            try #"{"workflow_backend": "\#(id)"}"#.write(
                to: dir.appendingPathComponent("\(stem).meta.json"), atomically: true, encoding: .utf8
            )
            let wav = dir.appendingPathComponent("\(stem).wav")
            XCTAssertEqual(flags(PipelineLauncher.cloudSecretPolicy(for: wav, configURL: cfg)), Self.secretPolicy[id], id)
        }
    }

    func test_secret_policy_under_regulated_mode_strips_everything_for_every_backend() throws {
        for id in Self.ids {
            let cfg = try config("[modes]\nregulated_mode = true\n[summarization]\nbackend = \"\(id)\"\n")
            XCTAssertEqual(flags(PipelineLauncher.cloudSecretPolicy(for: nil, configURL: cfg)), [true, true, true, true], id)
        }
    }

    // MARK: - SetupChecklist

    /// What a single route with this backend needs, before the regulated clamp.
    private static let needs: [String: Set<SetupChecklist.Gap>] = [
        "anthropic": [.anthropicKey],
        "local": [.localModel],
        "auto": [.anthropicKey, .localModel],
        "apple_intelligence": [],
        "claude_cli": [.claudeBinary],
        "openai": [.openaiKey],
        "": [],
        "some_future_vendor": [],
    ]

    func test_checklist_needs_for_each_global_backend() {
        for id in Self.ids {
            let inputs = SetupChecklist.Inputs(globalBackend: id, globalSinks: ["filesystem"])
            XCTAssertEqual(SetupChecklist.required(inputs), Self.needs[id], id)
        }
    }

    func test_checklist_needs_for_each_workflow_backend() {
        for id in Self.ids {
            let inputs = SetupChecklist.Inputs(
                globalBackend: "anthropic", globalSinks: ["filesystem"],
                workflowBackends: [id], workflowSinks: [["filesystem"]]
            )
            XCTAssertEqual(SetupChecklist.required(inputs), Self.needs[id], id)
        }
    }

    func test_checklist_needs_only_the_local_model_under_regulated_mode() {
        for id in Self.ids {
            let inputs = SetupChecklist.Inputs(regulatedMode: true, globalBackend: id, globalSinks: ["notion"])
            XCTAssertEqual(SetupChecklist.required(inputs), [.localModel], id)
        }
    }

    func test_checklist_items_with_nothing_set_up() {
        let expected: [String: [SetupChecklist.Item]] = [
            "anthropic": [.anthropicKey],
            "local": [.localModel],
            "auto": [.anthropicKey, .localModel],
            "apple_intelligence": [],
            "claude_cli": [.claudeBinary],
            "openai": [.openaiKey],
            "": [],
            "some_future_vendor": [],
        ]
        for id in Self.ids {
            let inputs = SetupChecklist.Inputs(
                globalBackend: id, globalSinks: ["filesystem"],
                anthropicKeyPresent: false, openaiKeyPresent: false, claudeBinaryPresent: false,
                localModelMissing: true
            )
            XCTAssertEqual(SetupChecklist.decide(inputs), expected[id], id)
        }
    }

    // MARK: - The local model

    func test_prefetch_follows_the_backends_that_may_need_the_local_model() {
        for id in Self.ids {
            let decision = ConfigRefreshCoordinator.prefetchDecision(backend: backend(id), modelId: "mlx/qwen")
            let expected: ConfigRefreshCoordinator.PrefetchAction = ["local", "auto"].contains(id)
                ? .ensure(modelId: "mlx/qwen") : .cancelAndIdle
            XCTAssertEqual(decision, expected, id)
        }
    }

    func test_only_the_local_backend_preloads() {
        for id in Self.ids {
            XCTAssertEqual(
                LocalModelPreloader.shouldPreload(enabled: true, backend: backend(id), modelCached: true, fitsMemory: true),
                id == "local", id
            )
        }
    }

    // MARK: - Zero egress and the on-device preview

    func test_the_regulated_clamp_for_each_backend() {
        for id in Self.ids {
            XCTAssertEqual(RegulatedMode.effectiveBackend(configured: id, regulated: true, workflowNDA: false), "local", id)
            XCTAssertEqual(RegulatedMode.effectiveBackend(configured: id, regulated: false, workflowNDA: true), "local", id)
            XCTAssertEqual(RegulatedMode.effectiveBackend(configured: id, regulated: false, workflowNDA: false), id, id)
        }
    }

    func test_the_on_device_preview_engine_for_each_resolved_backend() {
        for id in Self.ids {
            let onDevice = ["local", "apple_intelligence"].contains(id)
            XCTAssertEqual(EffectiveBackend.localPreviewEngine(resolved: id, global: "anthropic"), onDevice ? id : nil, id)
            XCTAssertEqual(EffectiveBackend.localPreviewEngine(resolved: "anthropic", global: id), onDevice ? id : nil, id)
        }
    }

    func test_reaches_cloud_for_each_resolved_backend() {
        for id in Self.ids {
            let onDevice = ["local", "apple_intelligence"].contains(id)
            XCTAssertEqual(SingleMeetingResummarize.reachesCloud(isZeroEgress: false, resolvedBackend: id), !onDevice, id)
        }
    }

    // MARK: - ConfigStore

    func test_a_missing_backend_key_loads_as_anthropic() throws {
        XCTAssertEqual(ConfigStore(configURL: try config("[summarization]\nmodel = \"m\"\n")).summarizationBackend, "anthropic")
        XCTAssertEqual(ConfigStore(configURL: try config("")).summarizationBackend, "anthropic")
    }

    /// The scope item the typed field had to keep: an id this build does not know is written back
    /// verbatim, not rewritten to a default, when an unrelated setting is saved.
    func test_every_backend_round_trips_through_load_and_save_unchanged() throws {
        for id in Self.ids {
            let url = try config("[summarization]\nbackend = \"\(id)\"\n")
            let store = ConfigStore(configURL: url)
            XCTAssertEqual(store.summarizationBackend, backend(id), id)
            store.manualHotkey = "cmd+shift+z"
            try store.saveNow()
            let raw = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(raw.contains("backend = \"\(id)\""), "\(id) did not survive a save: \(raw)")
            XCTAssertEqual(ConfigStore(configURL: url).summarizationBackend, backend(id), id)
        }
    }
}
