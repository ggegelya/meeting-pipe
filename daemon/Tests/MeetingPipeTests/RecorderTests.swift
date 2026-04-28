import XCTest
@testable import MeetingPipe

final class RecorderTests: XCTestCase {
    private var fakeFFmpeg: URL!
    private var savedOverride: String?

    override func setUp() {
        super.setUp()
        savedOverride = ProcessInfo.processInfo.environment["MEETINGPIPE_FFMPEG"]
        // Drop a fake executable so findFFmpeg has something real to hit.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-ffmpeg-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fakeFFmpeg = dir.appendingPathComponent("ffmpeg")
        FileManager.default.createFile(
            atPath: fakeFFmpeg.path,
            contents: "#!/bin/sh\nexit 0\n".data(using: .utf8)
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeFFmpeg.path
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fakeFFmpeg.deletingLastPathComponent())
        if let saved = savedOverride {
            setenv("MEETINGPIPE_FFMPEG", saved, 1)
        } else {
            unsetenv("MEETINGPIPE_FFMPEG")
        }
        super.tearDown()
    }

    func testEnvOverrideWinsOverPathAndFallbacks() {
        setenv("MEETINGPIPE_FFMPEG", fakeFFmpeg.path, 1)
        XCTAssertEqual(Recorder.findFFmpeg(), fakeFFmpeg.path)
    }

    func testIgnoresOverrideWhenNotExecutable() {
        let nonExistent = "/tmp/no-such-ffmpeg-\(UUID().uuidString)"
        setenv("MEETINGPIPE_FFMPEG", nonExistent, 1)
        // Should fall through to PATH search (or fallbacks) rather than
        // returning the bogus path. Result is environment-dependent — we
        // just assert that we don't return the bogus override.
        XCTAssertNotEqual(Recorder.findFFmpeg(), nonExistent)
    }
}
