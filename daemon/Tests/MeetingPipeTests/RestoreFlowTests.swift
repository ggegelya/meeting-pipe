import XCTest
@testable import MeetingPipe

/// STOR5: the in-app restore, which is the most destructive button in the app.
///
/// Three things are pinned here, and each of them is a way the feature could be
/// wrong without looking wrong: the plan Swift decodes is the one `mp restore
/// --dry-run --json` writes, the confirm copy tells the truth about what gets
/// overwritten, and the real run is unreachable except through a shown plan.
@MainActor
final class RestoreFlowTests: XCTestCase {

    /// Records what the flow asked for and parks each completion, so a test
    /// decides when (and whether) an invocation lands.
    private final class FakeDriver: PipelineDriver {
        private(set) var previewed: [URL] = []
        private(set) var restored: [URL] = []
        private var previewCompletion: ((Result<RestorePlan, Error>) -> Void)?
        private var restoreCompletion: ((Result<Void, Error>) -> Void)?

        func runAll(wav: URL, summaryMode: SummaryMode, completion: @escaping (Result<URL?, Error>) -> Void) {}

        func restorePreview(archive: URL, completion: @escaping (Result<RestorePlan, Error>) -> Void) {
            previewed.append(archive)
            previewCompletion = completion
        }

        func restore(archive: URL, completion: @escaping (Result<Void, Error>) -> Void) {
            restored.append(archive)
            restoreCompletion = completion
        }

