import os
import XCTest
@testable import MeetingPipe

/// REC20 item 3: the `transcription_memory` rows. No model is loaded and nothing reaches the real
/// event log: the reader is scripted and the sink is an array.
final class TranscriptionMemoryProbeTests: XCTestCase {

    func test_a_job_row_carries_start_sampled_peak_end_and_fraction() throws {
        let script = OSAllocatedUnfairLock<[UInt64]>(initialState: [100, 700, 300, 200])
        var rows: [(String, [String: Any])] = []
        let probe = TranscriptionMemoryProbe(
            read: {
                script.withLock { queue -> TranscriptionMemoryProbe.Reading? in
                    guard !queue.isEmpty else { return nil }
                    return .init(footprint: queue.removeFirst(), lifetimePeak: 9_000)
                }
            },
            emit: { rows.append(($0, $1)) },
            idleDelaySeconds: nil,
            physicalMemory: 1_000,
            startsSampler: false
        )
        probe.sample()   // 700
        probe.sample()   // 300
        let attributes = try XCTUnwrap(probe.finish(audioSec: 7_200.04))   // end 200

        XCTAssertEqual(rows.map(\.0), ["transcription_memory"])
        XCTAssertEqual(attributes["phase"] as? String, "job")
        XCTAssertEqual(attributes["footprint_start_bytes"] as? UInt64, 100)
        XCTAssertEqual(attributes["footprint_peak_bytes"] as? UInt64, 700)
        XCTAssertEqual(attributes["footprint_end_bytes"] as? UInt64, 200)
        XCTAssertEqual(attributes["lifetime_peak_bytes"] as? UInt64, 9_000)
        XCTAssertEqual(attributes["peak_fraction"] as? Double, 0.7)
        XCTAssertEqual(attributes["audio_sec"] as? Double, 7_200.0)
        XCTAssertNil(probe.finish(audioSec: 1), "once per probe")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(attributes["abandoned"] as? Bool, false)
    }

    /// PIPE36: a pass the job deadline gave up on is finished at the deadline, marked, and its
    /// late return (if one ever comes, from another thread) emits nothing more, so its row
    /// never takes in the next job's footprint.
    func test_an_abandoned_pass_is_finished_once_at_the_deadline_and_its_late_return_is_dropped() throws {
        let rows = OSAllocatedUnfairLock<[[String: Any]]>(uncheckedState: [])
        let probe = TranscriptionMemoryProbe(
            read: { .init(footprint: 500, lifetimePeak: 600) },
            emit: { _, attributes in rows.withLockUnchecked { $0.append(attributes) } },
            idleDelaySeconds: nil,
            physicalMemory: 1_000,
            startsSampler: false
        )
        let atDeadline = try XCTUnwrap(probe.finish(audioSec: 60, abandoned: true))
        XCTAssertEqual(atDeadline["abandoned"] as? Bool, true)

        let late = expectation(description: "the late return ran")
        DispatchQueue.global().async {
            XCTAssertNil(probe.finish(audioSec: 60), "the pass's own defer finds it finished")
            late.fulfill()
        }
        wait(for: [late], timeout: 2)
        XCTAssertEqual(rows.withLockUnchecked { $0.count }, 1)
    }

    func test_the_idle_reading_follows_the_last_job_only() {
        let fired = expectation(description: "idle row")
        let rows = OSAllocatedUnfairLock<[String]>(initialState: [])
        let footprints = OSAllocatedUnfairLock<[UInt64]>(initialState: [])
        let read: @Sendable () -> TranscriptionMemoryProbe.Reading? = { .init(footprint: 42, lifetimePeak: 50) }
        let first = TranscriptionMemoryProbe(
            read: read,
            emit: { _, a in rows.withLock { $0.append(a["phase"] as? String ?? "?") } },
            idleDelaySeconds: 0.2, physicalMemory: 100, startsSampler: false
        )
        first.finish(audioSec: 1)
        // A second job starting cancels the first job's pending idle reading.
        let second = TranscriptionMemoryProbe(
            read: read,
            emit: { _, a in
                let phase = a["phase"] as? String ?? "?"
                rows.withLock { $0.append(phase) }
                if phase == "idle" {
                    footprints.withLock { $0.append(a["footprint_bytes"] as? UInt64 ?? 0) }
                    fired.fulfill()
                }
            },
            idleDelaySeconds: 0.3, physicalMemory: 100, startsSampler: false
        )
        second.finish(audioSec: 2)
        wait(for: [fired], timeout: 3)
        // Long enough for the cancelled first reading to have fired, had it not been cancelled.
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(rows.withLock { $0 }, ["job", "job", "idle"])
        XCTAssertEqual(footprints.withLock { $0 }, [42])
    }

    func test_the_process_footprint_is_readable() throws {
        let reading = try XCTUnwrap(TranscriptionMemoryProbe.currentReading())
        XCTAssertGreaterThan(reading.footprint, 0)
        XCTAssertGreaterThanOrEqual(reading.lifetimePeak, reading.footprint)
    }

    /// The probe only measures if the runner opens one per job and closes it on every exit.
    func test_the_runner_brackets_every_job_with_a_probe() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runner = try String(
            contentsOf: root.appendingPathComponent("Sources/MeetingPipe/Transcription/FluidAudioRunner.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(runner.contains(
            "let memory = TranscriptionMemoryProbe()\n        var audioSec: Double?\n"
                + "        inFlight.withLockUnchecked { $0 = InFlightPass(probe: memory) }\n"
                + "        defer {\n            memory.finish(audioSec: audioSec)\n"
        ))
        // PIPE36: and a pass the job deadline abandons is closed at the deadline, marked.
        XCTAssertTrue(runner.contains("pass.probe.finish(audioSec: pass.audioSec, abandoned: true)"))
    }
}
