import XCTest
@testable import MeetingPipe

/// REC27: a wedged `AVAudioEngine` survived a timed-out teardown or restart, and the next start,
/// wake or watchdog tick then called it synchronously on the main thread with no bound, so one
/// audio wedge could freeze the menu, the HUD and the hotkeys until a force-quit.
///
/// T7 source fence (deliberate): the fences below grep MeetingRecorder and InputDeviceRecovery for engine calls outside a bounded closure, the teardown's engine retirement and start()'s single exit. Missing seam: an injectable engine in MeetingRecorder; without one `start()` cannot get past its first engine call headless and `stop()` cannot get past its first guard, and the claim "no engine call runs unbounded" is about the source text itself (CI has no live AVAudioEngine to wedge). The behavioural halves run against the fake host in `InputDeviceRecoveryTests` and against the real recorder's fail-fast path here.
final class EngineCallBoundsREC27Tests: XCTestCase {

    // MARK: - Item 2: no engine call on the main thread

    /// Every engine call in the recorder and its recovery sits inside a closure handed to one of
    /// the bounded helpers. Red against the code REC27 started from, where `buildMicChain`, the
    /// wake handler, the watchdog's `isRunning` read, `liveInputFormat`, `replaceCondemnedEngine`
    /// and the failed-start unwind all called the engine directly on main.
    func test_everyEngineCallSitsInsideABoundedClosure() throws {
        var unbounded: [String] = []
        for path in ["Sources/MeetingPipe/MeetingRecorder.swift", "Sources/MeetingPipe/InputDeviceRecovery.swift"] {
            let code = SwiftSourceScan.codeOnly(try daemonSource(path))
            for token in Self.engineCallTokens {
                for offset in SwiftSourceScan.occurrences(of: token, in: code)
                where !SwiftSourceScan.isInsideBoundedClosure(offset, in: code, allowed: Self.boundedHelpers) {
                    unbounded.append("\(path):\(SwiftSourceScan.lineNumber(of: offset, in: code)) \(token)")
                }
            }
        }
        XCTAssertEqual(
            unbounded, [],
            "each of these calls the audio engine without a bound. A wedged engine queue blocks every "
                + "such call, and on main that freezes the whole app (REC27, the 2026-06-12 start wedge)."
        )
    }

    /// `engineCall` is on the allowlist only because it is a wrapper over `runBlockingWithTimeout`;
    /// the day it stops being one, the fence above stops meaning anything.
    func test_theRecordersEngineCallHelperIsItselfBounded() throws {
        let code = String(SwiftSourceScan.codeOnly(try daemonSource("Sources/MeetingPipe/MeetingRecorder.swift")))
        let body = try XCTUnwrap(
            code.components(separatedBy: "private func engineCall<").dropFirst().first?
                .components(separatedBy: "\n    }\n").first,
            "the recorder's one bounded engine-call helper is missing"
        )
        XCTAssertTrue(body.contains("runBlockingWithTimeout("), "engineCall has to bound its call off main")
        XCTAssertTrue(body.contains("noteAbandoned(site:"), "a timed-out call has to be counted toward the cap")
        XCTAssertTrue(body.contains("abandonedCalls.isExhausted"), "past the cap the helper issues nothing")
    }

