import XCTest
@testable import MeetingPipe

/// Pins the extracted `ConfigRefreshCoordinator` (TECH-H1-FINISH): the
/// model-prefetch branch is decided by a pure function, and `start()`
/// seeds the regulated-mode glyph from the persisted flag.
final class ConfigRefreshCoordinatorTests: XCTestCase {

    // MARK: - prefetchDecision (pure)

    func test_anthropic_backend_cancels_and_idles() {
        XCTAssertEqual(
            ConfigRefreshCoordinator.prefetchDecision(backend: "anthropic", modelId: "anything"),
            .cancelAndIdle
        )
    }

    func test_unknown_backend_cancels_and_idles() {
        XCTAssertEqual(
            ConfigRefreshCoordinator.prefetchDecision(backend: "", modelId: "x"),
            .cancelAndIdle
        )
    }

    func test_local_backend_with_model_ensures() {
        XCTAssertEqual(
            ConfigRefreshCoordinator.prefetchDecision(backend: "local", modelId: "mlx/qwen"),
            .ensure(modelId: "mlx/qwen")
        )
    }

    func test_auto_backend_with_model_ensures() {
        XCTAssertEqual(
            ConfigRefreshCoordinator.prefetchDecision(backend: "auto", modelId: "mlx/qwen"),
            .ensure(modelId: "mlx/qwen")
        )
    }

    func test_local_backend_without_model_is_noop() {
        XCTAssertEqual(
            ConfigRefreshCoordinator.prefetchDecision(backend: "local", modelId: ""),
            .noop
        )
    }

    func test_auto_backend_without_model_is_noop() {
        XCTAssertEqual(
            ConfigRefreshCoordinator.prefetchDecision(backend: "auto", modelId: ""),
            .noop
        )
    }

    // MARK: - start() wiring

    func test_start_without_config_store_seeds_regulated_false_and_no_model_state() {
        var regulatedFlags: [Bool] = []
        var modelStates: [ModelDownloadSupervisor.State] = []
        let coord = ConfigRefreshCoordinator(
            configStore: nil,
            onModelDownloadState: { modelStates.append($0) },
            onRegulatedMode: { regulatedFlags.append($0) }
        )

        coord.start()

        // With no ConfigStore the prefetch path returns early, so no
        // model-download state is forced, but the regulated glyph is still
        // seeded to its default (off).
        XCTAssertEqual(regulatedFlags, [false])
        XCTAssertTrue(modelStates.isEmpty)
    }

    // MARK: - UX21 local-model preflight

    func test_preflight_without_config_store_offers_nothing_and_is_safe() {
        // No ConfigStore means no configured model id: the affordance must not be
        // offered (isModelMissing == false), the label degrades to the generic
        // phrase, and startDownload is a harmless no-op rather than a crash.
        let coord = ConfigRefreshCoordinator(
            configStore: nil,
            onModelDownloadState: { _ in },
            onRegulatedMode: { _ in }
        )
        let preflight = coord.makeLocalModelPreflight()
        XCTAssertFalse(preflight.isModelMissing())
        XCTAssertEqual(preflight.downloadSizeLabel(), "several GB")
        preflight.startDownload()
    }
}
