import Foundation

/// REC20 item 2: re-reads the library volume's free space once a minute while a recording runs,
/// and hands the session what `RecordingLowSpace.Policy` makes of it.
///
/// Before this the only defence against a filling disk was REC3's write-failure force-stop, which
/// fires after 32 consecutive failed writes, by which point the whole Mac is out of space and the
/// stop's own merge has nowhere to write. This stops while the merge still fits.
///
/// Shaped like `WriteFailureRouter` (REC25), and for the same reason: a reading taken for one
/// recording must never act on the next. `begin` opens a generation, `end` closes it, every tick
/// carries the generation it was armed under, and a reading that lands on main for any other
/// generation is dropped. The free-space read happens on the watch's own utility queue, never on
/// main: the volume being read is the one most likely to be slow (REC19, REC25).
///
/// Main-only apart from the timer handler, which touches only its injected reader and the hop.
final class LowSpaceWatch {

    /// Where the session hears about it. Read on main, at delivery.
    var onUpdate: ((RecordingLowSpace.Update) -> Void)?

    /// The generation of the recording being watched, or nil between recordings. Main-only.
    private(set) var liveGeneration: UInt64?
    private var lastGeneration: UInt64 = 0
    private var policy: RecordingLowSpace.Policy?
    private var startUptime: Double = 0
    private var directory: URL?
    /// The label last handed over, so an unchanged minute does not re-push it.
    private var lastLabel: String?
    private var timer: DispatchSourceTimer?

    private let interval: Double
    private let queue: DispatchQueue
    private let startsTimer: Bool
    private let freeSpace: (URL) -> (freeBytes: Int64?, volumeName: String?)
    private let mainHop: (@escaping () -> Void) -> Void
    private let uptime: () -> Double
    private let emit: (String, [String: Any]) -> Void

    /// The defaults are production's. Tests turn the timer off and drive `pollNow()` with a
    /// synchronous hop, a scripted free-space reader, a fixed clock and an event sink.
    init(
        interval: Double = RecordingLowSpace.checkIntervalSeconds,
        queue: DispatchQueue = DispatchQueue(label: "com.meetingpipe.lowspace", qos: .utility),
        startsTimer: Bool = true,
        freeSpace: @escaping (URL) -> (freeBytes: Int64?, volumeName: String?) = RecordingWriteFailure.freeSpace(at:),
        mainHop: @escaping (@escaping () -> Void) -> Void = { work in DispatchQueue.main.async { work() } },
        uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
        emit: @escaping (String, [String: Any]) -> Void = { action, attributes in
            Log.event(category: "recorder", action: action, attributes: attributes)
        }
    ) {
        self.interval = interval
        self.queue = queue
        self.startsTimer = startsTimer
        self.freeSpace = freeSpace
        self.mainHop = mainHop
        self.uptime = uptime
        self.emit = emit
    }

    /// From the end of a successful `start()`, on main. `captureBytesPerSecond` is both capture
    /// files' real rate; `start` is the preflight's reading, so a start already told it is short
    /// is not told again on the first tick, and its label is what the first tick replaces.
    func begin(directory: URL, captureBytesPerSecond: Double, start: RecordingLowSpace.StartNotice?) {
        end()
        lastGeneration &+= 1
        let generation = lastGeneration
        liveGeneration = generation
        self.directory = directory
        startUptime = uptime()
        policy = RecordingLowSpace.Policy(
            captureBytesPerSecond: captureBytesPerSecond, startCovered: start?.coveredSeconds
        )
        lastLabel = start.map { RecordingLowSpace.hudText(coveredSeconds: $0.coveredSeconds) }
        guard startsTimer else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            self?.poll(directory: directory, generation: generation)
        }
        self.timer = timer
        timer.resume()
    }

    /// Close the generation and cancel the timer. From the recorder's timer stand-down (every
    /// stop, and the termination flush), on main. Idempotent.
    func end() {
        timer?.cancel()
        timer = nil
        liveGeneration = nil
        policy = nil
        directory = nil
        lastLabel = nil
    }

    /// One reading for the live generation, now. Tests drive the watch through this; production
    /// reaches the same `poll` from the timer, on the watch's queue.
    func pollNow() {
        guard let generation = liveGeneration, let directory = directory else { return }
        poll(directory: directory, generation: generation)
    }

    /// On the watch's queue: read, then hop.
    private func poll(directory: URL, generation: UInt64) {
        let space = freeSpace(directory)
        mainHop { [weak self] in
            self?.deliver(freeBytes: space.freeBytes, generation: generation)
        }
    }

    /// On main: a reading for the live recording goes through the policy; anything else is dropped.
    private func deliver(freeBytes: Int64?, generation: UInt64) {
        guard generation == liveGeneration, var policy = policy else { return }
        let elapsed = max(0, uptime() - startUptime)
        let assessment = policy.evaluate(freeBytes: freeBytes, elapsedSeconds: elapsed)
        self.policy = policy
        guard let assessment = assessment, let free = freeBytes else { return }
        switch assessment.action {
        case .stop:
            let mergeBytes = RecordingSpaceBudget.finalBytes(seconds: elapsed)
            emit("recording_stopped_low_space", [
                "free_bytes": free,
                "merge_bytes": mergeBytes,
                "elapsed_sec": Int(elapsed),
            ])
            Log.writeLine("recorder", "low space: \(free) bytes free against a \(mergeBytes)-byte merge after \(Int(elapsed)) s - stopping so the merge still fits")
            onUpdate?(.stop(message: RecordingLowSpace.stopMessage(freeBytes: free)))
        case .warn:
            emit("recording_low_space", [
                "free_bytes": free,
                "minutes_covered": Int(assessment.coveredSeconds / 60),
                "elapsed_sec": Int(elapsed),
            ])
            Log.writeLine("recorder", "low space: \(free) bytes free covers about \(Int(assessment.coveredSeconds / 60)) more minutes")
            lastLabel = assessment.hudText
            let text = RecordingLowSpace.warnMessage(freeBytes: free, coveredSeconds: assessment.coveredSeconds)
            onUpdate?(.warn(hudText: assessment.hudText, title: text.title, body: text.body))
        case .fine:
            guard assessment.hudText != lastLabel else { return }
            lastLabel = assessment.hudText
            onUpdate?(.label(assessment.hudText))
        }
    }
}
