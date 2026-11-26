@preconcurrency import AVFoundation
import Foundation
import os

/// PERF28: the record-start file writes (the `.capturemode` marker, the mic capture file and
/// the recovery manifest), run off the main thread under a bound of their own and awaited.
///
/// They used to run synchronously on main inside `MeetingRecorder.start` and the controller's
/// start Task. On 4 of 74 field starts, each an early recording after a launch or rebuild,
/// the span holding `AVAudioFile(forWriting:)` took 2,274 to 3,078 ms, freezing the prompt
/// mid-fade with dead hotkeys. The cause is attributed to the create by elimination, so the
/// mic create logs its own duration (`mic file created in <n> ms`).
///
/// Not `engineCall`: its 2.0 s budget is below every measured slow create, each of which
/// succeeded, so routing through it would fail healthy starts and retire healthy engines.
/// A write here that runs out its budget is not an engine wedge and touches no engine state.
///
/// An abandoned write keeps running on its GCD thread, so it owns its own cleanup: when it
/// finally returns after the caller gave up, it deletes the file it was producing (the
/// `SystemCaptureStartAttempt` shape, REC17). A late `.mic.wav` or marker would otherwise
/// reappear after the failed start's unwind removed it. The manifest is the one exception
/// (`keepsLateResult`).
@MainActor
enum RecordStartFileWrite {

    /// Well above the slowest measured create (3.1 s) and the engine-call budget (2.0 s); the
    /// same figure as `engine.start()`'s budget. The UI stays live during the wait.
    nonisolated static let budgetSeconds = 8.0

    enum Outcome<Value> {
        /// The write returned inside its budget (or raced the deadline and stored first).
        case finished(Value, ms: Int)
        /// The budget ran out first. The write is abandoned and deletes what it produces.
        case timedOut
    }

    private struct Slot<Value> {
        var value: Value?
        var ms: Int?
        var abandoned = false
    }

    /// Run `body` off main, bounded, and hand its value back. Exactly one side owns the result:
    /// the caller adopts a value stored before it looked, however `runBlockingWithTimeout`
    /// reported; otherwise it marks the write abandoned, runs `onAbandon` in the same main-actor
    /// turn, and the write, when it returns, drops its value, removes `url` and calls
    /// `onLateFinish` from its own thread.
    ///
    /// `keepsLateResult` leaves a late file in place instead. Only the recovery manifest asks for
    /// it: its recording is usually still live when the late write lands, and deleting it would
    /// cost that meeting its crash routing (a BYO meeting auto-summarized), where keeping it costs
    /// at worst a stale `.recovery.json` beside a finished final.
    static func run<Value>(
        producing url: URL,
        budgetSeconds: Double = budgetSeconds,
        keepsLateResult: Bool = false,
        onAbandon: () -> Void = {},
        onLateFinish: @escaping @Sendable () -> Void = {},
        _ body: @escaping @Sendable () -> Value
    ) async -> Outcome<Value> {
        // `uncheckedState`: `AVAudioFile` makes no Sendable promise. It is created on the GCD
        // thread and handed to main once through this lock, after which only one side holds it,
        // the same single hand-off the serial writer already makes with it (CONC11's caution).
        let slot = OSAllocatedUnfairLock(uncheckedState: Slot<Value>())
        _ = await runBlockingWithTimeout(seconds: budgetSeconds) {
            let began = ProcessInfo.processInfo.systemUptime
            var value: Value? = body()
            let ms = Int(((ProcessInfo.processInfo.systemUptime - began) * 1000).rounded())
            let late = slot.withLockUnchecked { state -> Bool in
                if state.abandoned { return true }
                state.value = value
                state.ms = ms
                return false
            }
            guard late else { return }
            value = nil
            _ = value
            if keepsLateResult {
                Log.writeLine("recorder", "abandoned start write of \(url.lastPathComponent) finished after \(ms) ms; kept it")
            } else {
                try? FileManager.default.removeItem(at: url)
                Log.writeLine("recorder", "abandoned start write of \(url.lastPathComponent) finished after \(ms) ms; deleted it")
            }
            onLateFinish()
        }
        let adopted = slot.withLockUnchecked { state -> (Value, Int)? in
            if let value = state.value, let ms = state.ms {
                state.value = nil
                return (value, ms)
            }
            state.abandoned = true
            return nil
        }
        guard let (value, ms) = adopted else {
            onAbandon()
            return .timedOut
        }
        return .finished(value, ms: ms)
    }

    // MARK: - The mic capture file

    enum MicFileOutcome {
        case created(AVAudioFile)
        case failed(String)
        case timedOut
    }

    /// Create the mono mic capture file at `url`. Only the plain rate crosses into the closure,
    /// and the file's format is built there by `MeetingRecorder.monoCaptureFormat(sampleRate:)`,
    /// so no `AVAudioFormat` or settings dictionary crosses isolation. Logs the create's
    /// duration on every outcome.
    static func createMicFile(
        at url: URL,
        sampleRate: Double,
        budgetSeconds: Double = budgetSeconds,
        onAbandon: () -> Void = {},
        onLateFinish: @escaping @Sendable () -> Void = {},
        make: @escaping @Sendable (URL, Double) throws -> AVAudioFile = { try RecordStartFileWrite.makeMonoMicFile(at: $0, sampleRate: $1) }
    ) async -> MicFileOutcome {
        let outcome = await run(
            producing: url,
            budgetSeconds: budgetSeconds,
            onAbandon: onAbandon,
            onLateFinish: onLateFinish
        ) { () -> Result<AVAudioFile, Error> in
            Result { try make(url, sampleRate) }
        }
        switch outcome {
        case .finished(.success(let file), let ms):
            Log.writeLine("recorder", "mic file created in \(ms) ms")
            return .created(file)
        case .finished(.failure(let error), let ms):
            Log.writeLine("recorder", "mic file create failed in \(ms) ms: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        case .timedOut:
            Log.writeLine("recorder", "WARN: mic file create did not finish within \(Int(budgetSeconds)) s; abandoning the start")
            return .timedOut
        }
    }

    enum MicFileError: Error, LocalizedError {
        case noMonoFormat(Double)
        var errorDescription: String? {
            switch self {
            case .noMonoFormat(let rate): return "no mono capture format at \(rate) Hz"
            }
        }
    }

    nonisolated static func makeMonoMicFile(at url: URL, sampleRate: Double) throws -> AVAudioFile {
        guard let format = MeetingRecorder.monoCaptureFormat(sampleRate: sampleRate) else {
            throw MicFileError.noMonoFormat(sampleRate)
        }
        // SEC22: the owner's voice, so 0600 at creation, not the umask's 0644.
        return try OwnerOnlyFiles.openAudioForWriting(at: url, settings: format.settings)
    }
}