    /// The fence is only worth its name if it can see an unbounded call, so pin the scanner on
    /// the shapes the recorder actually uses: a trailing closure, a closure argument, a nested
    /// closure, and the three places a token must not count (a comment, a string, a bare call).
    func test_theScannerTellsABoundedCallFromABareOne() {
        let source = """
        func a() {
            engine.stop()
            // engine.stop() in a comment
            Log.writeLine("recorder", "engine.stop() in a string \\(x.joined(separator: ",")) still")
            _ = await runBlockingWithTimeout(seconds: 1) { [engine] in engine.stop() }
            let t = await EngineTeardown.run(
                removeTap: { [engine] in engine.inputNode.removeTap(onBus: 0) },
                stop: { [engine] in engine.stop() },
                revertVoiceProcessing: nil
            )
            _ = await engineCall(site: "x") { engine in
                GuardedTapInstall.install(format: f, site: "s", engine: engine) {
                    engine.inputNode.installTap(onBus: 0, bufferSize: 1, format: f) { _, _ in }
                }
            }
            let later = { [engine] in engine.stop() }
        }
        """
        let code = SwiftSourceScan.codeOnly(source)
        let verdicts = Self.engineCallTokens.flatMap { token in
            SwiftSourceScan.occurrences(of: token, in: code).map {
                (SwiftSourceScan.lineNumber(of: $0, in: code), token,
                 SwiftSourceScan.isInsideBoundedClosure($0, in: code, allowed: Self.boundedHelpers))
            }
        }.sorted { $0.0 < $1.0 }
        XCTAssertEqual(verdicts.map { "\($0.0) \($0.1) \($0.2)" }, [
            "2 engine.stop() false",
            "5 engine.stop() true",
            "7 removeTap( true",
            "8 engine.stop() true",
            "13 installTap( true",
            "16 engine.stop() false",
        ])
    }

    // MARK: - Item 1: a timeout condemns the engine

    /// A stop whose teardown timed out used to only log `engine_teardown_timed_out` and hand the
    /// same engine to the next meeting's `start()`. Pinned on the source because `stop()` cannot
    /// run headless past its first guard (see the class doc); `replaceEngine(reason:)` is what makes
    /// the next start bind a different instance.
    func test_aTimedOutTeardownRetiresTheEngine() throws {
        // The raw source, not `codeOnly`: the reason is a string literal, and that is what is pinned.
        let code = try daemonSource("Sources/MeetingPipe/MeetingRecorder.swift")
        let body = try XCTUnwrap(
            code.components(separatedBy: "private func teardownEngine() async {").dropFirst().first?
                .components(separatedBy: "\n    }\n").first
        )
        let notClean = try XCTUnwrap(body.range(of: "if !teardown.isClean {"), "the timeout branch is missing")
        XCTAssertNotNil(
            body.range(of: "replaceEngine(reason: \"teardown_timed_out\")", range: notClean.upperBound..<body.endIndex),
            "a timed-out teardown has to retire the engine, or the next start() calls the wedged one on main"
        )
    }

    /// Retiring an engine whose `stop()` timed out leaves an instance whose IO may still be
    /// rendering. Its tap must not write into the mic file beside the replacement's, so every swap
    /// bumps a generation and the render path drops a buffer from an older one. Fenced for the same
    /// missing seam: no headless engine to render from.
    func test_aRetiredEnginesTapCannotWriteBesideItsReplacement() throws {
        let code = try daemonSource("Sources/MeetingPipe/MeetingRecorder.swift")
        let replace = try XCTUnwrap(
            code.components(separatedBy: "private func replaceEngine(reason: String) {").dropFirst().first?
                .components(separatedBy: "\n    }\n").first
        )
        XCTAssertTrue(replace.contains("$0.engineGeneration &+= 1"), "every swap has to start a new generation")
        let process = try XCTUnwrap(
            code.components(separatedBy: "private func processMicBuffer(_ rawBuffer: AVAudioPCMBuffer, tapGeneration: UInt64) {")
                .dropFirst().first
        )
        let firstLine = process.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertEqual(
            firstLine?.trimmingCharacters(in: .whitespaces),
            "guard gateAccess.withLock({ $0.engineGeneration }) == tapGeneration else { return }",
            "the generation check has to come before anything touches the file or the counters"
        )
    }

    // MARK: - Item 4: one exit for every failed start

