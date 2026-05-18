import XCTest
@testable import MeetingPipe

/// Pure-logic gate for the `app_rebuild` event. The wrapper
/// `RebuildTagger.runOnce` reads `SecCodeCopySelf` + UserDefaults and
/// applies the side effects; tests exercise `decide` directly plus
/// `runOnce` with the cdhash reader and emitter injected.
final class RebuildTaggerTests: XCTestCase {

    func test_unreadable_when_current_is_nil() {
        XCTAssertEqual(RebuildTagger.decide(current: nil, previous: nil), .unreadable)
        XCTAssertEqual(RebuildTagger.decide(current: nil, previous: "abc"), .unreadable)
    }

    func test_first_launch_when_no_prior_hash() {
        XCTAssertEqual(
            RebuildTagger.decide(current: "abc", previous: nil),
            .firstLaunch(current: "abc")
        )
    }

    func test_no_change_when_hashes_match() {
        XCTAssertEqual(
            RebuildTagger.decide(current: "abc", previous: "abc"),
            .noChange
        )
    }

    func test_rebuild_when_hashes_differ() {
        XCTAssertEqual(
            RebuildTagger.decide(current: "abc", previous: "def"),
            .rebuild(prev: "def", current: "abc")
        )
    }

    // MARK: - runOnce side effects

    /// Isolated UserDefaults suite so a parallel run cannot collide.
    private func makeDefaults(_ label: String = #function) -> UserDefaults {
        let name = "RebuildTaggerTests.\(label).\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name)!
    }

    func test_runOnce_first_launch_persists_hash_and_does_not_emit() {
        let defaults = makeDefaults()
        var emitted: [(String, [String: Any])] = []
        RebuildTagger.runOnce(
            defaults: defaults,
            readCDHash: { "hash-v1" },
            emit: { action, attrs in emitted.append((action, attrs)) }
        )
        XCTAssertEqual(defaults.string(forKey: RebuildTagger.defaultsKey), "hash-v1")
        XCTAssertTrue(emitted.isEmpty)
    }

    func test_runOnce_same_hash_twice_emits_nothing() {
        let defaults = makeDefaults()
        defaults.set("hash-v1", forKey: RebuildTagger.defaultsKey)
        var emitted: [(String, [String: Any])] = []
        RebuildTagger.runOnce(
            defaults: defaults,
            readCDHash: { "hash-v1" },
            emit: { action, attrs in emitted.append((action, attrs)) }
        )
        XCTAssertTrue(emitted.isEmpty)
        XCTAssertEqual(defaults.string(forKey: RebuildTagger.defaultsKey), "hash-v1")
    }

    func test_runOnce_changed_hash_emits_app_rebuild_with_both_hashes() {
        let defaults = makeDefaults()
        defaults.set("hash-v1", forKey: RebuildTagger.defaultsKey)
        var emitted: [(String, [String: Any])] = []
        RebuildTagger.runOnce(
            defaults: defaults,
            readCDHash: { "hash-v2" },
            emit: { action, attrs in emitted.append((action, attrs)) }
        )
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted.first?.0, "app_rebuild")
        let attrs = emitted.first?.1 ?? [:]
        XCTAssertEqual(attrs["prev_cdhash"] as? String, "hash-v1")
        XCTAssertEqual(attrs["new_cdhash"] as? String, "hash-v2")
        XCTAssertEqual(defaults.string(forKey: RebuildTagger.defaultsKey), "hash-v2")
    }

    func test_runOnce_unreadable_hash_leaves_stored_value_alone() {
        let defaults = makeDefaults()
        defaults.set("hash-v1", forKey: RebuildTagger.defaultsKey)
        var emitted: [(String, [String: Any])] = []
        RebuildTagger.runOnce(
            defaults: defaults,
            readCDHash: { nil },
            emit: { action, attrs in emitted.append((action, attrs)) }
        )
        XCTAssertTrue(emitted.isEmpty)
        XCTAssertEqual(defaults.string(forKey: RebuildTagger.defaultsKey), "hash-v1")
    }
}
