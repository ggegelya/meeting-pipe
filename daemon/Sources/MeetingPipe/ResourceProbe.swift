import Darwin
import Foundation
import os

/// OBS10: what a post-stop job cost and what the machine was doing, so a slow episode (a 53 s
/// finalize, ASR at 3x real time instead of 70x, a 36 s `mp` launch) can be attributed from the log
/// instead of guessed at. Measure only: nothing here decides anything.

/// One job's wall and CPU time, and the arithmetic on them. Pure.
struct ResourceSample: Equatable {
    var wallMs: Double
    var cpuMs: Double
    /// Involuntary context switches over the span (`ru_nivcsw` delta): the scheduler taking the CPU
    /// away, which is what "busy elsewhere" looks like. Nil when not read.
    var involuntarySwitches: Double? = nil

    /// CPU over wall. Above 1.0 for a multi-threaded job, deliberately not clamped. Read it with
    /// care for ASR: FluidAudio runs on the CPU and the Neural Engine, and Neural Engine time is not
    /// in `getrusage`, so a healthy pass reads well under 1 and a fall back to the CPU reads higher.
    /// `involuntarySwitches` is the direct contention signal. Nil for a zero wall time.
    var cpuShare: Double? {
        wallMs > 0 ? cpuMs / wallMs : nil
    }

    /// Real-time factor: seconds of audio per second of wall time (70 to 100 healthy, 3 to 19 in the
    /// slow episodes). Nil for a zero wall time.
    func rtf(audioSeconds: Double) -> Double? {
        wallMs > 0 ? audioSeconds / (wallMs / 1000) : nil
    }

    /// The row attributes: `wall_ms`, `cpu_ms`, and `cpu_share` when there is one.
    var attributes: [String: Any] {
        var attrs: [String: Any] = ["wall_ms": wallMs.rounded(), "cpu_ms": cpuMs.rounded()]
        if let share = cpuShare { attrs["cpu_share"] = (share * 100).rounded() / 100 }
        if let switches = involuntarySwitches { attrs["involuntary_switches"] = switches }
        return attrs
    }
}

/// The machine's state at one moment, as fixed strings and booleans.
struct MachineState: Equatable {
    var thermalState: String
    var lowPower: Bool
    var memoryPressure: String

    /// FluidAudio is handed no `computeUnits`, so the models run on its default, which at the pinned
    /// version is `.cpuAndNeuralEngine` (`MLModelConfigurationUtils`). Named, so a FluidAudio bump
    /// that changes it is one string to update rather than a silent drift (ASR8 measures where ops
    /// actually run).
    static let computeUnits = "cpu_and_neural_engine"

    /// `thermal_state`, `low_power`, `memory_pressure`, with `suffix` appended to each key (the
    /// start-of-job snapshot rides beside the end one as `_at_start`).
    func attributes(suffix: String = "") -> [String: Any] {
        [
            "thermal_state\(suffix)": thermalState,
            "low_power\(suffix)": lowPower,
            "memory_pressure\(suffix)": memoryPressure,
        ]
    }

