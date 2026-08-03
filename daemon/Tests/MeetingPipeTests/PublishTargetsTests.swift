import XCTest
@testable import MeetingPipe

/// UX45: the enabled-but-unconfigured derivation.
///
/// The whole point of the type is the case where a workflow's sink checkbox is
/// on and the destination it needs was never set, which is exactly the case a
/// view cannot be asked about. Two axes, both tabled: whether the sink is
/// enabled, and whether its path is set.
final class PublishTargetsTests: XCTestCase {

    private let configured = PublishTargets(
        obsidianVaultPath: "~/Documents/Obsidian/Personal",
        filesystemOutputDir: "~/Documents/Meetings/published",
        lanMountPath: "/Volumes/meetings"
    )

    private let empty = PublishTargets()

    // MARK: - The caption table

    func test_enabled_and_unconfigured_shows_a_caption_for_every_target() {
        for target in PublishTarget.allCases {
            let caption = empty.caption(for: target, enabled: true)
            XCTAssertNotNil(caption, "\(target.rawValue) enabled with no destination must say so")
            XCTAssertTrue(
                caption?.contains("Preferences > Integrations") ?? false,
                "\(target.rawValue)'s caption must name where to fix it"
            )
        }
    }

    func test_enabled_and_configured_shows_nothing() {
        for target in PublishTarget.allCases {
            XCTAssertNil(configured.caption(for: target, enabled: true), target.rawValue)
        }
    }

    func test_disabled_shows_nothing_however_unconfigured() {
        for target in PublishTarget.allCases {
            XCTAssertNil(empty.caption(for: target, enabled: false), target.rawValue)
            XCTAssertNil(configured.caption(for: target, enabled: false), target.rawValue)
        }
    }

    /// One target being unset must not implicate the other two. The Obsidian
    /// vault is the one with an empty default, so this is the realistic mix.
    func test_captions_are_per_target_not_all_or_nothing() {
        let onlyObsidianMissing = PublishTargets(
            obsidianVaultPath: "",
            filesystemOutputDir: "~/Documents/Meetings/published",
            lanMountPath: "/Volumes/meetings"
        )
        XCTAssertNotNil(onlyObsidianMissing.caption(for: .obsidian, enabled: true))
        XCTAssertNil(onlyObsidianMissing.caption(for: .filesystem, enabled: true))
        XCTAssertNil(onlyObsidianMissing.caption(for: .lan, enabled: true))
    }

    /// A path of spaces is a path nobody set. Trimming here rather than at each
    /// call site is why `isConfigured` exists at all.
    func test_whitespace_only_path_counts_as_unconfigured() {
        let blank = PublishTargets(obsidianVaultPath: "   \n ")
        XCTAssertFalse(blank.isConfigured(.obsidian))
        XCTAssertNotNil(blank.caption(for: .obsidian, enabled: true))
    }

    // MARK: - The Integrations status hint

    func test_missing_setting_hint_names_the_setting_and_clears_once_set() {
        for target in PublishTarget.allCases {
            XCTAssertNotNil(empty.missingSettingHint(for: target), target.rawValue)
            XCTAssertNil(configured.missingSettingHint(for: target), target.rawValue)
        }
    }

    // MARK: - Vocabulary

    /// The target names ARE the sink names. If they ever diverge, a Preferences
    /// group would configure a destination no sink writes to.
    func test_target_names_match_the_sink_vocabulary() {
        XCTAssertEqual(PublishTarget.obsidian.sinkTypeName, WorkflowSink.obsidian.typeName)
        XCTAssertEqual(PublishTarget.filesystem.sinkTypeName, WorkflowSink.filesystem.typeName)
        XCTAssertEqual(PublishTarget.lan.sinkTypeName, WorkflowSink.lan.typeName)
    }

    /// Notion configures itself per workflow (the database rides on the case), so
    /// it deliberately maps to no global target; the other three all do.
    func test_only_notion_has_no_global_publish_target() {
        XCTAssertNil(WorkflowSink.notion(databaseId: "abc").publishTarget)
        XCTAssertEqual(WorkflowSink.obsidian.publishTarget, .obsidian)
        XCTAssertEqual(WorkflowSink.filesystem.publishTarget, .filesystem)
        XCTAssertEqual(WorkflowSink.lan.publishTarget, .lan)
    }
}