    /// Every throwing exit after the capture-mode marker is written goes through one catch, and
    /// that catch removes the marker and reverts voice processing. The behavioural half is the
    /// fail-fast test below, which throws from inside that block and finds no marker.
    func test_startHasOneExitAfterTheMarkerIsWritten() throws {
        let code = String(SwiftSourceScan.codeOnly(try daemonSource("Sources/MeetingPipe/MeetingRecorder.swift")))
        let start = try XCTUnwrap(
            code.components(separatedBy: "func start(outputDir: URL, captureMode: CaptureMode, voiceProcessing: Bool = false) async throws -> URL {")
                .dropFirst().first?.components(separatedBy: "\n    }\n").first
        )
        let afterMarker = try XCTUnwrap(
            start.components(separatedBy: "try? captureMode.marker.write(").dropFirst().first,
            "the marker write moved; re-read this fence against the new start()"
        )
        XCTAssertEqual(afterMarker.components(separatedBy: "throw ").count - 1, 1, "the one throw after the marker is the catch's rethrow")
        XCTAssertTrue(afterMarker.contains("} catch {"))
        XCTAssertTrue(afterMarker.contains("await unwindFailedStart(markerURL: modeMarkerURL, micURL: micURL)"))
        XCTAssertTrue(afterMarker.contains("throw error"))

        let unwind = try XCTUnwrap(
            code.components(separatedBy: "private func unwindFailedStart(markerURL: URL, micURL: URL) async {")
                .dropFirst().first?.components(separatedBy: "\n    }\n").first
        )
        XCTAssertTrue(unwind.contains("removeItem(at: markerURL)"))
        XCTAssertTrue(
            unwind.contains("if voiceProcessingEnabledForSession {"),
            "a start that enabled voice processing and then threw has to revert it (the 2026-05-13 symptom)"
        )
    }

    // MARK: - Item 3: the abandoned-call cap

    func test_theCountRisesOnEachAbandonmentAndEmitsOneRowEach() throws {
        try withScratchLogs { dir in
            let calls = AbandonedEngineCalls(threshold: 8)
            calls.record(site: "teardown_remove_tap")
            calls.record(site: "tap_watchdog_read")
            XCTAssertEqual(calls.count, 2)

            let rows = try rows(in: dir, action: "engine_call_abandoned")
            XCTAssertEqual(rows.map { $0["site"] as? String }, ["teardown_remove_tap", "tap_watchdog_read"])
            XCTAssertEqual(rows.map { $0["abandoned_total"] as? Int }, [1, 2])
            XCTAssertEqual(rows.map { $0["category"] as? String }, ["recorder", "recorder"])
        }
    }

    /// Refusal starts at the threshold, not one past it, and the crossing is reported exactly
    /// once so the owner gets one notice rather than one per later abandonment.
    func test_refusalStartsAtTheThresholdAndTheCrossingIsReportedOnce() {
        let calls = AbandonedEngineCalls(threshold: 3)
        XCTAssertFalse(calls.record(site: "a"))
        XCTAssertFalse(calls.record(site: "b"))
        XCTAssertFalse(calls.isExhausted, "one short of the threshold still issues calls")
        XCTAssertTrue(calls.record(site: "c"), "the abandonment that reaches the threshold is the crossing")
        XCTAssertTrue(calls.isExhausted)
        XCTAssertFalse(calls.record(site: "d"), "and it is reported once")
        XCTAssertTrue(calls.isExhausted)

        XCTAssertFalse(AbandonedEngineCalls.isExhausted(total: 7, threshold: 8))
        XCTAssertTrue(AbandonedEngineCalls.isExhausted(total: 8, threshold: 8))
    }

    /// The threshold is argued in its doc comment: a small multiple of what one wedge now costs,
    /// and far below GCD's ~64-thread pool. Pinned so a change to it is a decision, not a drift.
    func test_theDefaultThresholdIsTwoWedgesAndFarBelowThePool() {
        XCTAssertEqual(AbandonedEngineCalls.defaultThreshold, 8)
        XCTAssertLessThanOrEqual(AbandonedEngineCalls.defaultThreshold * 4, 64)
    }

