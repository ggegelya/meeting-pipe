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

    /// Spawn `mp doctor`; no-op if already running.
    func run() {
        guard state != .running else { return }
        guard let mp = PipelineLauncher.findMP() else {
            output = "mp launcher not found. Did you run scripts/install.sh?\n"
            state = .finished(exitCode: -1)
            return
        }

        output = ""
        state = .running

        let p = Process()
        p.executableURL = URL(fileURLWithPath: mp.shell)
        p.arguments = mp.args + ["doctor"]
        p.environment = PipelineLauncher.freshEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        // Merge stdout and stderr into the same output so FAIL/WARN lines appear in context.
        let appender = { [weak self] (data: Data) in
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
    func cancel() {
        process?.terminate()
        process = nil
        if state == .running {
            state = .finished(exitCode: -1)
        }
    }
}
