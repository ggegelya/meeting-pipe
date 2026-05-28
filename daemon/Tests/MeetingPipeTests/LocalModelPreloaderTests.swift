import XCTest
@testable import MeetingPipe

/// The launch-time local-model warm (TECH-A15) is gated by a pure decision so
/// the side-effecting spawn never runs unless every condition holds.
final class LocalModelPreloaderTests: XCTestCase {

    func test_shouldPreload_requires_opt_in_local_backend_and_cached_model() {
        XCTAssertTrue(
            LocalModelPreloader.shouldPreload(enabled: true, backend: "local", modelCached: true)
        )
    }

    func test_shouldPreload_false_when_opted_out() {
        XCTAssertFalse(
            LocalModelPreloader.shouldPreload(enabled: false, backend: "local", modelCached: true)
        )
    }

    func test_shouldPreload_false_for_non_local_backends() {
        // `auto` may answer the first summary via Anthropic; `anthropic` never
        // uses the local model. Warming it in either case wastes RAM.
        XCTAssertFalse(
            LocalModelPreloader.shouldPreload(enabled: true, backend: "auto", modelCached: true)
        )
        XCTAssertFalse(
            LocalModelPreloader.shouldPreload(enabled: true, backend: "anthropic", modelCached: true)
        )
    }

    func test_shouldPreload_false_when_model_not_cached() {
        // Starting the server before the model is downloaded would block on (or
        // trigger) a multi-GB download at launch; that stays with ModelDownloadSupervisor.
        XCTAssertFalse(
            LocalModelPreloader.shouldPreload(enabled: true, backend: "local", modelCached: false)
        )
    }
}