    static func label(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// The reads behind the rows, as closures so a test can inject them.
struct ResourceProbe {
    /// This process's user plus system CPU time, in ms (`getrusage(RUSAGE_SELF)`). Covers every
    /// thread, so a delta around a job also counts whatever else the daemon did meanwhile.
    var selfCPUMs: () -> Double = { ResourceProbe.rusageMs(RUSAGE_SELF) }
    /// Reaped children's CPU time, in ms (`getrusage(RUSAGE_CHILDREN)`). A delta around the ffmpeg
    /// merge also counts any other child reaped meanwhile (an `mp` run finishing); `ProcessRunner`
    /// rides on `Process`, which offers no per-child `wait4` rusage.
    var childrenCPUMs: () -> Double = { ResourceProbe.rusageMs(RUSAGE_CHILDREN) }
    /// This process's involuntary context switches so far (`ru_nivcsw`).
    var selfInvoluntarySwitches: () -> Double = { ResourceProbe.involuntarySwitches(RUSAGE_SELF) }
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var machine: () -> MachineState = {
        MachineState(
            thermalState: MachineState.label(ProcessInfo.processInfo.thermalState),
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            memoryPressure: MemoryPressureWatch.shared.level
        )
    }

    static let live = ResourceProbe()

    static func involuntarySwitches(_ who: Int32) -> Double {
        var usage = rusage()
        guard getrusage(who, &usage) == 0 else { return 0 }
        return Double(usage.ru_nivcsw)
    }

    static func rusageMs(_ who: Int32) -> Double {
        var usage = rusage()
        guard getrusage(who, &usage) == 0 else { return 0 }
        func ms(_ t: timeval) -> Double { Double(t.tv_sec) * 1000 + Double(t.tv_usec) / 1000 }
        return ms(usage.ru_utime) + ms(usage.ru_stime)
    }

    /// A job in progress: the start readings, closed by `finish`.
    struct Span {
        let probe: ResourceProbe
        let cpu: () -> Double
        let switches: (() -> Double)?
        let startedAt: TimeInterval
        let cpuAtStart: Double
        let switchesAtStart: Double?
        let machineAtStart: MachineState

        func finish() -> (sample: ResourceSample, machineAtStart: MachineState, machine: MachineState) {
            let sample = ResourceSample(
                wallMs: max(0, (probe.uptime() - startedAt) * 1000),
                cpuMs: max(0, cpu() - cpuAtStart),
                involuntarySwitches: switches.flatMap { read in switchesAtStart.map { max(0, read() - $0) } }
            )
            return (sample, machineAtStart, probe.machine())
        }
    }

    func begin(cpu: @escaping () -> Double, switches: (() -> Double)? = nil) -> Span {
        Span(
            probe: self, cpu: cpu, switches: switches, startedAt: uptime(), cpuAtStart: cpu(),
            switchesAtStart: switches?(), machineAtStart: machine()
        )
    }
}

/// The latest memory-pressure level, from one `DispatchSource.makeMemoryPressureSource` the daemon
/// creates at launch (`Coordinator`) and keeps for its lifetime. Seeded from
/// `kern.memorystatus_vm_pressure_level`, because the source fires only on a change: a daemon
/// launched into a machine already under pressure would otherwise read "normal" all day.
/// "unknown" when the seed read fails and nothing has been signalled since.
final class MemoryPressureWatch: Sendable {
    static let shared = MemoryPressureWatch()

    private let lock = OSAllocatedUnfairLock(initialState: MemoryPressureWatch.seedLevel())

    /// The kernel's current level: 1 normal, 2 warning, 4 critical.
    static func seedLevel() -> String {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return "unknown" }
        switch level {
        case 1: return "normal"
        case 2: return "warning"
        case 4: return "critical"
        default: return "unknown"
        }
    }

    private init() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: DispatchQueue.global(qos: .utility)
        )
        // The handler holds the source, which holds the handler: the watch lives as long as the
        // daemon, which is the point, and nothing else needs a reference to it.
        source.setEventHandler { [lock] in
            let event = source.data
            let label = event.contains(.critical) ? "critical" : event.contains(.warning) ? "warning" : "normal"
            lock.withLock { $0 = label }
        }
        source.resume()
    }

    var level: String { lock.withLock { $0 } }
}

/// OBS10: the `engine_succeeded` moment for each recording, so the `mp` spawn that follows it can say
/// how long the daemon took to get there (`ms_since_engine`), splitting `engine_succeeded` to
/// `run_started` into the daemon's delay and Python's start. Consumed by the first spawn for that
/// file, so a later library re-run of the same meeting carries none.
final class EngineHandoff: Sendable {
    static let shared = EngineHandoff()

    /// A stamp older than this is not "the spawn that followed": the hand-off failed or was cancelled.
    static let maxAgeSec: TimeInterval = 600

    private let lock = OSAllocatedUnfairLock(initialState: [String: TimeInterval]())

    func note(file: URL, at uptime: TimeInterval) {
        lock.withLock { $0[file.standardizedFileURL.path] = uptime }
    }

    /// The ms since the noted engine success for `file`, consuming it; nil if there is none recent.
    /// Taken at the top of `runMP`, so a spawn that never happens still consumes it and a later,
    /// unrelated spawn for the same file (a roster enroll) cannot inherit it.
    func take(file: URL, now: TimeInterval) -> Double? {
        let key = file.standardizedFileURL.path
        return lock.withLock { stamps -> Double? in
            guard let at = stamps.removeValue(forKey: key) else { return nil }
            stamps = stamps.filter { now - $0.value <= Self.maxAgeSec }
            let age = now - at
            return age >= 0 && age <= Self.maxAgeSec ? (age * 1000).rounded() : nil
        }
    }
}
