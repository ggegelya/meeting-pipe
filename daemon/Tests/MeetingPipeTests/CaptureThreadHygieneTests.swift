import XCTest
@testable import MeetingPipe

/// CONC6 (F166, F157): the recorder's level callbacks are swapped on main while the capture threads read
/// them, and the "first fired" lines no longer block the first buffer on the log's append lock.
final class CaptureThreadHygieneTests: XCTestCase {

    func test_arming_and_disarming_the_level_callbacks_while_a_capture_thread_reads_them_is_clean() {
        let recorder = MeetingRecorder()
        let reads = ThreadSafeCounter()
        let stop = LockedBoolBox()
        let reader = expectation(description: "reader done")
        DispatchQueue.global().async {
            // What the mic tap and the SCStream queue do per emit: read the callback once.
            while !stop.value {
                if let cb = recorder.onMicLevel { cb(-30); reads.increment() }
                if let cb = recorder.onSystemLevel { cb(-30); reads.increment() }
            }
            reader.fulfill()
        }
        for _ in 0..<5000 {
            recorder.onMicLevel = { _ in }
            recorder.onSystemLevel = { _ in }
            recorder.onMicLevel = nil
            recorder.onSystemLevel = nil
        }
        recorder.onMicLevel = { _ in }
        recorder.onSystemLevel = { _ in }
        Thread.sleep(forTimeInterval: 0.05)
        stop.set(true)
        wait(for: [reader], timeout: 10)
        XCTAssertGreaterThan(reads.value, 0)
    }

    func test_an_async_log_line_reaches_the_file_with_its_text_unchanged() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("conc6-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        setenv("MEETINGPIPE_LOGS_DIR", dir.path, 1)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }

        Log.writeLineAsync("recorder", "mic tap first fired: frames=480")
        Log.drainAsyncWrites()

        let text = try String(contentsOf: dir.appendingPathComponent("recorder.log"), encoding: .utf8)
        XCTAssertTrue(text.contains("mic tap first fired: frames=480\n"), text)
    }

    /// No synchronous `Log.writeLine` for the first-buffer lines inside the mic tap or the system buffer closure.
    func test_the_first_fired_lines_are_not_written_synchronously_on_the_capture_threads() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe")
        var found = 0
        for file in ["MeetingRecorder.swift", "SystemAudioChannel.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for line in text.components(separatedBy: "\n") where line.contains("tap first fired") {
                found += 1
                XCTAssertFalse(line.contains("Log.writeLine("), "\(file): \(line)")
                XCTAssertTrue(line.contains("Log.writeLineAsync("), "\(file): \(line)")
            }
        }
        XCTAssertEqual(found, 2, "expected one mic and one system first-fired line")
    }
}

final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func increment() { lock.lock(); _value += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
}
