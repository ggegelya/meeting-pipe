import XCTest
@testable import MeetingPipe

/// REC28: a system capture the channel has given up on can still write into it. `stop()` cut no
/// delivery for a stream it had adopted, the channel took a buffer from any capture while a file
/// was open, and the start Task applied `.started` / `.failed` from the cooperative pool with no
/// identity check. So a stream whose `stopCapture()` hung past `haltCapture`'s 5 s (the 2026-06-05
/// class) or the loss path's unbounded stop could write into the next recording's or the retry's
/// system WAV, and a late `.failed` could clear a file a retry had just been handed.
///
/// Pinned here: the pure halves (the attempt's stop gate, the channel's generation ledger), the
/// lifted outcome method driven through a headlessly armed channel (`armSystemCapture` builds the
/// capture object but never calls `start()`, so nothing reaches ScreenCaptureKit), the bounded
/// stop's event under scratch logs, and source fences on the wiring.
/// T7 source fence (pins implementation): four tests grep SystemAudioCapture and SystemAudioChannel for the stop-gate ordering, the delivery-callback gate (one read of the pure ledger's `deliversBuffers`), the buffer closure's generation check and the two bounded stop sites. Missing seam: an injectable SCStream in SystemAudioCapture (so no test can make a real stream deliver after `stop()`), and an injectable capture in SystemAudioChannel (so the loss path's own `Task` is fenced, while the helper it calls is driven for real with a stop that never returns).
final class SystemCaptureStopREC28Tests: XCTestCase {

    // MARK: - Item 1: the stop gate on the attempt

    func test_anAdoptedAttemptDeliversUntilTheStopGateIsSetAndNothingAfter() {
        var attempt = SystemCaptureStartAttempt()
        XCTAssertEqual(attempt.completed(), .adopt)
        XCTAssertTrue(attempt.deliversBuffers, "an adopted, unstopped stream delivers")
        attempt.stopDelivery()
        XCTAssertFalse(attempt.deliversBuffers, "from the top of stop(), nothing, however long stopCapture() takes")
        XCTAssertFalse(attempt.isAbandoned, "stopping an adopted stream is not abandoning its start")
    }

    /// `stopped()` was not the fix: it is a no-op once the attempt completed, and it would change
    /// what an `Abandonment` means. The gate is a field of its own.
    func test_theStopGateChangesNeitherTheCompletionNorAnAbandonment() {
        var gatedFirst = SystemCaptureStartAttempt()
        gatedFirst.stopDelivery()
        XCTAssertNil(gatedFirst.abandonment)
        XCTAssertEqual(gatedFirst.completed(), .adopt, "the gate alone does not turn an adoption into a discard")

        var timedOut = SystemCaptureStartAttempt()
        timedOut.timedOut()
        timedOut.stopDelivery()
        XCTAssertEqual(timedOut.abandonment, .timedOut)
        XCTAssertEqual(timedOut.completed(), .discard(.timedOut), "nor relabel an existing abandonment")

        var stopped = SystemCaptureStartAttempt()
        stopped.stopped()
        stopped.stopDelivery()
        XCTAssertEqual(stopped.completed(), .discard(.stopped))
    }

    func test_anAbandonedAttemptStillDeliversNothing() {
        var timedOut = SystemCaptureStartAttempt()
        timedOut.timedOut()
        XCTAssertFalse(timedOut.deliversBuffers)

        var lateAbandon = SystemCaptureStartAttempt()
        XCTAssertEqual(lateAbandon.completed(), .adopt)
        lateAbandon.timedOut()
        XCTAssertFalse(lateAbandon.deliversBuffers, "REC17's gate is unchanged by the stop gate's arrival")
    }

    // MARK: - Item 2: the channel's generation ledger

    func test_aGenerationIsLiveFromItsArmUntilInvalidatedOrReplaced() {
        var ledger = SystemCaptureGenerations()
        XCTAssertFalse(ledger.isLive(0), "0 is never live: it is what an unarmed channel holds")
        let first = ledger.arm()
        XCTAssertTrue(ledger.isLive(first))
        let second = ledger.arm()
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(ledger.isLive(first), "a retry's arm makes the dying capture stale")
        XCTAssertTrue(ledger.isLive(second))
        ledger.invalidate()
        XCTAssertFalse(ledger.isLive(second), "halt and loss let the capture go without arming another")
        let third = ledger.arm()
        XCTAssertNotEqual(third, first, "numbers are never reused, or a zombie from an earlier recording matches again")
        XCTAssertNotEqual(third, second)
    }