    /// Past the cap a start fails fast with the typed error, leaves no capture-mode marker (it
    /// throws from inside `start()`'s one catch, so this is also the behavioural half of item 4),
    /// and records nothing. It never reaches the engine: the check is the first statement of
    /// `startMicCapture`, ahead of every engine call, which CI (no input device) would otherwise
    /// trip over.
    @MainActor
    func test_aStartPastTheCapFailsFastWithTheTypedErrorAndLeavesNoMarker() async throws {
        let calls = AbandonedEngineCalls(threshold: 1)
        calls.record(site: "test")
        let recorder = MeetingRecorder(abandonedCalls: calls)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-rec27-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            _ = try await recorder.start(outputDir: dir, captureMode: .captureFirstRedact)
            XCTFail("a start past the cap has to throw")
        } catch MeetingRecorder.RecorderError.engineCallsExhausted(let count) {
            XCTAssertEqual(count, 1)
        }

        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(left.filter { $0.hasSuffix(".capturemode") }, [], "the marker is removed on a failed start")
        XCTAssertEqual(left, [])
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(calls.count, 1, "refusing is not abandoning")
        XCTAssertEqual(
            MeetingSessionController.startFailureReason(MeetingRecorder.RecorderError.engineCallsExhausted(1)),
            "engine_calls_exhausted"
        )
    }

    // MARK: - Helpers

    /// Point `Log` at a scratch directory so these read back exactly the rows they wrote.
    private func withScratchLogs(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-rec27-logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", dir.path, 1)
        defer {
            unsetenv("MEETINGPIPE_LOGS_DIR")
            try? FileManager.default.removeItem(at: dir)
        }
        try body(dir)
    }

    private func rows(in dir: URL, action: String) throws -> [[String: Any]] {
        let events = dir.appendingPathComponent("events.jsonl")
        guard let text = try? String(contentsOf: events, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["action"] as? String == action else { return nil }
            return object
        }
    }

    /// The calls the acceptance names. `.isRunning`, `.start()` and `.stop()` are written with
    /// the receiver because both files call `start()` / `stop()` on things that are not engines.
    static let engineCallTokens = [
        "setVoiceProcessingEnabled(", "outputFormat(forBus:", "installTap(", "removeTap(",
        "engine.isRunning", "engine.start()", "engine.stop()",
    ]

    /// The bounded shapes. `engineCall` is the recorder's wrapper over `runBlockingWithTimeout`
    /// that also counts abandonments; `test_theRecordersEngineCallHelperIsItselfBounded` keeps it
    /// honest.
    static let boundedHelpers: Set<String> = [
        "runBlockingWithTimeout", "runBoundedSync", "boundedEngineStart",
        "EngineTeardown.run", "EngineTeardown.runSync", "engineCall",
    ]

    private func daemonSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

/// Just enough of a Swift lexer for the REC27 fence: blank comments and string literals (offsets
/// kept, so line numbers survive) and decide whether an offset sits inside a closure handed to a
/// named call.
enum SwiftSourceScan {

    static func codeOnly(_ source: String) -> [Character] {
        let chars = Array(source)
        var out = chars
        func blank(_ from: Int, _ to: Int) {
            for k in from..<min(to, out.count) where out[k] != "\n" { out[k] = " " }
        }
        var i = 0
        while i < chars.count {
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if chars[i] == "/", next == "/" {
                var j = i
                while j < chars.count, chars[j] != "\n" { j += 1 }
                blank(i, j)
                i = j
            } else if chars[i] == "/", next == "*" {
                var j = i + 2
                while j + 1 < chars.count, !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
                blank(i, j + 2)
                i = j + 2
            } else if chars[i] == "\"" {
                let j = endOfString(chars, from: i)
                blank(i, j)
                i = j
            } else {
                i += 1
            }
        }
        return out
    }

