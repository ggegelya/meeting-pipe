import XCTest
@testable import MeetingPipe

/// T19: `runMP`'s two guards driven through a real spawn of a `/bin/sh` stand-in. `cloudSecretPolicy`
/// and `freshEnvironment` were unit-tested as pure functions, and the watchdog's
/// `LaunchError.timeout` was reached only by constructing the error by hand, so the lines in
/// `runMP` that join them could go with the suite green.
final class RunMPWiringT19Tests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-t19-runmp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", dir.appendingPathComponent("logs").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func script(_ body: String) throws -> URL {
        let url = dir.appendingPathComponent("fake-mp-\(UUID().uuidString).sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// An NDA meeting's spawn carries neither cloud token, whatever the global config says
    /// (`workflow_nda_mode` strips both), and keeps the rest of its environment.
    func test_anNDAMeetingsChildReceivesNoCloudToken() throws {
        let wav = dir.appendingPathComponent("20260101-120000.wav")
        try Data().write(to: wav)
        try #"{"workflow_nda_mode": true}"#.write(
            to: dir.appendingPathComponent("20260101-120000.meta.json"), atomically: true, encoding: .utf8
        )
        let envDump = dir.appendingPathComponent("env.txt")
        let fake = try script("env > \"\(envDump.path)\"\nexit 0\n")
        let launcher = PipelineLauncher(
            invocation: { .init(shell: "/bin/sh", args: [fake.path]) },
            environment: ["PATH": "/usr/bin:/bin", "MP_T19_BASE": "kept"],
            tokenSource: { ["ANTHROPIC_API_KEY": "sk-t19-anthropic", "NOTION_TOKEN": "ntn-t19-notion"] },
            reapOrphanedServer: {}
        )
        let done = expectation(description: "spawn finished")
        launcher.runAll(wav: wav) { _ in done.fulfill() }
        wait(for: [done], timeout: 20)

        let env = try String(contentsOf: envDump, encoding: .utf8)
        XCTAssertTrue(env.contains("MP_T19_BASE=kept"), "a non-secret base variable reaches the child")
        XCTAssertFalse(env.contains("sk-t19-anthropic"), "an NDA run must not hand the child the Anthropic key")
        XCTAssertFalse(env.contains("ntn-t19-notion"), "nor the Notion token")
    }

    /// A child that outlives `maxRuntime` is stopped, the run completes as `LaunchError.timeout`,
    /// and the orphaned-server reap runs.
    func test_aChildPastItsCeilingIsKilledAsATimeoutAndReaped() throws {
        let fake = try script("exec sleep 30\n")
        let reaped = expectation(description: "reap ran")
        let launcher = PipelineLauncher(
            maxRuntime: 1,
            invocation: { .init(shell: "/bin/sh", args: [fake.path]) },
            environment: ["PATH": "/usr/bin:/bin"],
            tokenSource: { [:] },
            reapOrphanedServer: { reaped.fulfill() }
        )
        let done = expectation(description: "spawn finished")
        var outcome: Result<URL?, Error>?
        launcher.runAll(wav: dir.appendingPathComponent("20260101-120000.wav")) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done, reaped], timeout: 20)

        guard case .failure(let error)? = outcome, case PipelineLauncher.LaunchError.timeout(let limit, _) = error else {
            return XCTFail("expected LaunchError.timeout, got \(String(describing: outcome))")
        }
        XCTAssertEqual(limit, 1)
    }
}