    /// A stale generation, or no open file, touches nothing.
    func test_theBufferPredicateNeedsTheLiveGenerationAndAnOpenFile() {
        var ledger = SystemCaptureGenerations()
        let stale = ledger.arm()
        let live = ledger.arm()
        XCTAssertTrue(ledger.accepts(live, hasOpenFile: true))
        XCTAssertFalse(ledger.accepts(live, hasOpenFile: false), "after closeFile() nothing is written, as before")
        XCTAssertFalse(ledger.accepts(stale, hasOpenFile: true), "the next recording's open file is not the zombie's")
        ledger.invalidate()
        XCTAssertFalse(ledger.accepts(live, hasOpenFile: true))
    }

    // MARK: - Item 3: the start outcome, on main, to its own attempt

    /// The stop shape: `haltCapture`'s start-await timed out, the stop went on, and the start's
    /// `.failed` lands afterwards. It used to nil whatever file and writer the channel held and
    /// delete the path; now it leaves them as they were.
    @MainActor
    func test_aLateFailureForACaptureAStopAlreadyHaltedLeavesTheFileAlone() async throws {
        try await withScratchChannel { channel, url in
            let armed = channel.armSystemCapture(systemURL: url, isRetry: false)
            XCTAssertTrue(channel.acceptsBuffer(from: armed.generation))
            await channel.haltCapture()
            XCTAssertFalse(channel.acceptsBuffer(from: armed.generation), "a halted capture's buffers are refused")

            channel.applyStartOutcome(.failed("late"), to: armed, systemURL: url, isRetry: false)

            XCTAssertTrue(channel.hasOpenSystemFile)
            XCTAssertNotNil(channel.systemWriter)
            XCTAssertFalse(channel.systemDegraded)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    /// The retry shape: a loss, then a retry armed into the same path, then the first attempt's
    /// late outcome. Neither `.failed` nor `.started` for the replaced capture may touch the
    /// retry's file, writer or `systemDegraded`; the retry's own outcome behaves as today.
    @MainActor
    func test_lateOutcomesForACaptureARetryReplacedLeaveTheRetryAlone() async throws {
        try await withScratchChannel { channel, url in
            channel.isRecordingProvider = { true }
            let first = channel.armSystemCapture(systemURL: url, isRetry: false)
            channel.handleSystemAudioLost(reason: "rec28_test", autoRetry: false)
            XCTAssertTrue(channel.systemDegraded)
            XCTAssertFalse(channel.acceptsBuffer(from: first.generation), "the loss path refuses the dying stream at once")

            let retry = channel.armSystemCapture(systemURL: url, isRetry: true)
            XCTAssertTrue(channel.acceptsBuffer(from: retry.generation))
            XCTAssertFalse(channel.acceptsBuffer(from: first.generation))

            channel.applyStartOutcome(.failed("late"), to: first, systemURL: url, isRetry: false)
            XCTAssertTrue(channel.hasOpenSystemFile, "the retry's file stays open")
            XCTAssertNotNil(channel.systemWriter, "and its writer stays")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "and the path stays on disk")
            XCTAssertTrue(channel.systemDegraded, "a stale failure does not speak for the retry either way")
            XCTAssertTrue(channel.acceptsBuffer(from: retry.generation), "nor end the retry's generation")

            channel.applyStartOutcome(.started, to: first, systemURL: url, isRetry: false)
            XCTAssertTrue(channel.systemDegraded, "a late start for the replaced capture leaves systemDegraded alone")

            var recovered = 0
            channel.onSystemAudioRecovered = { recovered += 1 }
            channel.applyStartOutcome(.started, to: retry, systemURL: url, isRetry: true)
            XCTAssertFalse(channel.systemDegraded, "the live retry's start clears it, as before")
            XCTAssertEqual(recovered, 1, "and fires the recovery callback, now synchronously on main")
        }
    }

    /// A current fresh start that failed still drops the empty file and degrades, as before.
    @MainActor
    func test_aCurrentFailureOnAFreshFileBehavesAsBefore() async throws {
        try await withScratchChannel { channel, url in
            let armed = channel.armSystemCapture(systemURL: url, isRetry: false)
            var degradedReasons: [String] = []
            channel.onSystemAudioDegraded = { degradedReasons.append($0) }

            channel.applyStartOutcome(.failed("no display"), to: armed, systemURL: url, isRetry: false)

            XCTAssertFalse(channel.hasOpenSystemFile)
            XCTAssertNil(channel.systemWriter)
            XCTAssertTrue(channel.systemDegraded)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "merge has to know there is nothing to mix")
            XCTAssertEqual(degradedReasons, ["no display"])
            XCTAssertFalse(channel.acceptsBuffer(from: armed.generation), "a failed start's generation is let go too")
        }
    }

