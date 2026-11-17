import XCTest
@testable import MeetingPipe

/// OBS10: the arithmetic on a job's wall and CPU time, and the rows built from it.
final class ResourceSampleTests: XCTestCase {

    func test_cpuShareAndRTF() {
        let sample = ResourceSample(wallMs: 20_000, cpuMs: 15_000)
        XCTAssertEqual(sample.cpuShare ?? .nan, 0.75, accuracy: 1e-9)
        XCTAssertEqual(sample.rtf(audioSeconds: 1_400) ?? .nan, 70, accuracy: 1e-9, "1,400 s of audio in 20 s")
    }

    func test_aZeroWallTime_hasNoShareAndNoRTF() {
        let sample = ResourceSample(wallMs: 0, cpuMs: 5)
        XCTAssertNil(sample.cpuShare)
        XCTAssertNil(sample.rtf(audioSeconds: 60))
        XCTAssertNil(sample.attributes["cpu_share"])
    }

    /// Multi-threaded ASR spends more CPU than wall time; the share reads above 1.0, not clamped.
    func test_cpuAboveWall_readsAboveOne() {
        let sample = ResourceSample(wallMs: 10_000, cpuMs: 38_000)
        XCTAssertEqual(sample.cpuShare ?? .nan, 3.8, accuracy: 1e-9)
        XCTAssertEqual(sample.attributes["cpu_share"] as? Double, 3.8)
    }

    func test_aSpan_measuresWallCPUAndSwitchDeltas_andBothMachineSnapshots() {
        var clock = 50.0, cpu = 200.0, switches = 10.0, hot = false
        let probe = ResourceProbe(
            selfCPUMs: { cpu }, childrenCPUMs: { 0 }, selfInvoluntarySwitches: { switches }, uptime: { clock },
            machine: { MachineState(thermalState: hot ? "serious" : "nominal", lowPower: false, memoryPressure: "normal") }
        )
        let span = probe.begin(cpu: probe.selfCPUMs, switches: probe.selfInvoluntarySwitches)
        clock += 2.5; cpu += 700; switches += 340; hot = true
        let (sample, atStart, atEnd) = span.finish()
        XCTAssertEqual(sample, ResourceSample(wallMs: 2_500, cpuMs: 700, involuntarySwitches: 340))
        XCTAssertEqual(sample.attributes["involuntary_switches"] as? Double, 340)
        XCTAssertEqual(atStart.thermalState, "nominal")
        XCTAssertEqual(atEnd.thermalState, "serious")
    }

    /// A merge's row carries the final's name and its kind, never a path.
    func test_mergeCompleted_namesTheFinalFile() {
        let attrs = RecordingPostProcessor.mergeCompletedAttributes(
            kind: "merge", file: URL(fileURLWithPath: "/tmp/20261117-180000.wav"), audioSeconds: 1_221,
            sample: ResourceSample(wallMs: 52_000, cpuMs: 9_000),
            atStart: MachineState(thermalState: "nominal", lowPower: false, memoryPressure: "normal"),
            atEnd: MachineState(thermalState: "fair", lowPower: false, memoryPressure: "warning")
        )
        XCTAssertEqual(attrs["file"] as? String, "20261117-180000.wav")
        XCTAssertEqual(attrs["kind"] as? String, "merge")
        XCTAssertEqual(attrs["wall_ms"] as? Double, 52_000)
        XCTAssertEqual(attrs["audio_seconds"] as? Double, 1_221)
        XCTAssertEqual(attrs["memory_pressure"] as? String, "warning")
        XCTAssertEqual(attrs["memory_pressure_at_start"] as? String, "normal")
    }

    /// The memory-pressure seed reads the kernel's level rather than assuming "normal".
    func test_theMemoryPressureSeed_isAKnownLevel() {
        XCTAssertTrue(["normal", "warning", "critical", "unknown"].contains(MemoryPressureWatch.seedLevel()))
    }

    /// The hand-off stamp is consumed by the first spawn and expires.
    func test_engineHandoff_isConsumedOnce_andExpires() {
        let handoff = EngineHandoff()
        let wav = URL(fileURLWithPath: "/tmp/obs10-\(UUID().uuidString).wav")
        handoff.note(file: wav, at: 100)
        XCTAssertEqual(handoff.take(file: wav, now: 101.25), 1_250)
        XCTAssertNil(handoff.take(file: wav, now: 101.5), "a library re-run of the same meeting carries none")
        handoff.note(file: wav, at: 100)
        XCTAssertNil(handoff.take(file: wav, now: 100 + EngineHandoff.maxAgeSec + 1), "a stale stamp is not the spawn that followed")
    }
}
