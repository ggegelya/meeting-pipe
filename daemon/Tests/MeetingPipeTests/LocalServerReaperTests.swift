import XCTest
@testable import MeetingPipe

/// LOCAL10. The reap decision is two pure predicates over a `ps` command line plus
/// a marker decode, so nothing here starts a process or signals one. The rules must
/// stay identical to `mp.local_server`'s: the daemon and `mp doctor` read the same
/// marker, and a disagreement means one of them lies about the same server.
final class LocalServerReaperTests: XCTestCase {

    private func markerData(
        pid: Any? = 4242,
        ownerPID: Any? = 1111,
        model: String? = "mlx-community/Qwen2.5-7B-Instruct-4bit",
        port: Int? = 8765
    ) -> Data {
        var obj: [String: Any] = ["schema_version": 1, "spawned_at": 1_770_000_000.0]
        if let pid { obj["pid"] = pid }
        if let ownerPID { obj["owner_pid"] = ownerPID }
        if let model { obj["model"] = model }
        if let port { obj["port"] = port }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: - Marker decode

    func testParsesAWellFormedMarker() {
        let marker = LocalServerReaper.parseMarker(markerData())
        XCTAssertEqual(marker, LocalServerReaper.Marker(
            pid: 4242,
            ownerPID: 1111,
            model: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            port: 8765
        ))
    }

    func testMarkerWithoutPidsIsUnusable() {
        XCTAssertNil(LocalServerReaper.parseMarker(markerData(pid: nil)))
        XCTAssertNil(LocalServerReaper.parseMarker(markerData(ownerPID: nil)))
    }

    func testMarkerWithNonIntegerPidIsUnusable() {
        XCTAssertNil(LocalServerReaper.parseMarker(markerData(pid: "nope")))
    }

    func testMalformedJSONIsNilNotACrash() {
        XCTAssertNil(LocalServerReaper.parseMarker(Data("{not json".utf8)))
        XCTAssertNil(LocalServerReaper.parseMarker(Data()))
    }

    func testOptionalFieldsFallBackWithoutFailingTheDecode() {
        // The pid pair is what we act on; a marker missing cosmetics is still actionable.
        let marker = LocalServerReaper.parseMarker(markerData(model: nil, port: nil))
        XCTAssertEqual(marker?.model, "unknown")
        XCTAssertEqual(marker?.port, 0)
    }

    // MARK: - Server identity (what we are allowed to kill)

    func testRecognisesTheServerByCommand() {
        XCTAssertTrue(LocalServerReaper.isServerCommand(
            "/opt/homebrew/bin/mlx_lm.server --model mlx-community/Qwen2.5-7B-Instruct-4bit"
        ))
        XCTAssertTrue(LocalServerReaper.isServerCommand(
            "/usr/bin/python3 -m mlx_lm.server --host 127.0.0.1 --port 8765"
        ))
    }

    func testARecycledPidIsNeverTakenForTheServer() {
        // The load-bearing case: pid 4242 died and the OS handed the number to Safari.
        // Killing it because the marker still names 4242 would be a real bug.
        XCTAssertFalse(LocalServerReaper.isServerCommand("/Applications/Safari.app/Contents/MacOS/Safari"))
        XCTAssertFalse(LocalServerReaper.isServerCommand(nil))
        XCTAssertFalse(LocalServerReaper.isServerCommand(""))
    }

    // MARK: - Owner identity (whether the server is still someone's)

    // PIPE22: the same two lists `test_local_server.py` pins (`OWNER_COMMANDS`,
    // `NOT_OWNER_COMMANDS`). The rule used to be "contains `mp` or `python`", which
    // every rejected line below satisfied, so a recycled owner pid could shield an
    // orphan forever. A console script shows up in `ps` as its interpreter followed
    // by the script path, which is why the accepted forms all start with a Python.
    static let ownerCommands = [
        "python3 -m mp run-all x.wav",
        "/path/.venv/bin/python /path/.venv/bin/mp ask q",
        "/usr/bin/python3 -m mp run-all /tmp/x.wav",
        "/Applications/MeetingPipe.app/Contents/Resources/python/bin/python3 -m mp ask q",
        "/Users/x/My Documents/meeting-pipe/pipeline/.venv/bin/python3 "
            + "/Users/x/My Documents/meeting-pipe/pipeline/.venv/bin/mp run-all /tmp/x.wav",
    ]
    static let notOwnerCommands = [
        "/usr/bin/sample 123",
        "/bin/sh /tmp/x.sh",
        "/usr/sbin/cupsd -l",
        "/usr/bin/python3 /tmp/unrelated.py",
        "/usr/bin/python3 -m pytest tests",
        "/bin/sh /path/bin/mp run-all x.wav",
        "",
    ]

    func testALiveMpProcessCountsAsTheOwner() {
        for command in Self.ownerCommands {
            XCTAssertTrue(LocalServerReaper.isOwnerCommand(command), command)
        }
    }

    func testADeadOrRecycledOwnerDoesNotShieldTheServer() {
        XCTAssertFalse(LocalServerReaper.isOwnerCommand(nil))     // owner pid is gone
        for command in Self.notOwnerCommands {
            XCTAssertFalse(LocalServerReaper.isOwnerCommand(command), command)  // pid reused
        }
    }

    // MARK: - The daemon's own server is never a marker

    func testMarkerURLSitsBesideTheLogs() {
        // The filename is the Swift-to-Python contract; the directory is whatever
        // `Log.logsDir` resolves to (redirected to a temp dir under XCTest, which is
        // why this asserts the relationship and not an absolute path).
        // `mp serve-local` writes no marker: the daemon owns its lifetime through a
        // child handle. Only `LocalSummaryClient._spawn` registers here.
        XCTAssertEqual(LocalServerReaper.markerURL.lastPathComponent, "mlx-server.json")
        XCTAssertEqual(
            LocalServerReaper.markerURL.deletingLastPathComponent().standardizedFileURL,
            Log.logsDir.standardizedFileURL
        )
    }
}
