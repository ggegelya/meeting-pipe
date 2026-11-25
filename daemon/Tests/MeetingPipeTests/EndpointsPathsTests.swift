import XCTest
@testable import MeetingPipe

/// ARCH18: `Endpoints.Paths` is the one list of the app's on-disk folders. The file constants derive
/// from the folder constants, so these pin every one to its literal: a derivation that changes a
/// string moves a file the owner already has, and nothing else would notice.
final class EndpointsPathsTests: XCTestCase {

    func test_every_relative_path_keeps_its_literal() {
        typealias P = Endpoints.Paths
        XCTAssertEqual(P.configDirRelative, ".config/meeting-pipe")
        XCTAssertEqual(P.appSupportRelative, "Library/Application Support/MeetingPipe")
        XCTAssertEqual(P.cachesRelative, "Library/Caches/MeetingPipe")
        XCTAssertEqual(P.logsRelative, "Library/Logs/MeetingPipe")
        XCTAssertEqual(P.configRelative, ".config/meeting-pipe/config.toml")
        XCTAssertEqual(P.secretsRelative, ".config/meeting-pipe/secrets.env")
        XCTAssertEqual(P.voiceprintRelative, ".config/meeting-pipe/voiceprint.json")
        XCTAssertEqual(P.rosterRelative, ".config/meeting-pipe/roster.json")
        XCTAssertEqual(P.glossaryRelative, ".config/meeting-pipe/glossary.toml")
        XCTAssertEqual(P.lastBackupRelative, ".config/meeting-pipe/.last-backup.json")
        XCTAssertEqual(P.correctionsRelative, "Library/Application Support/MeetingPipe/corrections")
    }

    func test_the_folder_accessors_resolve_from_home() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(Endpoints.Paths.configDir.path, home + "/.config/meeting-pipe")
        XCTAssertEqual(Endpoints.Paths.appSupportDir.path, home + "/Library/Application Support/MeetingPipe")
        XCTAssertEqual(Endpoints.Paths.cachesDir.path, home + "/Library/Caches/MeetingPipe")
    }

    /// The migrated defaults land where they did before ARCH18. Only the side-effect-free ones:
    /// `WaveformPeaksLoader.cacheDirectory()` and `AutoRetryStore.init` create their folder.
    func test_the_migrated_defaults_keep_their_paths() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let config = home + "/.config/meeting-pipe"
        let support = home + "/Library/Application Support/MeetingPipe"
        let caches = home + "/Library/Caches/MeetingPipe"
        XCTAssertEqual(MeetingAppRegistry.defaultOverlayURL.path, config + "/meeting_apps.toml")
        XCTAssertEqual(WorkflowStore.defaultDirectory.path, config + "/workflows")
        XCTAssertEqual(WorkflowCorrectionStore.defaultURL.path, config + "/workflow_corrections.json")
        XCTAssertEqual(SavedSearchStore.defaultURL.path, config + "/saved_searches.json")
        XCTAssertEqual(LegacyConsentMigration.defaultURL.path, support + "/auto_consent.json")
        XCTAssertEqual(MuteRedactor.originalsDirectory().path, support + "/originals")
        XCTAssertEqual(NotionDatabaseList.defaultCacheURL.path, caches + "/notion-databases.json")
        XCTAssertEqual(SearchIndexer.defaultIndexURL().path, caches + "/search/index.sqlite")
        XCTAssertEqual(MeetingDurationCache.defaultURL().path, caches + "/durations.json")
        XCTAssertEqual(LaunchAgentScheduler.logDir, home + "/Library/Logs/MeetingPipe")
    }
}
