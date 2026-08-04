import Foundation

/// Configuration record for a meeting client whose own diagnostic log carries mute transitions. One instance today (Teams); the shape is a data row for the same reason `NativeAppMuteConfig` is.
public struct LogMuteConfig {
    public let bundleIDs: Set<String>
    /// MuteLabels TOML app key, also the `micgate` event's surface tag.
    public let app: String
    /// Directory holding the client's diagnostic logs.
    public let directory: URL
    /// Filename prefix of the log **family** that carries the transition line.
    /// Never a mtime-only match over the directory: see `SlimCoreMuteLog.generations`.
    public let family: String

    public init(bundleIDs: Set<String>, app: String, directory: URL, family: String) {
        self.bundleIDs = bundleIDs
        self.app = app
        self.directory = directory
        self.family = family
    }
}

public extension LogMuteConfig {
    /// Teams' SlimCore media stack (MIC8). The bundle IDs mirror
    /// `NativeAppMuteConfig.teams`, deliberately: both adapters run for a Teams
    /// meeting and `MicGate` fuses their readings.
    static var teams: LogMuteConfig {
        LogMuteConfig(
            bundleIDs: NativeAppMuteConfig.teams.bundleIDs,
            app: NativeAppMuteConfig.teams.app,
            directory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers")
                .appendingPathComponent("UBF8T346G9.com.microsoft.teams")
                .appendingPathComponent("Library/Application Support/Logs"),
            family: "MSTeamsNM_SlimCore_"
        )
    }
}

/// MicGate adapter that reads a meeting client's mute state from the client's own log instead of its UI (MIC8). Tails the newest generation of one log family, parses the transition line, and hands an `AXMuteButtonProbe.Event` to the sink, landing in the same `MicGate` state the AX scrape does; `MuteSourceFusion` decides which of the two wins. UI-independent by construction, so no window scoping, no locale, and nothing for a client redesign to break.
///
/// Threading mirrors `MeetingAXWindowWatcher` (MIC16): the blocking directory listing
/// and file read run on `readQueue`, and only the bytes hop back to the caller's queue,
/// where every piece of mutable state lives. `start` / `stop` on main; tests leave
/// `readQueue` nil so the whole tick runs synchronously under a manual scheduler.
public final class LogMuteAdapter: MicGateAdapter {

    /// Returns a cancel closure. Default re-arms a one-shot `Timer` per tick; tests inject a manual driver to step the poll without sleeping.
    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    public var bundleIDs: Set<String> { config.bundleIDs }
    public var app: String { config.app }
    public var source: MuteReadingSource { .log }

    /// One second: the log is written on the toggle, so the tick rate is the only
    /// latency this path adds, and it still beats the AX read it is fused with.
    public static let defaultPollInterval: TimeInterval = 1.0

