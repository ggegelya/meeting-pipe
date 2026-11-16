import Foundation
import os

/// CONC5: the one run-to-completion subprocess primitive, replacing the hand-rolled `Process()` copies
/// that each picked their own drain order and their own bound (drain after exit, wait then read what is
/// buffered, abandon on timeout and never kill).
///
/// Contract:
///   - **Both pipes drain while the child runs** (through `ProcessOutputDrain`), so a child that writes
///     more than a pipe buffer to stderr can no longer block on the write while the caller blocks on the
///     exit. Output is kept as a bounded tail.
///   - **A timeout kills.** SIGTERM, a grace, then SIGKILL, escalated on the calling thread so no timer can
///     fire after the finish. Signals are gated on `process.isRunning`, never on the drain's own state
///     (it finishes up to its 2 s ceiling after the reap, and a pid can be reused in that window).
///   - **`reaped`** says whether the child is known to be gone when `run` returns. A caller that is about to
///     delete a file the child was writing deletes it only when `reaped` is true. A child in uninterruptible
///     I/O (a file being fetched from iCloud) can ignore SIGKILL, and the runner bounds its own wait rather
///     than hang with it.
///   - **`timedOut` means "this runner signalled a running child"**, so a child that exits in time while a
///     pipe lags is not reported as timed out.
///   - It blocks the CALLING thread, for at most `timeout + grace + drain ceiling + margin`. Callers are on a
///     GCD thread already, or use `runAsync`, which hops to one. It never runs on the cooperative pool
///     (a blocked pool thread starves every deadline sharing it, CI8).
///   - The grandchild caveat: it kills the child, not its process group. A child that forks (`mp` through
///     `uv`) can leave a grandchild behind, so "reaped" means the child is gone, not that nothing is still
///     writing.
enum ProcessRunner {

    struct Result {
        /// The child's exit status; -1 when it never ran or was not reaped.
        var status: Int32 = -1
        /// The last `stdoutLimit` bytes of stdout.
        var stdout = Data()
        /// The last `ProcessOutputDrain.stderrLimit` bytes of stderr.
        var stderrTail = Data()
        var timedOut = false
        var reaped = false
        /// Set when `Process.run()` threw, so nothing ran.
        var launchFailure: String?

        var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        var stderrText: String { String(decoding: stderrTail, as: UTF8.self) }
        /// Ran, was not killed by us, and exited 0.
        var succeeded: Bool { launchFailure == nil && !timedOut && reaped && status == 0 }
    }

    /// How long a SIGTERMed child gets before SIGKILL. `PipelineLauncher`'s cancel grace; its 30 s
    /// watchdog grace is for a local summary unwinding a model server and is wrong for a short call.
    static let killGrace: TimeInterval = 10
    /// Default bound on the kept stdout, for a caller that wants a small text answer.
    static let defaultStdoutLimit = 64 * 1024
    /// Slack past the drain's own ceiling when waiting for the reap after SIGKILL.
    private static let reapMargin: TimeInterval = 2

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval,
        grace: TimeInterval = killGrace,
        stdoutLimit: Int = defaultStdoutLimit
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input = stdin == nil ? nil : Pipe()
        if let input { process.standardInput = input }

        let finished = DispatchSemaphore(value: 0)
        let collected = OSAllocatedUnfairLock(initialState: (stdout: Data(), status: Int32(-1), stderr: Data()))
        let drain = ProcessOutputDrain(
            process: process, stdout: out, stderr: err, label: "runner",
            onChunk: { stream, data in
                guard stream == .stdout else { return }
                collected.withLock {
                    $0.stdout.append(data)
                    if $0.stdout.count > stdoutLimit { $0.stdout.removeFirst($0.stdout.count - stdoutLimit) }
                }
            },
            onFinished: { status, stderrTail in
                collected.withLock { $0.status = status; $0.stderr = stderrTail }
                finished.signal()
            }
        )
        do {
            try drain.run()
        } catch {
            return Result(launchFailure: error.localizedDescription)
        }
        if let input, let stdin { feed(stdin, into: input) }

        var timedOut = false
        var reaped = true
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            // Signal only a child that is still running; a child that exited with a lagging pipe is not
            // a timeout, and `terminate()` on one that is gone must not reach a reused pid.
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
            if finished.wait(timeout: .now() + grace) == .timedOut {
                if process.isRunning {
                    timedOut = true
                    kill(process.processIdentifier, SIGKILL)
                }
                reaped = finished.wait(timeout: .now() + ProcessOutputDrain.postExitCeiling + reapMargin) == .success
            }
        }
        let snapshot = collected.withLock { $0 }
        return Result(
            status: reaped ? snapshot.status : -1,
            stdout: snapshot.stdout,
            stderrTail: snapshot.stderr,
            timedOut: timedOut,
            reaped: reaped && !process.isRunning
        )
    }

    /// The async face: hops to a GCD thread (never the cooperative pool) and resumes a continuation.
    static func runAsync(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval,
        grace: TimeInterval = killGrace,
        stdoutLimit: Int = defaultStdoutLimit,
        qos: DispatchQoS.QoSClass = .utility
    ) async -> Result {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(returning: run(
                    executable: executable, arguments: arguments, environment: environment, stdin: stdin,
                    timeout: timeout, grace: grace, stdoutLimit: stdoutLimit
                ))
            }
        }
    }

    /// Writes `data` on its own thread and closes the child's stdin, so a child that never reads cannot
    /// park the caller before the timed wait starts. The parent's read end is closed first, so a child
    /// that dies turns a full pipe into EPIPE instead of leaving the writer blocked forever.
    private static func feed(_ data: Data, into pipe: Pipe) {
        try? pipe.fileHandleForReading.close()
        let writer = pipe.fileHandleForWriting
        // F_SETNOSIGPIPE: a child that exited before reading must fail the write with EPIPE, not deliver
        // the daemon a SIGPIPE.
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .utility).async {
            try? writer.write(contentsOf: data)
            try? writer.close()
        }
    }
}
