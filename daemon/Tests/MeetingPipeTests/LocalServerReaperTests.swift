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

    func testALiveMpProcessCountsAsTheOwner() {
        XCTAssertTrue(LocalServerReaper.isOwnerCommand("/usr/bin/python3 -m mp run-all /tmp/x.wav"))
        XCTAssertTrue(LocalServerReaper.isOwnerCommand("/Users/x/.local/bin/mp summarize /tmp/x.md"))
    }

    func testADeadOrRecycledOwnerDoesNotShieldTheServer() {
        XCTAssertFalse(LocalServerReaper.isOwnerCommand(nil))     // owner pid is gone
        XCTAssertFalse(LocalServerReaper.isOwnerCommand("/usr/sbin/cupsd -l"))  // pid reused
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
