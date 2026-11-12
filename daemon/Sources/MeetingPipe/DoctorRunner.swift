import Combine
import Foundation

/// Runs `mp doctor` out of process and streams its output for the Preferences sheet. Reuses `PipelineLauncher.findMP()` resolution so it picks up the same environment the user has set up. State: idle -> running -> finished.
@MainActor
final class DoctorRunner: ObservableObject {

    enum State: Equatable {
        case idle
        case running
        case finished(exitCode: Int32)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var output: String = ""

    private var process: Process?

    /// PERF24: the self-check probes, run on `probeQueue` rather than on main. Injected so a
    /// test can hand in a probe that blocks.
    private let probes: [DoctorCommand.Probe]
    private let probeQueue: DispatchQueue
    /// Where `mp` is. `PipelineLauncher.findMP` in the app; a test passes `{ nil }` so the suite
    /// never spawns a real `mp doctor`. CONC7 names this same parameter for its spawn drain, so
    /// the two compose.
    private let invocation: () -> PipelineLauncher.MPInvocation?
    /// Bumped by every `run()` and `cancel()`, so a probe result from a run that was cancelled
    /// (the sheet closed mid-check) or superseded lands nowhere and spawns nothing.
    private var runToken = 0
    /// The current run's failed probes, for the self-check's verdict line.
    private var hardFails = 0

    init(
        probes: [DoctorCommand.Probe] = DoctorCommand.daemonSelfCheckProbes(),
        probeQueue: DispatchQueue = DispatchQueue.global(qos: .utility),
        invocation: @escaping () -> PipelineLauncher.MPInvocation? = { PipelineLauncher.findMP() }
    ) {
        self.probes = probes
        self.probeQueue = probeQueue
        self.invocation = invocation
    }

    /// Run the daemon self-check probes, then spawn `mp doctor`. The two
    /// halves are complementary: the Swift probes cover AX trust, TCC permissions,
    /// per-app reachability, events writability, and the orphan scan (things
    /// `mp doctor` cannot see); `mp doctor` covers credentials, network, and the
    /// pipeline (UX20). No-op if already running.
    ///
    /// PERF24: the probes run on `probeQueue`, never on main. They used to run inline under a
    /// "fast, in-process" comment, which holds on a healthy Mac and not with a hung meeting app,
    /// where each AX read waits out the process-wide 2 s messaging timeout, and a doctor run is
    /// what the owner reaches for when something is already wrong. Each result comes back to
    /// main in probe order (one serial loop, each hop a FIFO `DispatchQueue.main.async`), where
    /// its line is appended and its event emitted, so the sheet fills in as the probes finish in
    /// the order it always had. `mp doctor` spawns after the last one.
    func run() {
        guard state != .running else { return }
        state = .running
        runToken &+= 1
        hardFails = 0
        let token = runToken

        // The self-check's FAIL/WARN lines are visible in the sheet; the exit badge tracks
        // `mp doctor`.
        output = "== Daemon self-check ==\n"
        let probes = self.probes
        probeQueue.async {
            for probe in probes {
                let result = probe.run()
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.appendProbeResult(result, token: token) }
                }
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.finishSelfCheck(token: token) }
            }
        }
    }

    private func appendProbeResult(_ result: DoctorCommand.ProbeResult, token: Int) {
        guard token == runToken else { return }
        output.append(DoctorCommand.record(result) + "\n")
        if result.status == .fail { hardFails += 1 }
    }

    private func finishSelfCheck(token: Int) {
        guard token == runToken else { return }
        var lines = DoctorCommand.summaryLines(hardFails: hardFails)
        lines.append("")
        lines.append("== mp doctor ==")
        output.append(lines.joined(separator: "\n") + "\n")
        spawnMPDoctor()
    }

    private func spawnMPDoctor() {
        guard let mp = invocation() else {
            output.append("mp launcher not found. Did you run scripts/install.sh?\n")
            state = .finished(exitCode: -1)
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: mp.shell)
        p.arguments = mp.args + ["doctor"]
        p.environment = PipelineLauncher.freshEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        // Merge stdout and stderr into the same output so FAIL/WARN lines appear in context.
        // `@Sendable` because the two `readabilityHandler` closures below are `@Sendable`
        // and capture it; it only touches a `@MainActor` DoctorRunner via `weak self`.
        let appender: @Sendable (Data) -> Void = { [weak self] data in
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.output.append(chunk)
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            appender(handle.availableData)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            appender(handle.availableData)
        }

        p.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor [weak self] in
                self?.state = .finished(exitCode: proc.terminationStatus)
                self?.process = nil
            }
        }

        do {
            try p.run()
            self.process = p
        } catch {
            output = "Failed to spawn `mp doctor`: \(error.localizedDescription)\n"
            state = .finished(exitCode: -1)
        }
    }

    /// Cancel an in-flight run (called when the user closes the sheet before the doctor finishes).
    /// Also stands down a self-check still on `probeQueue`: its results land nowhere and it
    /// spawns no `mp doctor`.
    func cancel() {
        runToken &+= 1
        process?.terminate()
        process = nil
        if state == .running {
            state = .finished(exitCode: -1)
        }
    }
}