        func landPreview(_ plan: RestorePlan) { previewCompletion?(.success(plan)) }
        func failPreview(_ message: String) {
            previewCompletion?(.failure(NSError(
                domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: message]
            )))
        }
        func landRestore() { restoreCompletion?(.success(())) }
        func failRestore(_ message: String) {
            restoreCompletion?(.failure(NSError(
                domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: message]
            )))
        }
    }

    /// The flow hops to the main actor to publish each phase, so a test has to
    /// let those hops run before reading one.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    // MARK: - The payload contract

    /// Verbatim `mp.restore.plan_restore` output (paths shortened), produced by
    /// running the real writer over a two-file backup restored onto a Mac that
    /// already has one of the two files and its own config.toml. If this stops
    /// decoding, the Python writer moved and the preview is about to render an
    /// empty plan.
    private static let planJSON = #"""
    {
      "archive": "/Users/x/Backups/meeting-pipe-backup-20260803-105419.tar.gz",
      "created_at": "2026-08-03T10:54:19.738612+00:00",
      "audio_included": true,
      "keeps_config_toml": true,
      "total_files": 3,
      "added": 2,
      "replaced": 1,
      "roots": [
        {
          "name": "library",
          "prefix": "library",
          "destination": "/Users/x/Meetings/raw",
          "files": 2,
          "added": 1,
          "replaced": 1,
          "occupied": true
        },
        {
          "name": "digests",
          "prefix": "digests",
          "destination": "/Users/x/Meetings/digests",
          "files": 0,
          "added": 0,
          "replaced": 0,
          "occupied": false
        },
        {
          "name": "config",
          "prefix": "config",
          "destination": "/Users/x/.config/meeting-pipe",
          "files": 1,
          "added": 1,
          "replaced": 0,
          "occupied": false
        },
        {
          "name": "corrections",
          "prefix": "corrections",
          "destination": "/Users/x/Library/Application Support/MeetingPipe/corrections",
          "files": 0,
          "added": 0,
          "replaced": 0,
          "occupied": false
        }
      ],
      "added_sample": [
        "library/20260801-1030.wav",
        "config/roster.json"
      ],
      "replaced_sample": [
        "library/20260801-1030.md"
      ]
    }
    """#

    private func fixturePlan() throws -> RestorePlan {
        try JSONDecoder().decode(RestorePlan.self, from: XCTUnwrap(Self.planJSON.data(using: .utf8)))
    }

    private func plan(
        totalFiles: Int = 10,
        added: Int = 4,
        replaced: Int = 6,
        roots: [RestorePlan.Root] = [],
        addedSample: [String] = [],
        replacedSample: [String] = [],
        audioIncluded: Bool = true,
        keepsConfigToml: Bool = false,
        archive: String = "/Users/x/Backups/meeting-pipe-backup-20260803-105419.tar.gz"
    ) -> RestorePlan {
        let decoded = try? fixturePlan()
        return RestorePlan(
            archive: archive,
            createdAt: decoded?.createdAt ?? "2026-08-03T10:54:19.738612+00:00",
            audioIncluded: audioIncluded,
            keepsConfigToml: keepsConfigToml,
            totalFiles: totalFiles,
            added: added,
            replaced: replaced,
            roots: roots.isEmpty ? (decoded?.roots ?? []) : roots,
            addedSample: addedSample,
            replacedSample: replacedSample
        )
    }

    func testPlanDecodesWhatTheDryRunWrites() throws {
        let plan = try fixturePlan()

        XCTAssertEqual(plan.totalFiles, 3)
        XCTAssertEqual(plan.added, 2)
        XCTAssertEqual(plan.replaced, 1)
        XCTAssertTrue(plan.audioIncluded)
        XCTAssertTrue(plan.keepsConfigToml)
        XCTAssertEqual(plan.archiveName, "meeting-pipe-backup-20260803-105419.tar.gz")
        XCTAssertEqual(plan.roots.map(\.name), ["library", "digests", "config", "corrections"])

        let library = try XCTUnwrap(plan.roots.first)
        XCTAssertEqual(library.destination, "/Users/x/Meetings/raw")
        XCTAssertEqual([library.files, library.added, library.replaced], [2, 1, 1])
        // Occupancy is its own question: this library holds other meetings.
        XCTAssertTrue(library.occupied)
        XCTAssertEqual(plan.addedSample.first, "library/20260801-1030.wav")
        XCTAssertEqual(plan.replacedSample, ["library/20260801-1030.md"])
    }

    func testAnUnreadablePlanIsNilRatherThanACrash() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-plan-\(UUID().uuidString).json")
        try #"{"archive": "/x"}"#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(RestorePlan.load(from: url))
        XCTAssertNil(RestorePlan.load(from: url.appendingPathExtension("missing")))
    }

    // MARK: - The confirm copy

    /// Big counts are grouped in the reader's own locale, so an expectation
    /// spelled `1,204` passes on this Mac and fails on a French one. Build the
    /// expected digits the same way the copy does, and pin the wording around it.
    private func grouped(_ n: Int) -> String { n.formatted(.number.grouping(.automatic)) }

    func testConfirmTitleNamesHowMuchLands() {
        XCTAssertEqual(RestorePreview.confirmTitle(for: plan(totalFiles: 1)), "Restore 1 file")
        XCTAssertEqual(RestorePreview.confirmTitle(for: plan(totalFiles: 2)), "Restore 2 files")
        XCTAssertEqual(
            RestorePreview.confirmTitle(for: plan(totalFiles: 1204)),
            "Restore \(grouped(1204)) files"
        )
    }

    func testMessageSaysHowManyFilesItOverwrites() {
        let message = RestorePreview.message(for: plan(totalFiles: 1204, added: 24, replaced: 1180))

        XCTAssertTrue(message.contains("This writes \(grouped(1204)) files into your"), message)
        XCTAssertTrue(message.contains("overwriting \(grouped(1180)) files already there"), message)
        // The other half of the truth: a restore is a merge, not a swap.
        XCTAssertTrue(message.contains("Files the backup does not carry are left alone."), message)

        // Recovering one deleted recording is the case this button exists for,
        // so the copy has to stay grammatical at one file.
        let single = RestorePreview.message(for: plan(totalFiles: 1, added: 0, replaced: 1))
        XCTAssertTrue(single.contains("This writes 1 file into your"), single)
        XCTAssertTrue(single.contains("overwriting 1 file already there"), single)
    }

    func testMessageSaysNothingIsTouchedWhenNothingIsReplaced() {
        let message = RestorePreview.message(for: plan(totalFiles: 12, added: 12, replaced: 0))

        XCTAssertTrue(message.contains("Nothing already on disk is touched."), message)
        XCTAssertFalse(message.contains("overwriting"), message)
    }

    func testMessageNamesTheFilesThatComeBack() {
        let message = RestorePreview.message(for: plan(
            totalFiles: 3, added: 3, replaced: 0,
            addedSample: ["library/20260801-1030.wav", "library/20260801-1030.md", "library/x.json"]
        ))

        XCTAssertTrue(message.contains("20260801-1030.wav and 20260801-1030.md"), message)
        // The archive prefix is an implementation detail; the root is named above.
        XCTAssertFalse(message.contains("library/"), message)
        XCTAssertTrue(message.contains("and 1 more"), message)
    }

    func testMessageNamesTheRootsThatActuallyReceiveFiles() throws {
        let message = RestorePreview.message(for: try fixturePlan())

        XCTAssertTrue(message.contains("library and config"), message)
        // Two of the four roots take nothing from this archive; naming them would
        // be padding the blast radius with folders nothing is written into.
        XCTAssertFalse(message.contains("digests"), message)
        XCTAssertFalse(message.contains("corrections"), message)
    }

    func testMessageWarnsThatASidecarOnlyBackupHasNoAudio() {
        XCTAssertTrue(
            RestorePreview.message(for: plan(audioIncluded: false))
                .contains("carries no recordings"))
        XCTAssertFalse(
            RestorePreview.message(for: plan(audioIncluded: true))
                .contains("carries no recordings"))
    }

    func testMessageSaysTheLibraryStaysWhereItIsWhenConfigIsKept() {
        let kept = RestorePreview.message(for: plan(keepsConfigToml: true))
        XCTAssertTrue(kept.contains("config.toml is kept"), kept)
        // The corollary the owner has to know: everything else under config is not.
        XCTAssertTrue(kept.contains("Workflows, roster, and vocabulary are replaced"), kept)
        XCTAssertFalse(RestorePreview.message(for: plan(keepsConfigToml: false))
            .contains("config.toml is kept"))
    }

    func testMessageAlwaysEndsWithTheIrreversibility() {
        let cases = [plan(replaced: 0), plan(replaced: 900), plan(audioIncluded: false)]
        for candidate in cases {
            XCTAssertTrue(RestorePreview.message(for: candidate).hasSuffix("There is no undo."))
        }
    }

    func testTakenRendersPythonsMicrosecondTimestamp() {
        // `ISO8601DateFormatter`'s fractional mode wants milliseconds and Python
        // writes microseconds, so a naive parse renders the raw string at the
        // owner (which is how this was wrong for an afternoon).
        let rendered = RestorePreview.taken("2026-08-03T10:54:19.738612+00:00")
        XCTAssertNotEqual(rendered, "2026-08-03T10:54:19.738612+00:00")
        XCTAssertTrue(rendered.contains("2026"), rendered)

        XCTAssertEqual(RestorePreview.taken("not a date"), "not a date")
    }

    func testSummaryNamesTheArchiveItRestored() {
        XCTAssertEqual(
            RestorePreview.summary(for: plan(totalFiles: 1204)),
            "Restored \(grouped(1204)) files from meeting-pipe-backup-20260803-105419.tar.gz."
        )
    }

    // MARK: - The two invocations

    func testPreviewIsTheOnlyThingAPickedArchiveStarts() async throws {
        let driver = FakeDriver()
        let flow = RestoreFlow(launcher: driver)
        let archive = URL(fileURLWithPath: "/Users/x/Backups/b.tar.gz")

        flow.preview(archive: archive)
        XCTAssertEqual(flow.phase, .previewing)
        driver.landPreview(try fixturePlan())
        await settle()

        XCTAssertEqual(driver.previewed, [archive])
        XCTAssertEqual(driver.restored, [], "a picked archive must not restore anything by itself")
        XCTAssertEqual(flow.pendingPlan, try fixturePlan())
    }

    func testTheRealRunIsUnreachableWithoutAConfirmedPlan() async throws {
        let driver = FakeDriver()
        let flow = RestoreFlow(launcher: driver)

        // From idle: nothing to confirm, so nothing runs.
        flow.confirm()
        await settle()
        XCTAssertEqual(driver.restored, [])

        // Mid-preview: still nothing, the plan has not landed.
        flow.preview(archive: URL(fileURLWithPath: "/Users/x/Backups/b.tar.gz"))
        flow.confirm()
        await settle()
        XCTAssertEqual(driver.restored, [])

        driver.landPreview(try fixturePlan())
        await settle()
        flow.confirm()
        await settle()
        XCTAssertEqual(driver.restored.count, 1)
    }

    func testTheRealRunUsesTheArchiveThePlanDescribed() async throws {
        let driver = FakeDriver()
        let flow = RestoreFlow(launcher: driver)

        // The picker's URL and the plan's path are the same file, and taking it
        // from the plan is what makes that provable rather than assumed.
        flow.preview(archive: URL(fileURLWithPath: "/Users/x/Backups/b.tar.gz"))
        driver.landPreview(try fixturePlan())
        await settle()
        flow.confirm()
        await settle()

        XCTAssertEqual(driver.restored.map(\.path), [try fixturePlan().archive])
        XCTAssertEqual(flow.phase, .restoring(try fixturePlan()))
    }

    func testAFailedPreviewNeverReachesTheRealRun() async {
        let driver = FakeDriver()
        let flow = RestoreFlow(launcher: driver)

        flow.preview(archive: URL(fileURLWithPath: "/Users/x/Downloads/holiday.zip"))
        driver.failPreview("not a meeting-pipe backup")
        await settle()

        flow.confirm()
        await settle()
        XCTAssertEqual(driver.restored, [])
        XCTAssertTrue(flow.hasFailed)
        XCTAssertEqual(
            flow.footerText, "Could not read that backup: not a meeting-pipe backup"
        )
    }

    func testCancellingTheConfirmRestoresNothing() async throws {
        let driver = FakeDriver()
        let flow = RestoreFlow(launcher: driver)

        flow.preview(archive: URL(fileURLWithPath: "/Users/x/Backups/b.tar.gz"))
        driver.landPreview(try fixturePlan())
        await settle()
        flow.dismiss()

        XCTAssertEqual(flow.phase, .idle)
        XCTAssertNil(flow.pendingPlan)
        flow.confirm()
        await settle()
        XCTAssertEqual(driver.restored, [])
    }

    func testASecondPreviewIsRefusedWhileOneIsOut() async throws {
        let driver = FakeDriver()
        let flow = RestoreFlow(launcher: driver)

        flow.preview(archive: URL(fileURLWithPath: "/Users/x/Backups/a.tar.gz"))
        flow.preview(archive: URL(fileURLWithPath: "/Users/x/Backups/b.tar.gz"))
        await settle()

        XCTAssertEqual(driver.previewed.map(\.lastPathComponent), ["a.tar.gz"])
    }

    func testALandedRestoreReportsWhatItRestored() async throws {
        let driver = FakeDriver()
        let flow = RestoreFlow(launcher: driver)

        flow.preview(archive: URL(fileURLWithPath: "/Users/x/Backups/b.tar.gz"))
        driver.landPreview(try fixturePlan())
        await settle()
        flow.confirm()
        XCTAssertTrue(flow.isBusy, "a running restore has to block a backup")
        driver.landRestore()
        await settle()

        XCTAssertFalse(flow.isBusy)
        XCTAssertFalse(flow.hasFailed)
        XCTAssertEqual(
            flow.footerText,
            "Restored 3 files from meeting-pipe-backup-20260803-105419.tar.gz."
        )
    }

    func testAFailedRestoreSaysSoInTheFooter() async throws {
        let driver = FakeDriver()
        let flow = RestoreFlow(launcher: driver)

        flow.preview(archive: URL(fileURLWithPath: "/Users/x/Backups/b.tar.gz"))
        driver.landPreview(try fixturePlan())
        await settle()
        flow.confirm()
        driver.failRestore("pipeline exited 1: no space left on device")
        await settle()

        XCTAssertTrue(flow.hasFailed)
        XCTAssertEqual(
            flow.footerText, "Restore failed: pipeline exited 1: no space left on device"
        )
    }

    // MARK: - argv

    func testBothInvocationsSpellTheirArguments() {
        let archive = URL(fileURLWithPath: "/Users/x/Backups/b.tar.gz")
        let out = URL(fileURLWithPath: "/tmp/plan.json")

        XCTAssertEqual(
            PipelineLauncher.restorePreviewArgs(archive: archive, out: out),
            ["restore", "/Users/x/Backups/b.tar.gz", "--dry-run", "--json", "--out", "/tmp/plan.json"]
        )
        // `--force` is what makes an in-app restore possible at all: every
        // destination here is a live root, which a plain `mp restore` refuses.
        XCTAssertEqual(
            PipelineLauncher.restoreArgs(archive: archive),
            ["restore", "/Users/x/Backups/b.tar.gz", "--force"]
        )
        XCTAssertFalse(PipelineLauncher.restoreArgs(archive: archive).contains("--dry-run"))
    }

    // MARK: - The shared busy gate

    func testBackupAndRestoreAreMutuallyExclusive() {
        let idle = StorageBusyGate(
            backupRunning: false, restoreRunning: false, hasBackupDestination: true
        )
        XCTAssertTrue(idle.backupEnabled)
        XCTAssertTrue(idle.restoreEnabled)

        let backing = StorageBusyGate(
            backupRunning: true, restoreRunning: false, hasBackupDestination: true
        )
        XCTAssertFalse(backing.restoreEnabled, "a restore mid-backup rewrites what is being read")
        XCTAssertFalse(backing.backupEnabled)

        let restoring = StorageBusyGate(
            backupRunning: false, restoreRunning: true, hasBackupDestination: true
        )
        XCTAssertFalse(restoring.backupEnabled, "a backup mid-restore archives a half-restored library")
        XCTAssertFalse(restoring.restoreEnabled)
    }

    func testRestoreNeedsNoRememberedDestination() {
        // The one place the two differ: `mp backup` needs a folder to write into,
        // while a restore is handed its archive by the picker. Someone who has
        // never backed up from this app still has to be able to open an archive.
        let gate = StorageBusyGate(
            backupRunning: false, restoreRunning: false, hasBackupDestination: false
        )
        XCTAssertFalse(gate.backupEnabled)
        XCTAssertTrue(gate.restoreEnabled)
    }
}
