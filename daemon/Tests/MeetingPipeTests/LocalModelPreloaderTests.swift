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

    // MARK: - LOCAL11: restart on a config change
    //
    // The warm server pins one model + adapter for the daemon's lifetime, so
    // without this a Preferences flip left the old weights answering every
    // summary until the app was quit. `mp` deliberately will not kill a server it
    // did not spawn, which makes this the fix for the daemon-owned one.

    private func identity(
        _ model: String, adapter: String = "", backend: String = "local"
    ) -> LocalModelPreloader.Identity {
        LocalModelPreloader.Identity(backend: backend, model: model, adapterPath: adapter)
    }

    func test_decide_noop_when_nothing_runs_and_nothing_is_wanted() {
        XCTAssertEqual(LocalModelPreloader.decide(running: nil, desired: nil), .noop)
    }

    func test_decide_noop_when_the_identity_is_unchanged() {
        // The common case: a Preferences save that touched some unrelated key.
        // Reloading a multi-GB model for that would be a visible stall.
        XCTAssertEqual(
            LocalModelPreloader.decide(running: identity("a/b"), desired: identity("a/b")),
            .noop
        )
    }

    func test_decide_restarts_on_a_model_change() {
        XCTAssertEqual(
            LocalModelPreloader.decide(running: identity("a/b"), desired: identity("c/d")),
            .restart
        )
    }

    func test_decide_restarts_on_an_adapter_change_alone() {
        // Same model, adapter opted into (LOCAL9). Without this the A/B would
        // compare the base model against itself and read as "no improvement".
        XCTAssertEqual(
            LocalModelPreloader.decide(
                running: identity("a/b"),
                desired: identity("a/b", adapter: "/adapters/lora")
            ),
            .restart
        )
    }

    func test_decide_stops_when_the_backend_leaves_local() {
        // Switching to anthropic should free the resident model, not keep it warm.
        XCTAssertEqual(LocalModelPreloader.decide(running: identity("a/b"), desired: nil), .stop)
    }

    func test_decide_starts_when_gating_begins_to_pass() {
        // e.g. the model finished downloading, or the user just opted in.
        XCTAssertEqual(LocalModelPreloader.decide(running: nil, desired: identity("a/b")), .start)
    }
}