    /// One past the closing quote of the literal opening at `start`.
    private static func endOfString(_ chars: [Character], from start: Int) -> Int {
        let isTriple = start + 2 < chars.count && chars[start + 1] == "\"" && chars[start + 2] == "\""
        var j = start + (isTriple ? 3 : 1)
        while j < chars.count {
            if chars[j] == "\\" {
                if j + 1 < chars.count, chars[j + 1] == "(" {
                    j = endOfInterpolation(chars, from: j + 2)
                } else {
                    j += 2
                }
                continue
            }
            if chars[j] == "\"" {
                if !isTriple { return j + 1 }
                if j + 2 < chars.count, chars[j + 1] == "\"", chars[j + 2] == "\"" { return j + 3 }
            }
            j += 1
        }
        return chars.count
    }

    private static func endOfInterpolation(_ chars: [Character], from start: Int) -> Int {
        var depth = 1
        var k = start
        while k < chars.count {
            switch chars[k] {
            case "\"": k = endOfString(chars, from: k); continue
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return k + 1 }
            default: break
            }
            k += 1
        }
        return chars.count
    }

    static func occurrences(of token: String, in code: [Character]) -> [Int] {
        let needle = Array(token)
        guard !needle.isEmpty, code.count >= needle.count else { return [] }
        var found: [Int] = []
        for i in 0...(code.count - needle.count) where Array(code[i..<(i + needle.count)]) == needle {
            found.append(i)
        }
        return found
    }

    static func lineNumber(of offset: Int, in code: [Character]) -> Int {
        code[..<offset].filter { $0 == "\n" }.count + 1
    }

    /// Whether any closure enclosing `offset` is a closure argument (or the trailing closure) of a
    /// call whose name is in `allowed`.
    static func isInsideBoundedClosure(_ offset: Int, in code: [Character], allowed: Set<String>) -> Bool {
        var k = offset - 1
        var depth = 0
        while k >= 0 {
            if code[k] == "}" {
                depth += 1
            } else if code[k] == "{" {
                if depth > 0 {
                    depth -= 1
                } else if opensClosureOfAllowedCall(k, in: code, allowed: allowed) {
                    return true
                }
            }
            k -= 1
        }
        return false
    }

    private static func opensClosureOfAllowedCall(_ brace: Int, in code: [Character], allowed: Set<String>) -> Bool {
        // Trailing closure: `name(args) {`.
        var k = brace - 1
        while k >= 0, code[k].isWhitespace { k -= 1 }
        if k >= 0, code[k] == ")", let open = matchingOpenParen(k, in: code),
           allowed.contains(identifier(endingBefore: open, in: code)) {
            return true
        }
        // Closure argument: walk out through the enclosing argument lists, stopping at the block
        // the closure literal sits in.
        k = brace - 1
        var parens = 0
        var braces = 0
        while k >= 0 {
            let c = code[k]
            if c == "}" {
                braces += 1
            } else if c == "{" {
                if braces == 0 { return false }
                braces -= 1
            } else if braces == 0 {
                if c == ")" {
                    parens += 1
                } else if c == "(" {
                    if parens > 0 {
                        parens -= 1
                    } else if allowed.contains(identifier(endingBefore: k, in: code)) {
                        return true
                    }
                }
            }
            k -= 1
        }
        return false
    }

    private static func matchingOpenParen(_ close: Int, in code: [Character]) -> Int? {
        var depth = 0
        var k = close
        while k >= 0 {
            if code[k] == ")" { depth += 1 }
            if code[k] == "(" {
                depth -= 1
                if depth == 0 { return k }
            }
            k -= 1
        }
        return nil
    }

    private static func identifier(endingBefore index: Int, in code: [Character]) -> String {
        var k = index - 1
        var name: [Character] = []
        while k >= 0, code[k].isLetter || code[k].isNumber || code[k] == "_" || code[k] == "." {
            name.insert(code[k], at: 0)
            k -= 1
        }
        return String(name)
    }
}