    public static let defaultScheduler: Scheduler = { delay, action in
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            action()
        }
        return { timer.invalidate() }
    }

    private let config: LogMuteConfig
    private let eventLog: EventLog
    private let scheduler: Scheduler
    private let readQueue: DispatchQueue?
    private let pollInterval: TimeInterval

    private var sink: ((AXMuteButtonProbe.Event) -> Void)?
    private var cancelPoll: (() -> Void)?
    private var bundleID: String = ""
    /// The generation we are reading, and how far into it. Both nil/zero until the
    /// first resolve; rotation (a Teams restart) moves them.
    private var current: URL?
    private var offset: UInt64 = 0
    /// True until the first generation is resolved, so a fresh watch starts at
    /// end-of-file rather than replaying every toggle Teams ever logged.
    private var skipHistory = true
    /// Bytes read but not yet terminated by a newline. SlimCore flushes mid-line
    /// routinely (the live file's last line is usually truncated), so a tick must
    /// carry the remainder rather than parse a half line.
    private var pending = Data()
    /// Last state handed to the sink, so `MicGate` only ever sees real transitions.
    private var lastMuted: Bool?
    /// True once the absent-family event has been emitted for this watch, so a
    /// missing log says so once instead of at 1 Hz for the whole meeting.
    private var reportedMissing = false
    /// Bumped on every `stop()`, so a read still in flight on `readQueue` is dropped
    /// on delivery instead of re-arming a stopped poll (the MIC16 pattern).
    private var generation: Int = 0

    public init(
        config: LogMuteConfig,
        eventLog: EventLog = NoopEventLog(),
        scheduler: @escaping Scheduler = LogMuteAdapter.defaultScheduler,
        readQueue: DispatchQueue? = DispatchQueue(label: "MeetingPipeCore.LogMuteAdapter"),
        pollInterval: TimeInterval = LogMuteAdapter.defaultPollInterval
    ) {
        self.config = config
        self.eventLog = eventLog
        self.scheduler = scheduler
        self.readQueue = readQueue
        self.pollInterval = pollInterval
    }

    public func start(
        context: MeetingLifecycleContext,
        handle: MicGateAdapterHandle,
        sink: @escaping (AXMuteButtonProbe.Event) -> Void
    ) throws {
        stop()
        self.sink = sink
        self.bundleID = context.bundleID
        eventLog.emit(category: "micgate", action: "log_mute_watch_started", attributes: [
            "bundle_id": context.bundleID,
            "app": config.app,
            "family": config.family,
            "poll_interval_s": pollInterval,
        ])
        tick()
    }

    public func stop() {
        generation &+= 1
        cancelPoll?()
        cancelPoll = nil
        sink = nil
        bundleID = ""
        current = nil
        offset = 0
        skipHistory = true
        pending = Data()
        lastMuted = nil
        reportedMissing = false
    }

    // MARK: - Poll loop

    private func tick() {
        let directory = config.directory
        let family = config.family
        let current = self.current
        let offset = self.offset
        let skipHistory = self.skipHistory
        guard let readQueue = readQueue else {
            consume(SlimCoreMuteLog.tail(
                directory: directory, family: family,
                current: current, offset: offset, skipHistory: skipHistory
            ))
            return
        }
        let gen = generation
        readQueue.async { [weak self] in
            let tail = SlimCoreMuteLog.tail(
                directory: directory, family: family,
                current: current, offset: offset, skipHistory: skipHistory
            )
            DispatchQueue.main.async {
                guard let self = self, gen == self.generation else { return }
                self.consume(tail)
            }
        }
    }

    /// One tick's continuation: apply the read, emit a transition if the state moved, re-arm. Runs on main in production (hopped from `readQueue`), synchronously on the caller in tests.
    private func consume(_ tail: SlimCoreMuteLog.Tail) {
        defer { rearm() }
        guard let url = tail.url else {
            // The family is absent: Teams never ran on this Mac, or the log moved.
            // That degrades to no reading at all, NEVER to unmuted. `AirPodsService`
            // is a misnomer for this component, but the measurement cannot rule out
            // a dependency on AirPods being connected for output, so an absent line
            // has to stay unknown and let the AX read carry.
            if !reportedMissing {
                reportedMissing = true
                eventLog.emit(category: "micgate", action: "log_mute_source_missing", attributes: [
                    "bundle_id": bundleID,
                    "app": config.app,
                    "family": config.family,
                ])
            }
            return
        }
        if tail.rotated {
            eventLog.emit(category: "micgate", action: "log_mute_generation_resolved", attributes: [
                "bundle_id": bundleID,
                "app": config.app,
                "generation": url.lastPathComponent,
                "from_end": skipHistory,
            ])
            skipHistory = false
            pending = Data()
        }
        current = url
        offset = tail.offset
        reportedMissing = false
        guard !tail.chunk.isEmpty else { return }
        pending.append(tail.chunk)
        // Only the LAST transition in the batch matters: the sink is edge-triggered
        // on state, so replaying a whole batch would flap the verdict through states
        // that were already superseded before we read them.
        var latest: SlimCoreMuteLog.Reading?
        for line in completeLines() {
            if let reading = SlimCoreMuteLog.parse(line: line) { latest = reading }
        }
        // Whatever is left is a partial line, which is the normal case. Dropped past
        // a cap, because a file with no newline at all would otherwise grow the
        // buffer without bound; a real SlimCore line is a few hundred bytes.
        if pending.count > LogMuteAdapter.maxPendingBytes { pending = Data() }
        guard let reading = latest, reading.muted != lastMuted else { return }
        lastMuted = reading.muted
        eventLog.emit(category: "micgate", action: "log_mute_event", attributes: [
            "bundle_id": bundleID,
            "app": config.app,
            "state": reading.muted ? "muted" : "unmuted",
            "generation": url.lastPathComponent,
            "line_ts": LogMuteAdapter.iso8601.string(from: reading.at),
        ])
        sink?(AXMuteButtonProbe.Event(
            state: reading.muted ? .muted : .unmuted,
            label: SlimCoreMuteLog.transitionMarker + (reading.muted ? "mute" : "unmute"),
            // Empty on purpose: this reading has no locale, which is exactly what it
            // buys over the label scrape.
            locale: ""
        ))
    }

    /// Split `pending` on newlines, decoding only complete lines and leaving any
    /// trailing partial in the buffer for the next tick.
    private func completeLines() -> [String] {
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending = Data(pending[pending.index(after: newline)...])
        }
        return lines
    }

    private func rearm() {
        cancelPoll?()
        cancelPoll = scheduler(pollInterval) { [weak self] in
            self?.tick()
        }
    }

    private static let maxPendingBytes = 256 * 1024

    private static let iso8601: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