    /// REC10's half of the same branch: a current failure on a resumed file keeps the file.
    @MainActor
    func test_aCurrentFailureOnAResumedFileKeepsIt() async throws {
        try await withScratchChannel { channel, url in
            let armed = channel.armSystemCapture(systemURL: url, isRetry: false)
            let resumed = SystemAudioChannel.ArmedSystemCapture(
                capture: armed.capture, generation: armed.generation, resumedOpenFile: true
            )
            channel.applyStartOutcome(.failed("retry failed"), to: resumed, systemURL: url, isRetry: true)
            XCTAssertTrue(channel.hasOpenSystemFile)
            XCTAssertNotNil(channel.systemWriter)
            XCTAssertTrue(channel.systemDegraded)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    // MARK: - Item 4: both stops bounded and evented

    /// The loss path's stop through the helper it calls, with a stop that never returns.
    func test_aLossPathStopThatNeverReturnsIsEventedWithPathLoss() async throws {
        try await withScratchLogs { dir in
            let began = Date()
            let finished = await SystemAudioChannel.boundedCaptureStop(path: .loss, seconds: 0.2) {
                try? await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
            }
            XCTAssertFalse(finished)
            XCTAssertLessThan(Date().timeIntervalSince(began), 5.0, "the caller stops waiting at the budget")
            let rows = rows(in: dir, action: "system_capture_stop_timed_out")
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?["path"] as? String, "loss")
            XCTAssertEqual(rows.first?["category"] as? String, "recorder")
        }
    }

    func test_theHaltPathStopTimeoutCarriesPathStop() async throws {
        try await withScratchLogs { dir in
            let finished = await SystemAudioChannel.boundedCaptureStop(path: .stop, seconds: 0.2) {
                try? await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
            }
            XCTAssertFalse(finished)
            XCTAssertEqual(rows(in: dir, action: "system_capture_stop_timed_out").first?["path"] as? String, "stop")
        }
    }

    func test_aStopThatReturnsInTimeIsNotEvented() async throws {
        try await withScratchLogs { dir in
            let finished = await SystemAudioChannel.boundedCaptureStop(path: .loss, seconds: 5) {}
            XCTAssertTrue(finished)
            XCTAssertTrue(rows(in: dir, action: "system_capture_stop_timed_out").isEmpty)
        }
    }

    // MARK: - Wiring fences

    /// The gate is set under the lock before anything in `stop()` is awaited.
    func test_stopSetsTheDeliveryGateBeforeAwaitingStopCapture() throws {
        let text = try daemonSource("Sources/MeetingPipe/SystemAudioCapture.swift")
        let body = try XCTUnwrap(Self.body(of: "func stop() async", in: text))
        let gate = try XCTUnwrap(body.range(of: "attempt.stopDelivery()"), "stop() has to set the delivery gate")
        let await_ = try XCTUnwrap(body.range(of: "try await live.stopCapture()"))
        XCTAssertLessThan(gate.lowerBound, await_.lowerBound)
        let lock = try XCTUnwrap(body.range(of: "withStartLock {"))
        XCTAssertLessThan(lock.lowerBound, gate.lowerBound, "under the start lock, beside the ledger it belongs to")
    }

    func test_theDeliveryCallbackConsultsTheStopGate() throws {
        let text = try daemonSource("Sources/MeetingPipe/SystemAudioCapture.swift")
        let body = try XCTUnwrap(Self.body(of: "didOutputSampleBuffer sampleBuffer: CMSampleBuffer", in: text))
        let gate = try XCTUnwrap(body.range(of: "guard deliversBuffers else { return }"))
        let deliver = try XCTUnwrap(body.range(of: "onBuffer(pcm)"))
        XCTAssertLessThan(gate.lowerBound, deliver.lowerBound)
        // The host reads the pure ledger's answer, the one the tests above pin, under one lock.
        XCTAssertTrue(text.contains("private var deliversBuffers: Bool { withStartLock { attempt.deliversBuffers } }"))
    }

    /// The closure asks before it counts, stamps or enqueues; the old `systemFile != nil` alone
    /// let any capture through.
    func test_theBufferClosureAsksForItsGenerationBeforeCountingAnything() throws {
        let text = try daemonSource("Sources/MeetingPipe/SystemAudioChannel.swift")
        let check = try XCTUnwrap(text.range(of: "guard let self = self, self.acceptsBuffer(from: generation) else { return }"))
        let count = try XCTUnwrap(text.range(of: "self.systemFires &+= 1"))
        XCTAssertLessThan(check.lowerBound, count.lowerBound)
        XCTAssertFalse(text.contains("guard let self = self, self.systemFile != nil else { return }"))
    }

    /// Both stop sites refuse the capture's buffers, then stop it through the one bounded helper
    /// with their own path. The loss path's `Task` cannot be driven headlessly (no injectable
    /// capture), so it is fenced here and the helper is driven above.
    func test_bothStopSitesInvalidateFirstThenStopBoundedWithTheirPath() throws {
        let text = try daemonSource("Sources/MeetingPipe/SystemAudioChannel.swift")
        for (signature, call) in [
            ("func haltCapture() async", "await Self.boundedCaptureStop(path: .stop) { await capture?.stop() }"),
            ("func handleSystemAudioLost(", "Task { await SystemAudioChannel.boundedCaptureStop(path: .loss) { await dying.stop() } }"),
        ] {
            let body = try XCTUnwrap(Self.body(of: signature, in: text), signature)
            let invalidate = try XCTUnwrap(body.range(of: "invalidateCaptureGeneration()"), signature)
            let stop = try XCTUnwrap(body.range(of: call), "\(signature) has to stop through the bounded helper")
            XCTAssertLessThan(invalidate.lowerBound, stop.lowerBound, signature)
        }
        XCTAssertFalse(text.contains("Task { await dying.stop() }"), "the unbounded, unevented loss stop is gone")
        XCTAssertEqual(text.components(separatedBy: "action: \"system_capture_stop_timed_out\"").count - 1, 1,
                       "one emitter, in the helper, so both paths carry `path`")
    }

    /// The outcome is applied on the main actor, from the start Task, and nowhere else touches the
    /// file or writer from that Task.
    func test_theStartOutcomeIsAppliedOnMain() throws {
        let text = try daemonSource("Sources/MeetingPipe/SystemAudioChannel.swift")
        XCTAssertTrue(text.contains("@MainActor\n    func applyStartOutcome(_ outcome: SystemCaptureStartOutcome"))
        XCTAssertTrue(text.contains("await self?.applyStartOutcome(outcome, to: armed, systemURL: systemURL, isRetry: isRetry)"))
        XCTAssertFalse(text.contains("self?.systemFile = nil"), "the pool-side writes REC28 moved onto main")
        XCTAssertFalse(text.contains("self?.systemDegraded"))
    }

    // MARK: - Helpers

    /// A channel whose system WAV lives in a scratch directory, closed and removed afterwards.
    @MainActor
    private func withScratchChannel(_ body: (SystemAudioChannel, URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-rec28-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let channel = SystemAudioChannel()
        defer {
            _ = channel.finishWriterForTermination(timeout: 2)
            channel.dropCaptureForTermination()
            try? FileManager.default.removeItem(at: dir)
        }
        try await body(channel, dir.appendingPathComponent("rec28.system.wav"))
    }

    /// Point `Log` at a scratch directory so these read back exactly the rows they wrote.
    private func withScratchLogs(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-rec28-logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", dir.path, 1)
        defer {
            unsetenv("MEETINGPIPE_LOGS_DIR")
            try? FileManager.default.removeItem(at: dir)
        }
        try await body(dir)
    }

    private func rows(in dir: URL, action: String) -> [[String: Any]] {
        let events = dir.appendingPathComponent("events.jsonl")
        guard let text = try? String(contentsOf: events, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["action"] as? String == action else { return nil }
            return object
        }
    }

    private func daemonSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The brace-matched body of the first declaration containing `signature`. The files fenced
    /// here put no brace inside a string literal or comment in these functions.
    static func body(of signature: String, in text: String) -> Substring? {
        guard let head = text.range(of: signature),
              let open = text[head.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var i = open
        while i < text.endIndex {
            if text[i] == "{" { depth += 1 }
            if text[i] == "}" {
                depth -= 1
                if depth == 0 { return text[open...i] }
            }
            i = text.index(after: i)
        }
        return nil
    }
}
