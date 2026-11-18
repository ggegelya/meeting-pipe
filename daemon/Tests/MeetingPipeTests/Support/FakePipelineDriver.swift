import Foundation
@testable import MeetingPipe

/// T13: the one `PipelineDriver` double, replacing three `FakeDriver`s, three `NoopDriver`s and a
/// `CountingDriver` that each covered a different subset. Every call is recorded. A call that takes a
/// completion parks it until the test resolves it with that method's `finish…`, oldest first, so a
/// test decides when, and with what, the "subprocess" ends; until then nothing completes, which is
/// what the no-op drivers did. Methods this fake does not implement keep the protocol's `NSError`
/// defaults, so an unexpected call fails rather than succeeds.
///
/// Exceptions kept from the fakes they replace: `rosterForget` and `rosterUnenroll` complete
/// synchronously (with `unenrollResult` for the latter), and the restore pair holds only the latest
/// completion, as `RestoreFlowTests` always had it.
///
/// Recording and parking are lock-guarded; completions run outside the lock, on the caller's thread.
final class FakePipelineDriver: PipelineDriver, @unchecked Sendable {

    /// A FIFO of parked completions for one method.
    private final class Parked<R> {
        var completions: [(R) -> Void] = []
    }

    private let lock = NSLock()
    private func locked<T>(_ body: () -> T) -> T { lock.withLock(body) }
    private func park<R>(_ queue: Parked<R>, _ completion: @escaping (R) -> Void) {
        locked { queue.completions.append(completion) }
    }
    private func resolve<R>(_ queue: Parked<R>, _ result: R) {
        let head: ((R) -> Void)? = locked { queue.completions.isEmpty ? nil : queue.completions.removeFirst() }
        head?(result)
    }

    // MARK: - run-all, cancel, supervise

    private(set) var startedFiles: [URL] = []
    /// The progress callback the caller handed the active run (TECH-UX5).
    private(set) var capturedProgress: ((PipelineProgress) -> Void)?
    private(set) var cancelled = 0
    var cancelCalled: Bool { cancelled > 0 }
    private(set) var terminated = 0
    private let runAllQueue = Parked<Result<URL?, Error>>()

    func runAll(wav: URL, summaryMode: SummaryMode, completion: @escaping (Result<URL?, Error>) -> Void) {
        runAll(wav: wav, summaryMode: summaryMode, onProgress: nil, completion: completion)
    }

    func runAll(
        wav: URL,
        summaryMode: SummaryMode,
        onProgress: ((PipelineProgress) -> Void)?,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        locked {
            startedFiles.append(wav)
            capturedProgress = onProgress
        }
        park(runAllQueue, completion)
    }

    /// Resolve the oldest in-flight run-all.
    func finish(_ result: Result<URL?, Error>) { resolve(runAllQueue, result) }

    /// Fire a progress heartbeat as if the subprocess emitted one.
    func emitProgress(_ progress: PipelineProgress) {
        let progressSink = locked { capturedProgress }
        progressSink?(progress)
    }

    func cancelActiveRun() { locked { cancelled += 1 } }
    func terminateSupervised() { locked { terminated += 1 } }

    // MARK: - finalize (ASR3)

    private(set) var finalizedFiles: [URL] = []
    private let finalizeQueue = Parked<Result<Void, Error>>()

    func finalize(wav: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        locked { finalizedFiles.append(wav) }
        park(finalizeQueue, completion)
    }

    func finishFinalize(_ result: Result<Void, Error>) { resolve(finalizeQueue, result) }

    // MARK: - summarize, preview, publish

    private(set) var summarizeInputs: [URL] = []
    /// PIPE6: the one-shot backend override forwarded into each summarize call.
    private(set) var summarizeBackends: [String?] = []
    private(set) var publishInputs: [URL] = []
    private(set) var publishFromPasteInputs: [URL] = []
    private(set) var previewInputs: [URL] = []
    private(set) var applePreviewInputs: [URL] = []
    /// TECH-FEAT7: the contextOverride forwarded into each preview call, both engines.
    private(set) var previewContextOverrides: [String?] = []
    private let summarizeQueue = Parked<Result<Void, Error>>()
    private let publishQueue = Parked<Result<URL?, Error>>()
    private let publishFromPasteQueue = Parked<Result<Void, Error>>()
    private let previewQueue = Parked<Result<Void, Error>>()

    func summarizePreview(transcriptMD: URL, contextOverride: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        locked {
            previewInputs.append(transcriptMD)
            previewContextOverrides.append(contextOverride)
        }
        park(previewQueue, completion)
    }

