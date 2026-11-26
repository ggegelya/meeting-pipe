import AVFoundation
import XCTest
@testable import MeetingPipe

/// SEC22: the library's audio is owner-only from the moment it exists, and so are the folders
/// that hold it. Before this every recording landed `-rw-r--r--` in a `drwxr-xr-x` folder, and the
/// default library (`~/Meetings/raw`) sits outside `~/Documents`' 0700, so nothing else kept it
/// private. Each test sets the umask to the owner Mac's `022` so a 0600 is the code's doing, not
/// the test runner's.
final class OwnerOnlyFilesSEC22Tests: XCTestCase {

    private var dir: URL!
    private var savedUmask: mode_t = 0

    override func setUpWithError() throws {
        savedUmask = umask(0o022)
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-sec22-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        umask(savedUmask)
        try? FileManager.default.removeItem(at: dir)
    }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func test_the_mic_capture_file_is_created_owner_only() throws {
        let mic = dir.appendingPathComponent("20261126-100000.mic.wav")
        let file = try RecordStartFileWrite.makeMonoMicFile(at: mic, sampleRate: 48_000)
        XCTAssertEqual(try mode(mic), 0o600, "the mic capture is the owner's voice; 0644 is the umask default")
        // Still a writable capture file: the pre-create must not cost the recorder its format.
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 480))
        buffer.frameLength = 480
        try file.write(from: buffer)
        XCTAssertEqual(file.length, 480)
    }

    /// The system capture opens through the same call (`SystemAudioChannel.openSystemFile`).
    /// `forWriting` truncates, so an existing 0644 file from before SEC22 is tightened too.
    func test_an_audio_file_opened_for_writing_is_owner_only_even_over_an_older_file() throws {
        let system = dir.appendingPathComponent("20261126-100000.system.wav")
        FileManager.default.createFile(atPath: system.path, contents: Data("old".utf8),
                                       attributes: [.posixPermissions: 0o644])
        _ = try OwnerOnlyFiles.openAudioForWriting(at: system, settings: SystemAudioCapture.captureFormat.settings)
        XCTAssertEqual(try mode(system), 0o600)
    }

    func test_a_library_folder_and_every_folder_it_creates_on_the_way_are_owner_only() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        let raw = dir.appendingPathComponent("Meetings/raw", isDirectory: true)
        try OwnerOnlyFiles.createDirectory(at: raw)
        XCTAssertEqual(try mode(raw), 0o700)
        XCTAssertEqual(try mode(raw.deletingLastPathComponent()), 0o700, "~/Meetings is created on the way")
        XCTAssertEqual(try mode(dir), 0o755, "a folder that already existed is never touched")
    }

    func test_an_existing_library_folder_is_left_as_it_was_by_create() throws {
        let raw = dir.appendingPathComponent("raw", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try OwnerOnlyFiles.createDirectory(at: raw)
        XCTAssertEqual(try mode(raw), 0o755, "create only creates; the launch sweep is what tightens an old folder")
    }

    func test_restrict_tightens_a_file_to_owner_only() throws {
        let tmp = dir.appendingPathComponent("20261126-100000.merging.wav")
        FileManager.default.createFile(atPath: tmp.path, contents: Data("x".utf8),
                                       attributes: [.posixPermissions: 0o644])
        XCTAssertTrue(OwnerOnlyFiles.restrict(tmp))
        XCTAssertEqual(try mode(tmp), 0o600)
        XCTAssertFalse(OwnerOnlyFiles.restrict(dir.appendingPathComponent("missing.wav")))
    }

    /// Ratchet: a third capture file opened with a bare `AVAudioFile(forWriting:)` would land at
    /// the umask again, exactly how both capture files did before SEC22. Comments do not count.
    func test_no_source_opens_audio_for_writing_except_through_the_owner_only_helper() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(atPath: sources.path))
        var scanned = 0
        var offenders: [String] = []
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            scanned += 1
            let text = try String(contentsOf: sources.appendingPathComponent(relative), encoding: .utf8)
            let code = String(SwiftSourceScan.codeOnly(text))
            if code.contains("AVAudioFile(forWriting:"), relative != "MeetingPipe/OwnerOnlyFiles.swift" {
                offenders.append(relative)
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the walker must see the tree, or this passes on nothing")
        XCTAssertEqual(offenders, [], "open audio through OwnerOnlyFiles.openAudioForWriting (SEC22)")
    }
}
