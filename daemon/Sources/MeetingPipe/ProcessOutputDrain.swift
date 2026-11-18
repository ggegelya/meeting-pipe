import Foundation
import os

/// CONC7: the streaming read side of a long-lived child (`mp doctor`, `mp run-all`), one type so every
/// spawn that streams ends its pipes the same way.
///
/// What it replaces cleared `readabilityHandler` inside `terminationHandler`. The child being reaped
/// and the readability source having delivered what is still in the pipe are independent events, so the
/// last chunk (for `mp`, the traceback the failure caption is built from) could be dropped, and the
/// stderr tail was a captured `var` appended on the pipe queue and read on the termination queue.
///
/// Contract:
///   - Chunks from both streams reach `onChunk` on ONE private serial queue, so a consumer that hops to
///     main with a FIFO `DispatchQueue.main.async` sees them in order.
///   - `onFinished(status, stderrTail)` fires exactly once, on that same queue and therefore after every
///     chunk, once the process has exited AND both pipes have reached EOF. The handlers are cleared
///     here, after EOF, never in a termination handler.
///   - A grandchild that inherited a pipe holds it open past the child's own exit. So the finish also has
///     a ceiling after exit (`postExitCeiling`); past it, it finishes with what it holds and logs once.
///   - Never blocks: reads happen only when the dispatch source says data is ready.
///
/// All mutable state lives behind one `OSAllocatedUnfairLock`, so the type is genuinely `Sendable`
/// (no new `@unchecked`, per `daemon/CLAUDE.md`).
final class ProcessOutputDrain: Sendable {

    enum Stream: Sendable { case stdout, stderr }

    /// How long a finished child's pipes get to reach EOF. A grandchild holding stderr open is the
    /// only reason EOF lags the exit, so 2 s is generous for the kernel to flush a normal child and
    /// short enough that a leaked grandchild does not hold the result.
    static let postExitCeiling: TimeInterval = 2
    /// Bound on the stderr tail handed to `onFinished` (what `mp` failure captions are built from).
    static let stderrLimit = 4096

    private struct State {
        var stderrTail = Data()
        var stdoutEOF = false
        var stderrEOF = false
        var exitStatus: Int32?
        var finished = false
    }

    private let process: Process
    private let outHandle: FileHandle
    private let errHandle: FileHandle
    private let queue: DispatchQueue
    private let onChunk: @Sendable (Stream, Data) -> Void
    private let onFinished: @Sendable (Int32, Data) -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// `process`'s `standardOutput` / `standardError` must already be `stdout` / `stderr`. The drain
    /// owns `process.terminationHandler` from here on.
    init(
        process: Process,
        stdout: Pipe,
        stderr: Pipe,
        label: String,
        onChunk: @escaping @Sendable (Stream, Data) -> Void,
        onFinished: @escaping @Sendable (Int32, Data) -> Void
    ) {
        self.process = process
        self.outHandle = stdout.fileHandleForReading
        self.errHandle = stderr.fileHandleForReading
        self.queue = DispatchQueue(label: "com.meetingpipe.drain.\(label)")
        self.onChunk = onChunk
        self.onFinished = onFinished
    }

    /// Install the readers and start the process. If the spawn itself throws, nothing is left behind
    /// (no handler, no descriptor, no retain cycle) and `onFinished` never fires.
    func run() throws {
        outHandle.readabilityHandler = { [self] h in read(h, stream: .stdout) }
        errHandle.readabilityHandler = { [self] h in read(h, stream: .stderr) }
        process.terminationHandler = { [self] p in exited(status: p.terminationStatus) }
        do {
            try process.run()
        } catch {
            detach()
            throw error
        }
    }

    /// Drop everything without a process exit: handlers cleared, both pipes closed. For a spawn that
    /// never ran, whose termination handler would never fire to do it.
    func detach() {
        state.withLock { $0.finished = true }
        outHandle.readabilityHandler = nil
        errHandle.readabilityHandler = nil
        process.terminationHandler = nil
        for handle in [outHandle, errHandle] { try? handle.close() }
        if let pipe = process.standardOutput as? Pipe { try? pipe.fileHandleForWriting.close() }
        if let pipe = process.standardError as? Pipe { try? pipe.fileHandleForWriting.close() }
        // A supervised spawn (PIPE37) also has a stdin pipe whose read end only the child would have closed.
        if let pipe = process.standardInput as? Pipe { try? pipe.fileHandleForReading.close() }
    }

    // MARK: Reads (the pipe queues)

    private func read(_ handle: FileHandle, stream: Stream) {
        let data = handle.availableData
        if data.isEmpty {
            // EOF. Clearing here is what stops the source re-firing on a closed pipe.
            handle.readabilityHandler = nil
            queue.async { [self] in reachedEOF(stream) }
        } else {
            queue.async { [self] in deliver(data, stream: stream) }
        }
    }

    // MARK: State (the private queue)

    private func deliver(_ data: Data, stream: Stream) {
        let live = state.withLock { s -> Bool in
            if s.finished { return false }
            if stream == .stderr {
                s.stderrTail.append(data)
                if s.stderrTail.count > Self.stderrLimit {
                    s.stderrTail.removeFirst(s.stderrTail.count - Self.stderrLimit)
                }
            }
            return true
        }
        if live { onChunk(stream, data) }
    }

    private func reachedEOF(_ stream: Stream) {
        state.withLock { s in
            if stream == .stdout { s.stdoutEOF = true } else { s.stderrEOF = true }
        }
        finishIfReady(force: false)
    }

    private func exited(status: Int32) {
        queue.async { [self] in
            state.withLock { $0.exitStatus = status }
            queue.asyncAfter(deadline: .now() + Self.postExitCeiling) { [self] in
                finishIfReady(force: true)
            }
            finishIfReady(force: false)
        }
    }

    private func finishIfReady(force: Bool) {
        let outcome = state.withLock { s -> (Int32, Data, Bool)? in
            guard !s.finished, let status = s.exitStatus else { return nil }
            let bothEOF = s.stdoutEOF && s.stderrEOF
            guard bothEOF || force else { return nil }
            s.finished = true
            return (status, s.stderrTail, !bothEOF)
        }
        guard let (status, tail, timedOut) = outcome else { return }
        outHandle.readabilityHandler = nil
        errHandle.readabilityHandler = nil
        process.terminationHandler = nil
        if timedOut {
            Log.failure(category: "daemon", action: "process_drain_pipe_held", reason: "a pipe stayed open past the child's exit (a grandchild holds it); finishing with what was read", attributes: [
                "ceiling_sec": Int(Self.postExitCeiling),
            ])
        }
        onFinished(status, tail)
    }
}