    func summarizePreviewViaApple(transcriptMD: URL, contextOverride: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        locked {
            applePreviewInputs.append(transcriptMD)
            previewContextOverrides.append(contextOverride)
        }
        park(previewQueue, completion)
    }

    func finishPreview(_ result: Result<Void, Error>) { resolve(previewQueue, result) }

    func summarize(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        summarize(transcriptMD: transcriptMD, backend: nil, completion: completion)
    }

    func summarize(transcriptMD: URL, backend: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        locked {
            summarizeInputs.append(transcriptMD)
            summarizeBackends.append(backend)
        }
        park(summarizeQueue, completion)
    }

    func finishSummarize(_ result: Result<Void, Error>) { resolve(summarizeQueue, result) }

    func publish(summaryJSON: URL, completion: @escaping (Result<URL?, Error>) -> Void) {
        locked { publishInputs.append(summaryJSON) }
        park(publishQueue, completion)
    }

    func finishPublish(_ result: Result<URL?, Error>) { resolve(publishQueue, result) }

    func publishFromPaste(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        locked { publishFromPasteInputs.append(transcriptMD) }
        park(publishFromPasteQueue, completion)
    }

    func finishPublishFromPaste(_ result: Result<Void, Error>) { resolve(publishFromPasteQueue, result) }

    // MARK: - merge (FEAT9)

    private(set) var mergeInputs: [(primary: URL, fragments: [URL])] = []
    private let mergeQueue = Parked<Result<URL?, Error>>()

    func mergeMeetings(primary: URL, fragments: [URL], completion: @escaping (Result<URL?, Error>) -> Void) {
        locked { mergeInputs.append((primary, fragments)) }
        park(mergeQueue, completion)
    }

    func finishMerge(_ result: Result<URL?, Error>) { resolve(mergeQueue, result) }

    // MARK: - ask (UX37)

    private(set) var askInputs: [String] = []
    /// UX37: how many times Ask's Cancel reached the driver.
    private(set) var cancelAskCalls = 0
    private let askQueue = Parked<Result<AskAnswer, Error>>()

    func ask(question: String, completion: @escaping (Result<AskAnswer, Error>) -> Void) {
        locked { askInputs.append(question) }
        park(askQueue, completion)
    }

    func cancelAsk() { locked { cancelAskCalls += 1 } }

    func finishAsk(_ result: Result<AskAnswer, Error>) { resolve(askQueue, result) }

    // MARK: - roster (FEAT3-UNDO, FEAT24)

    private(set) var enrollInputs: [(name: String, label: String, noRelabel: Bool)] = []
    private(set) var forgetInputs: [String] = []
    /// FEAT24: the stem is the anchor's, so a test can pin that the unenroll names THIS meeting.
    private(set) var unenrollInputs: [(name: String, label: String, stem: String)] = []
    var unenrollResult: Result<Void, Error> = .success(())
    private let enrollQueue = Parked<Result<Void, Error>>()

    func rosterUnenroll(name: String, label: String, wav: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let result: Result<Void, Error> = locked {
            unenrollInputs.append((name, label, wav.deletingPathExtension().lastPathComponent))
            return unenrollResult
        }
        completion(result)
    }

    func rosterEnroll(name: String, label: String, wav: URL, noRelabel: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        locked { enrollInputs.append((name, label, noRelabel)) }
        park(enrollQueue, completion)
    }

    func rosterForget(name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        locked { forgetInputs.append(name) }
        completion(.success(()))
    }

    func finishEnroll(_ result: Result<Void, Error>) { resolve(enrollQueue, result) }

    // MARK: - restore (STOR5): the latest completion only

    private(set) var restorePreviewed: [URL] = []
    private(set) var restored: [URL] = []
    private var restorePreviewCompletion: ((Result<RestorePlan, Error>) -> Void)?
    private var restoreCompletion: ((Result<Void, Error>) -> Void)?

    func restorePreview(archive: URL, completion: @escaping (Result<RestorePlan, Error>) -> Void) {
        locked {
            restorePreviewed.append(archive)
            restorePreviewCompletion = completion
        }
    }

    func restore(archive: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        locked {
            restored.append(archive)
            restoreCompletion = completion
        }
    }

    func landPreview(_ plan: RestorePlan) { locked { restorePreviewCompletion }?(.success(plan)) }
    func failPreview(_ message: String) { locked { restorePreviewCompletion }?(.failure(Self.error(message))) }
    func landRestore() { locked { restoreCompletion }?(.success(())) }
    func failRestore(_ message: String) { locked { restoreCompletion }?(.failure(Self.error(message))) }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
