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

    /// CONC13: reading the getter must not grow the stored closure. Before the fix every read wrapped
    /// it in two more reabstraction thunks, so the call's stack depth rose two frames per read and a
    /// 35-minute recording overflowed main. 10,000 reads would add ~20,000 frames.
    func test_reading_onMicLevel_many_times_does_not_deepen_its_call() {
        let recorder = MeetingRecorder()
        let depth = CallDepthBox()
        recorder.onMicLevel = { _ in depth.value = Thread.callStackSymbols.count }
        let (before, after) = Self.depthBeforeAndAfterReads(depth) { recorder.onMicLevel }
        XCTAssertEqual(after, before, "onMicLevel's call grew by \(after - before) frames over 10,000 reads")
    }

    func test_reading_onSystemLevel_many_times_does_not_deepen_its_call() {
        let recorder = MeetingRecorder()
        let depth = CallDepthBox()
        recorder.onSystemLevel = { _ in depth.value = Thread.callStackSymbols.count }
        let (before, after) = Self.depthBeforeAndAfterReads(depth) { recorder.onSystemLevel }
        XCTAssertEqual(after, before, "onSystemLevel's call grew by \(after - before) frames over 10,000 reads")
    }

    /// Invoke the callback once for a baseline, read the getter 10,000 times without reassigning
    /// (what the capture threads do per buffer), invoke it again from the same call site.
    private static func depthBeforeAndAfterReads(
        _ depth: CallDepthBox, read: () -> ((Float) -> Void)?
    ) -> (Int, Int) {
        func invoke() -> Int {
            read()?(-30)
            return depth.value
        }
        let before = invoke()
        for _ in 0..<10_000 { _ = read() }
        let after = invoke()
        return (before, after)
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

/// CONC13: the stack depth the level callback saw on its last call. Single-threaded use only.
final class CallDepthBox {
    var value = 0
}
