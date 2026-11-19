import Darwin
import Foundation
import os

enum Log {
    static let main = Logger(subsystem: Endpoints.logSubsystem, category: "main")
    static let detector = Logger(subsystem: Endpoints.logSubsystem, category: "detector")
    static let recorder = Logger(subsystem: Endpoints.logSubsystem, category: "recorder")

    /// The resolved logs directory, created the first time each resolution is seen.
    ///
    /// Resolved per call, never frozen: eleven test files `setenv("MEETINGPIPE_LOGS_DIR", ...)`
    /// mid-process and rely on the next line going to the new directory (PERF13). What is no
    /// longer per call is the cost around it: the variables are read with `getenv` rather than
    /// by building `ProcessInfo.processInfo.environment`, `isRunningUnderTests` is memoized, and
    /// a directory already created is not `createDirectory`'d again on every line. A directory
    /// removed after that (a test's `tearDown`) is recreated by the append's ENOENT retry.
    static var logsDir: URL {
        let dir = resolveLogsDir()
        ensureDirectory(dir.path)
        return dir
    }

    /// Resolve the logs directory. An explicit `MEETINGPIPE_LOGS_DIR` wins (sandboxed
    /// runs, targeted tests); otherwise, under XCTest we redirect to a temp dir so
    /// `swift test` never appends fixture rows (clip.wav, stem "m", "Boom error",
    /// notion.example) into the user's production events.jsonl, which would corrupt
    /// every events-log consumer (`mp analyze-detection`, dogfood reports). Matches the
    /// existing MEETINGPIPE_FFMPEG / MEETING_PIPE_DRY_RUN env-override convention.
    private static func resolveLogsDir() -> URL {
        if let override = env("MEETINGPIPE_LOGS_DIR"), !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if isRunningUnderTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("MeetingPipe-test-logs", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(Endpoints.Paths.logsRelative, isDirectory: true)
    }

    /// One environment variable, without copying the whole environment into a dictionary.
    private static func env(_ name: String) -> String? {
        getenv(name).map { String(cString: $0) }
    }

    /// True when the process is hosting an XCTest bundle. Checks the runner env vars
    /// first, then falls back to the loaded `XCTestCase` class so the guard holds even
    /// if a future toolchain stops exporting them. The production app never links XCTest.
    /// Memoized (PERF13): whether XCTest is loaded cannot change within a process, and the
    /// production answer used to be an `NSClassFromString` lookup on every line.
    static let isRunningUnderTests: Bool = {
        if getenv("XCTestConfigurationFilePath") != nil
            || getenv("XCTestBundlePath") != nil
            || getenv("XCTestSessionIdentifier") != nil {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }()

    /// Append-only tail-able log file (logging conventions in CONVENTIONS.md). os.Logger goes to the unified log; this writes ~/Library/Logs/MeetingPipe/<category>.log.
    static func writeLine(_ category: String, _ message: String) {
        writeLine(category, message, at: Date())
    }

    /// OBS6: the Verbose logging toggle's own key (`UISettings.verboseLogging` writes it).
    static let verboseDefaultsKey = "mp.ui.verboseLogging"

    /// The live toggle, read from `UserDefaults`, which is safe off main where the scanner runs.
    static func isVerbose() -> Bool { UserDefaults.standard.bool(forKey: verboseDefaultsKey) }

    /// OBS6: narration at a decision point, written to `<category>.log` only while Verbose logging
    /// is on. Files, not os.Logger, because macOS does not persist debug lines. Never a failure
    /// (those stay unconditional) and never a title, a name or transcript text.
    static func verbose(_ category: String, _ message: @autoclosure () -> String, enabled: () -> Bool = Log.isVerbose) {
        guard enabled() else { return }
        writeLine(category, "verbose: \(message())")
    }

    private static func writeLine(_ category: String, _ message: String, at date: Date) {
        let url = logsDir.appendingPathComponent("\(category).log")
        let line = "[\(ISO8601.format(date, fractional: true))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        append(data, to: url)
    }

    /// One serial queue for log lines whose caller must not wait on `append`'s process-wide lock, its
    /// rotation check and its open/write/close (CONC6): the first-buffer lines inside the capture callbacks.
    private static let asyncWriteQueue = DispatchQueue(label: "com.meetingpipe.log.async", qos: .utility)

    /// `writeLine` handed to a utility queue, with the timestamp taken now, so the line reads as the
    /// moment it was written and not the moment the queue got to it. For a capture thread.
    static func writeLineAsync(_ category: String, _ message: String) {
        let now = Date()
        asyncWriteQueue.async { writeLine(category, message, at: now) }
    }

    /// Blocks until every `writeLineAsync` queued before this call is on disk. For tests.
    static func drainAsyncWrites() { asyncWriteQueue.sync {} }

    // MARK: - Failures (OBS1)

    /// The cap on a failure row's `error` text, matching PIPE19's `stage_failed` `message`.
    static let failureDescriptionCap = 300

    /// A failure is never os.Logger alone (OBS1): the unified log stores the reason as
    /// `<private>`, keeps about a week, and is not what Diagnostics, `mp logs` or `mp doctor`
    /// read. This writes an `events.jsonl` row (the caller's attributes plus `error`,
    /// `error_domain`, `error_code`), a `<file>.log` sentence, and one os.Logger `.error` whose
    /// action, domain and code are public and whose description stays private.
    ///
    /// `describe: false` keeps the description out of both files, leaving domain and code,
    /// for an error whose text can quote meeting content (SEC38): a path the owner named.
    static func failure(
        category: String,
        action: String,
        error: Error,
        attributes: [String: Any] = [:],
        file: String = "daemon",
        describe: Bool = true
    ) {
        let ns = error as NSError
        record(
            category: category, action: action,
            description: describe ? ns.localizedDescription : nil,
            domain: ns.domain, code: ns.code,
            attributes: attributes, file: file
        )
    }

    /// A failure with no `Error` to bridge (`mp` not found, a watchdog's kill): the same row,
    /// with `reason` as the description and no domain or code.
    static func failure(
        category: String,
        action: String,
        reason: String,
        attributes: [String: Any] = [:],
        file: String = "daemon"
    ) {
        record(
            category: category, action: action, description: reason,
            domain: nil, code: nil, attributes: attributes, file: file
        )
    }

    private static func record(
        category: String,
        action: String,
        description: String?,
        domain: String?,
        code: Int?,
        attributes: [String: Any],
        file: String
    ) {
        var attributes = attributes
        let text = description.map { capped($0) }
        if let text { attributes["error"] = text }
        if let domain { attributes["error_domain"] = domain }
        if let code { attributes["error_code"] = code }
        event(category: category, action: action, attributes: attributes)

        let codeTag = domain.map { " [\($0) \(code ?? 0)]" } ?? ""
        writeLine(file, "\(action): \(text ?? "(description withheld)")\(codeTag)")

        let logger = file == "recorder" ? recorder : main
        let publicDomain = domain ?? "-"
        let publicCode = code ?? 0
        logger.error("\(action, privacy: .public) [\(publicDomain, privacy: .public) \(publicCode, privacy: .public)]: \(text ?? "")")
    }

    private static func capped(_ text: String) -> String {
        guard text.count > failureDescriptionCap else { return text }
        return String(text.prefix(failureDescriptionCap - 1)) + "…"
    }

    /// Write one JSON object per line to `events.jsonl` for `jq`-based post-hoc analysis.
    ///
    /// A value JSON cannot hold is coerced rather than dropping the event (PERF13), matching
    /// Python's `default=str`: a `URL`, `Date`, `UUID` or any other object is written as its
    /// string form, and a non-finite `Double` as `null` with a sibling `<key>_invalid: true`.
    /// It used to return without writing, so one stray attribute silently lost the whole row.
    static func event(
        category: String,
        action: String,
        attributes: [String: Any] = [:]
    ) {
        guard let line = eventLine(category: category, action: action, attributes: attributes) else { return }
        append(line, to: logsDir.appendingPathComponent("events.jsonl"))
    }

    /// OBS9: the diagnostics family. A high-volume row whose only use is investigating a storm (HAL
    /// subscribe churn, process-audio resolution, a teardown source missing) goes to
    /// `diagnostics.jsonl`, same envelope as `event`, so it can no longer rotate lifecycle,
    /// recorder and pipeline rows out of `events.jsonl`: three such families were 79.5 percent of
    /// its bytes and held its history to 46 days. The family keeps `diagnosticGenerations`
    /// rotated files, fewer than `events.jsonl`; it is allowed to be short.
    static func diagnostic(
        category: String,
        action: String,
        attributes: [String: Any] = [:]
    ) {
        guard let line = eventLine(category: category, action: action, attributes: attributes) else { return }
        append(line, to: logsDir.appendingPathComponent(diagnosticsFile), generations: diagnosticGenerations)
    }

    static let diagnosticsFile = "diagnostics.jsonl"
    /// The resident agent's `StandardErrorPath` and `StandardOutPath`
    /// (`scripts/launchd.plist.template`), which launchd writes and nothing else bounds; rotated at
    /// launch (OBS9).
    static let launchdOwnedLogs = ["launchd.err.log", "launchd.out.log"]
    static let diagnosticGenerations = 1

    /// One JSON line with the shared envelope (`ts`, `category`, `action`), or nil when it
    /// cannot be encoded even after coercion.
    private static func eventLine(category: String, action: String, attributes: [String: Any]) -> Data? {
        var dict: [String: Any] = attributes
        dict["ts"] = ISO8601.format(Date(), fractional: true)
        dict["category"] = category
        dict["action"] = action
        // OBS5: every row names the process that wrote it, so a launch's rows group without
        // timestamp arithmetic and a row from before a crash cannot be read as after it.
        dict["launch_id"] = LaunchRecord.launchID
        // The common case is already valid, so it never pays for the walk. The re-check after
        // coercion is load-bearing: `JSONSerialization.data` raises an Objective-C exception,
        // not a Swift error, on a value it cannot encode, and that would take the daemon down.
        let payload = JSONSerialization.isValidJSONObject(dict) ? dict : coerced(dict)
        guard JSONSerialization.isValidJSONObject(payload),
              let json = try? JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            return nil
        }
        var line = json
        line.append(0x0A) // newline
        return line
    }

    /// `attributes` with every value JSON cannot hold replaced by one it can. A top-level
    /// non-finite number also gains a `<key>_invalid: true` sibling, so a `null` that was a
    /// NaN stays distinguishable from a value that was genuinely absent.
    static func coerced(_ attributes: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in attributes {
            if isNonFiniteNumber(value) {
                out[key] = NSNull()
                out["\(key)_invalid"] = true
            } else {
                out[key] = coercedValue(value)
            }
        }
        return out
    }

    private static func coercedValue(_ value: Any) -> Any {
        // An `Optional` boxed in `Any` is invalid JSON whether or not it holds a value.
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return NSNull() }
            return coercedValue(wrapped)
        }
        switch value {
        case is String, is NSNull:
            return value
        case let number as NSNumber:
            return isNonFiniteNumber(number) ? NSNull() : number
        case let array as [Any]:
            return array.map(coercedValue)
        case let dict as [String: Any]:
            return coerced(dict)
        case let date as Date:
            return ISO8601.format(date, fractional: true)
        case let url as URL:
            // A file URL reads as its path, the way Python's `str(Path)` does.
            return url.isFileURL ? url.path : url.absoluteString
        case let uuid as UUID:
            return uuid.uuidString
        default:
            return String(describing: value)
        }
    }

    /// A `Double` or `Float` that is NaN or infinite. `Bool` and the integer types bridge to
    /// `NSNumber` too, so this reads the boxed type rather than `doubleValue`.
    private static func isNonFiniteNumber(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        let type = String(cString: number.objCType)
        guard type == "d" || type == "f" else { return false }
        return !number.doubleValue.isFinite
    }

    // MARK: - Appending (PERF13)

    /// What the one write lock guards besides the files themselves.
    private struct WriterState {
        /// Directories this process has already created, so `logsDir` skips the syscall.
        var createdDirectories: Set<String> = []
        /// Log families (a base file name) whose failed append has already been reported.
        var reportedFailures: Set<String> = []
    }

    /// Every append, rotation and first-create in this process goes through this one lock.
    ///
    /// The logger used to have none, while about 385 call sites reach it from main, the audio
    /// writer queues, GCD workers and pipe readers. It opened a `FileHandle` without
    /// `O_APPEND`, sought to the end and wrote, so two lines in the same millisecond sought to
    /// the same offset and the second overwrote the first; that is the one corrupt row in the
    /// owner's `events.jsonl` (a stop-cascade event half-overwritten on 2026-10-16). A missing
    /// file was `createFile`'d, which replaces what is there, and two threads could both pass
    /// the size check and rotate twice. The descriptor below is opened per write with
    /// `O_APPEND | O_CREAT`, so the kernel places each write at the end even when the other
    /// process writing this file (the `MeetingPipe doctor` CLI) appends at the same moment, and
    /// this lock makes check-rotate-append one step within the process.
    ///
    /// Writes stay synchronous on the caller's thread, so the unflushed tail on a crash is
    /// zero lines: a line is in the kernel when `event` or `writeLine` returns.
    /// `UncaughtExceptionLogger.record` and `AppDelegate.flushAndExit` rely on that, and so does
    /// every test that reads a log straight after emitting. At tens of microseconds a line and
    /// about 1 Hz, a queue would buy little and would need a drain at both exits.
    private static let writer = OSAllocatedUnfairLock(initialState: WriterState())

    private static func ensureDirectory(_ path: String) {
        if writer.withLock({ $0.createdDirectories.contains(path) }) { return }
        guard (try? FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true
        )) != nil else { return }
        writer.withLock { _ = $0.createdDirectories.insert(path) }
    }

    /// Append `data` to `url` as one locked, `O_APPEND` write, rotating first when the file
    /// has reached the size cap. `PipelineLauncher.runMP` writes `pipeline.log` through this
    /// too, one call per output chunk, so concurrent spawns and a rotation mid-run cannot
    /// overwrite or strand each other's bytes. Empty `data` just creates the file (0600).
    static func append(_ data: Data, to url: URL, generations: Int = maxLogGenerations) {
        let failure: Int32? = writer.withLock { _ in
            rotateLocked(url, generations: generations)
            return appendLocked(data, path: url.path)
        }
        if let failure { reportFailedAppend(url, errno: failure) }
    }

    /// The write itself, under `writer`. Returns the `errno` of a failure, nil on success.
    private static func appendLocked(_ data: Data, path: String) -> Int32? {
        // 0600: the event log and the tail logs carry verbatim meeting titles
        // and transcript-derived context, so they stay private to the user (SEC11).
        let flags = O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC
        var fd = open(path, flags, 0o600)
        if fd < 0, errno == ENOENT {
            // The directory went away after `logsDir` created it (a test's tearDown, a user
            // clearing the folder). Recreate it once rather than lose the line.
            let parent = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            fd = open(path, flags, 0o600)
        }
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        return data.withUnsafeBytes { raw -> Int32? in
            guard var base = raw.baseAddress else { return nil }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, base, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                remaining -= n
                base = base.advanced(by: n)
            }
            return nil
        }
    }

    /// One os.Logger `.error` per log family per launch, naming the path and the errno.
    /// OBS1's helper cannot report this: it writes through the very path that just failed.
    private static func reportFailedAppend(_ url: URL, errno code: Int32) {
        let family = url.lastPathComponent
        guard writer.withLock({ $0.reportedFailures.insert(family).inserted }) else { return }
        let path = url.path
        let reason = String(cString: strerror(code))
        main.error("log append failed: \(path, privacy: .public) errno \(code, privacy: .public) (\(reason, privacy: .public))")
    }

    /// The families whose failed append has been reported this launch. For the tests.
    static var reportedAppendFailures: Set<String> {
        writer.withLock { $0.reportedFailures }
    }

    // PERF7: size-based rename rotation so the event log and the tail logs
    // self-bound. `events.jsonl` grew to 63 MB / 338k lines on the dogfood Mac
    // (1 Hz ax/mute state for the whole of every meeting) with no trim.
    static let maxLogGenerations = 3
    private static var maxLogBytes: UInt64 {
        if let raw = env("MEETINGPIPE_LOG_MAX_BYTES"), let n = UInt64(raw) {
            return n
        }
        return 5 * 1024 * 1024
    }

    /// Rename-rotate `url` when it reaches the size cap. `url` -> `url.1`, shifting
    /// older generations up and dropping the oldest, so a log family self-bounds at
    /// ~`(maxLogGenerations + 1) * maxLogBytes`.
    ///
    /// Takes the same lock as `append`, which runs the locked half before every write, so
    /// two writers crossing the cap together rotate once: the second sees the fresh, small
    /// base file. That holds within this process only. A second process (the doctor CLI, or
    /// Python rotating `pipeline_events.jsonl`) can still race a rotation; what keeps the
    /// line there is that every writer opens per write with `O_APPEND | O_CREAT`, so a write
    /// after a rename lands in a new base file rather than at a stale offset in the old one.
    static func rotateIfNeeded(_ url: URL) {
        writer.withLock { _ in rotateLocked(url, generations: maxLogGenerations) }
    }

    private static func rotateLocked(_ url: URL, generations: Int) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              size >= maxLogBytes else { return }
        try? fm.removeItem(at: generationURL(url, generations))
        var k = generations - 1
        while k >= 1 {
            let src = generationURL(url, k)
            if fm.fileExists(atPath: src.path) {
                let dst = generationURL(url, k + 1)
                try? fm.removeItem(at: dst)
                try? fm.moveItem(at: src, to: dst)
            }
            k -= 1
        }
        let firstGen = generationURL(url, 1)
        try? fm.removeItem(at: firstGen)
        try? fm.moveItem(at: url, to: firstGen)
    }

    /// `events.jsonl` -> `events.1.jsonl`, `daemon.log` -> `daemon.2.log`. The index
    /// goes before the extension so a rotated file stays valid JSONL / a tail-able log.
    static func generationURL(_ url: URL, _ k: Int) -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let name = ext.isEmpty ? "\(stem).\(k)" : "\(stem).\(k).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// Existing log files for `url`, oldest first (base last / newest). A reader
    /// concatenating these sees the recent window across a rotation boundary.
    static func logGenerations(_ url: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        var k = maxLogGenerations
        while k >= 1 {
            let g = generationURL(url, k)
            if fm.fileExists(atPath: g.path) { out.append(g) }
            k -= 1
        }
        if fm.fileExists(atPath: url.path) { out.append(url) }
        return out
    }

    /// Best-effort one-time tightening of existing log files to 0600 (SEC11).
    /// New files are created 0600 by `append`; this closes the hole for logs
    /// that predate that change (they were created 0644). Call once at startup.
    static func tightenLogPermissions() {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: logsDir, includingPropertiesForKeys: nil
        ) else { return }
        for url in items where url.pathExtension == "jsonl" || url.pathExtension == "log" {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        }
    }
}
