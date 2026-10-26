import ApplicationServices
import Foundation

/// AX mute-button probe. Watches `kAXValueChangedNotification` and `kAXTitleChangedNotification` on the meeting app's mute `AXUIElement`. A health poll (1 Hz, backing off to 5 s once its reads stop bringing news, PERF19) absorbs Sequoia notification drops; transient `.unknown` results latch the prior known state (see `evaluate` inline comment).
///
/// Threading (PERF10): every mutable field is confined to `queue`, a private serial queue, and the
/// production poll is a `DispatchSourceTimer` on it, so the button reads (cross-process AX IPC into the
/// meeting app) and the TECH-MIC6 re-arm walk never run on main. Before, the poll was a main-run-loop
/// `Timer`, and against a hung Teams one tick held main for up to three 2 s reads, about six seconds in
/// every seven, with Stop and the hotkeys waiting behind it. `start` and `stop` are called on main and
/// return at once: each bumps `generation` under `lock` and hops onto the queue with `async`, never
/// `sync` (a `sync` from main waits out whatever read or walk is ahead of it, which is the PERF15
/// shape). The value/title notification handlers, which `AXObserverBus` delivers on main, hop on with
/// `async` too. Every queued block carries the generation it was created under and does nothing once
/// `stop` or a later `start` has moved it on, and a read is re-checked after it returns, so a read in
/// flight when `stop()` runs cannot deliver into the next meeting's `MicGate` (one check-then-call
/// window aside, see the end of `evaluate`). `onChange` fires on the queue; `MicGate.injectAxMuteEvent`
/// and its sink are any-queue by contract. Each element the probe reads gets a short per-element
/// messaging timeout (`defaultElementReadTimeout`), so a hung client costs a quarter second per read
/// rather than the 2 s system-wide backstop. Injecting a `Scheduler` (tests) selects the inline path,
/// no queue at all, as `AXLeaveButtonSignal` and `ProcessAudioSignal` do, so those assertions stay
/// synchronous.
public final class AXMuteButtonProbe {

    public typealias Probe = (AXUIElement) -> AXTextBlob

    /// AX attribute bundle passed to `recognize`; decouples the scrape from the recogniser for unit tests.
    public struct AXTextBlob: Equatable {
        public let title: String?
        public let help: String?
        public let description: String?

        public init(title: String? = nil, help: String? = nil, description: String? = nil) {
            self.title = title
            self.help = help
            self.description = description
        }
    }

    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void
    public typealias LocaleResolver = () -> String
    /// Applies the per-element messaging timeout to an element before the probe first reads it.
    public typealias ElementTimeout = (AXUIElement) -> Void

    public struct Event: Equatable {
        public let state: MuteLabels.State
        public let label: String?
        public let locale: String

        /// Public so out-of-band producers (e.g. the mute-state poller) can build events for `MicGate.injectAxMuteEvent`.
        public init(state: MuteLabels.State, label: String?, locale: String) {
            self.state = state
            self.label = label
            self.locale = locale
        }
    }

    /// Set on main, read on the queue, so it lives under `lock`. Called outside the lock.
    public var onChange: ((Event) -> Void)? {
        get { lock.withLock { _onChange } }
        set { lock.withLock { _onChange = newValue } }
    }

    /// The last reading delivered. Queue-confined, so only the tests read it, on the inline path.
    private(set) var lastEvent: Event?

    public static let defaultPollInterval: TimeInterval = 1.0
    /// TECH-PERF5: the backed-off health-poll rate, held once polls stop
    /// bringing news (PERF19; worst case beside `AdaptivePollCadence.steadyPollsBeforeSlow`).
    public static let defaultSlowPollInterval: TimeInterval = 5.0
    /// TECH-MIC6: consecutive `.unknown` reads before the probe re-resolves its
    /// cached element via a fresh tree walk. An `.unknown` read returns the
    /// health poll to its 1 Hz `fast` rate (PERF19), so this is ~5 s of an
    /// unreadable control, counted from its first unknown read, before a recovery attempt.
    public static let defaultRearmThreshold: Int = 5
    /// PERF10: the messaging timeout set on the mute button and on every element the re-arm resolver
    /// returns, in seconds. A timeout set on one element bounds that element's reads only, so it goes on
    /// each element the probe reads, never on the application element alone. Measured 2026-10-26 with a
    /// read-only harness over up to 40 buttons in each of six running apps (Chrome, Safari, Finder, Telegram,
    /// WhatsApp, the Claude desktop app; Teams was not running), 3,975 samples: the one-call read of
    /// title, help and description took p50 0.02 to 0.05 ms, p99 at most 2.2 ms, max 4.2 ms (Finder); the
    /// old three single reads max 7.0 ms. 0.25 s is 35 times the slowest healthy read seen, and an eighth
    /// of the 2 s system-wide backstop `App.swift` keeps. A read that times out returns nothing, decodes
    /// to `.unknown`, and the latch below holds the prior state across it.
    public static let defaultElementReadTimeout: Float = 0.25

    private let app: String
    private let axBus: AXObserverBus
    private let eventLog: EventLog
    private let catalogue: MuteLabels
    private let probe: Probe
    private let scheduler: Scheduler
    private let localeResolver: LocaleResolver
    private let elementTimeout: ElementTimeout
    private let pollInterval: TimeInterval
    private let slowPollInterval: TimeInterval
    private let rearmThreshold: Int
    /// Confines every field below the lock-guarded pair. Nil when a scheduler is injected (tests run inline).
    private let queue: DispatchQueue?

    /// Guards `generation` and `_onChange`, the only fields touched off the queue. Never held across an AX call or `onChange`.
    private let lock = NSLock()
    /// Bumped by every `start` and `stop`. A queued block whose captured value no longer matches does nothing.
    private var generation: UInt64 = 0
    private var _onChange: ((Event) -> Void)?

    // Queue-confined from here down.
    private var element: AXUIElement?
    private var pid: pid_t = 0
    private var bundleID: String = ""
    private var tokens: [AXObserverBus.Token] = []
    private var cancelPoll: (() -> Void)?
    private var cadence: AdaptivePollCadence
    private var currentPollInterval: TimeInterval = 0
    /// Re-resolve the live mute button via a fresh tree walk; injected at `start`
    /// by the daemon (TECH-MIC6). Nil when the caller cannot re-walk (then the
    /// probe just keeps latching, the pre-MIC6 behaviour).
    private var resolveElement: (() -> AXUIElement?)?
    /// Consecutive `.unknown` reads since the last confident state.
    private var consecutiveUnknown: Int = 0

    /// `scheduler` nil is production: the private queue and a `DispatchSourceTimer` poll on it. An
    /// injected scheduler is the test path and runs everything inline on the caller.
    public init(
        app: String,
        axBus: AXObserverBus,
        catalogue: MuteLabels,
        eventLog: EventLog = NoopEventLog(),
        probe: @escaping Probe = AXMuteButtonProbe.defaultProbe,
        scheduler: Scheduler? = nil,
        localeResolver: @escaping LocaleResolver = AXMuteButtonProbe.defaultLocaleResolver,
        elementTimeout: @escaping ElementTimeout = AXMuteButtonProbe.defaultElementTimeout,
        pollInterval: TimeInterval = AXMuteButtonProbe.defaultPollInterval,
        slowPollInterval: TimeInterval = AXMuteButtonProbe.defaultSlowPollInterval,
        rearmThreshold: Int = AXMuteButtonProbe.defaultRearmThreshold
    ) {
        self.app = app
        self.axBus = axBus
        self.eventLog = eventLog
        self.catalogue = catalogue
        self.probe = probe
        self.localeResolver = localeResolver
        self.elementTimeout = elementTimeout
        self.pollInterval = pollInterval
        self.slowPollInterval = slowPollInterval
        self.rearmThreshold = max(1, rearmThreshold)
        self.cadence = AdaptivePollCadence(fast: pollInterval, slow: slowPollInterval)
        if let scheduler {
            self.scheduler = scheduler
            self.queue = nil
        } else {
            let queue = DispatchQueue(label: "MeetingPipeCore.AXMuteButtonProbe", qos: .userInitiated)
            self.queue = queue
            self.scheduler = AXMuteButtonProbe.queueScheduler(on: queue)
        }
    }

    deinit {
        // Nothing else can be touching the queue's state once the last reference is gone, so this
        // cannot race it. A `DispatchSourceTimer` must not be released while still active.
        cancelPoll?()
    }

    /// Returns at once in production; the subscriptions and the initial read happen on the queue.
    /// No longer throws (PERF10): a notification that fails to subscribe is logged as
    /// `ax_mute_button_arm_failed` and the health poll still reads the button, the way
    /// `AXLeaveButtonSignal` treats a failed subscribe.
    public func start(
        pid: pid_t,
        bundleID: String,
        button: AXUIElement,
        resolveElement: (() -> AXUIElement?)? = nil
    ) {
        let generation = bumpGeneration()
        run {
            self.begin(
                pid: pid, bundleID: bundleID, button: button,
                resolveElement: resolveElement, generation: generation
            )
        }
    }

    /// Returns at once in production. A block this session queued that runs after it emits nothing,
    /// and the teardown runs after any read already in flight.
    public func stop() {
        _ = bumpGeneration()
        run { self.teardown() }
    }

    /// Test seam: wait until every block queued so far has run. A no-op on the inline path.
    func drainForTesting() {
        queue?.sync {}
    }

    /// Test seam for the inline path: one evaluate under the current session.
    @discardableResult
    func evaluate(reason: String) -> AdaptivePollCadence.PollObservation {
        evaluate(reason: reason, generation: lock.withLock { generation })
    }

    // MARK: - Generation (under `lock`)

    private func bumpGeneration() -> UInt64 {
        lock.withLock {
            generation &+= 1
            return generation
        }
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        lock.withLock { generation == candidate }
    }

    /// `async` onto the queue, or inline on the test path. Never `sync`: see the type's Threading note.
    private func run(_ work: @escaping () -> Void) {
        if let queue {
            queue.async(execute: work)
        } else {
            work()
        }
    }

    // MARK: - Queue-confined

    private func begin(
        pid: pid_t,
        bundleID: String,
        button: AXUIElement,
        resolveElement: (() -> AXUIElement?)?,
        generation: UInt64
    ) {
        guard isCurrent(generation) else { return }
        teardown()
        elementTimeout(button)
        self.element = button
        self.pid = pid
        self.bundleID = bundleID
        self.resolveElement = resolveElement
        self.consecutiveUnknown = 0
        for notification in [
            kAXValueChangedNotification,
            kAXTitleChangedNotification
        ] {
            do {
                // Delivered on main by `AXObserverBus`: hop with `async`, never `sync`.
                let token = try axBus.subscribe(
                    pid: pid, element: button, notification: notification as String
                ) { [weak self] in
                    self?.run { [weak self] in
                        guard let self, self.isCurrent(generation) else { return }
                        self.cadence.noteListener()   // TECH-PERF5: notification is delivering
                        self.evaluate(reason: "notification", generation: generation)
                    }
                }
                tokens.append(token)
            } catch {
                eventLog.emit(category: "micgate", action: "ax_mute_button_arm_failed", attributes: [
                    "bundle_id": bundleID,
                    "pid": Int(pid),
                    "app": app,
                    "notification": notification as String,
                    "error": "\(error)",
                ])
            }
        }
        cadence = AdaptivePollCadence(fast: pollInterval, slow: slowPollInterval)
        startPoll(interval: cadence.initialInterval, generation: generation)
        evaluate(reason: "initial", generation: generation)
    }

    private func teardown() {
        for token in tokens { axBus.unsubscribe(token) }
        tokens.removeAll()
        cancelPoll?(); cancelPoll = nil
        currentPollInterval = 0
        element = nil
        pid = 0
        bundleID = ""
        lastEvent = nil
        resolveElement = nil
        consecutiveUnknown = 0
    }

    /// Arm (or re-arm) the health poll at `interval`, backing the rate off once
    /// polls stop finding anything the notifications missed and speeding back up on
    /// an unannounced change or an unknown read (TECH-PERF5, PERF19). Re-armed only
    /// from the poll callback, on the queue.
    private func startPoll(interval: TimeInterval, generation: UInt64) {
        cancelPoll?()
        currentPollInterval = interval
        cancelPoll = scheduler(interval) { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            let observation = self.evaluate(reason: "health_poll", generation: generation)
            let next = self.cadence.intervalAfterPoll(observation)
            if next != self.currentPollInterval {
                self.startPoll(interval: next, generation: generation)
            }
        }
    }

    /// Returns what the read said against the state already held, which the health poll hands to its
    /// cadence (PERF19). A read for a session that has moved on is `.unknown`; nothing re-arms on it,
    /// since the poll callback checks the generation first.
    @discardableResult
    private func evaluate(reason: String, generation: UInt64) -> AdaptivePollCadence.PollObservation {
        guard let element = element, isCurrent(generation) else { return .unknown }
        let blob = probe(element)
        // The read can outlast its session (up to the element timeout against a hung client).
        guard isCurrent(generation) else { return .unknown }
        let locale = localeResolver()
        let state = catalogue.recognize(
            app: app, locale: locale,
            title: blob.title, help: blob.help, description: blob.description
        )
        let label = labelFromBlob(blob)
        let event = Event(state: state, label: label, locale: locale)

        // TECH-MIC6: a cached element that goes stale (Teams 2 re-render, compact
        // view, "Mic is not available") reads `.unknown` forever. Count the
        // streak and, past the threshold, re-resolve via a fresh tree walk so the
        // read recovers instead of latching the prior state until the call ends.
        // The latch below still holds the prior state across the streak; the
        // re-arm just retargets the element it reads.
        if state == .unknown {
            noteUnknownAndMaybeRearm(reason: reason, generation: generation)
            // So can the walk.
            guard isCurrent(generation) else { return .unknown }
        } else {
            consecutiveUnknown = 0
        }

        if event == lastEvent { return state == .unknown ? .unknown : .steady }

        // Suppress transient `.unknown` once a real state was
        // observed. Teams 2 shows "Mic is not available" on its
        // mute button during call setup, then briefly returns nil
        // for the title; both decode to `.unknown` and the original
        // code propagated those to MicGate. Clearing `axMute` made
        // the verdict fall through to VAD / RMS for ~90 s while the
        // user was actually muted in Teams, leaking their voice
        // into the recording. Latching the prior known state keeps
        // `mutedByApp` in place across the glitch; the next real
        // `.muted` or `.unmuted` event resumes normal flow.
        if state == .unknown, let prev = lastEvent, prev.state != .unknown {
            eventLog.emit(category: "micgate", action: "ax_mute_button_state_kept", attributes: [
                "bundle_id": bundleID,
                "pid": Int(pid),
                "app": app,
                "locale": locale,
                "reason": reason,
                "kept_state": prev.state == .muted ? "muted" : "unmuted",
                "transient_label": label as Any
            ])
            return .unknown
        }

        let previous = lastEvent
        lastEvent = event
        eventLog.emit(category: "micgate", action: "ax_mute_button_state", attributes: [
            "bundle_id": bundleID,
            "pid": Int(pid),
            "app": app,
            "locale": locale,
            "state": state == .muted ? "muted" : (state == .unmuted ? "unmuted" : "unknown"),
            "label": label as Any,
            "reason": reason,
            "previous": previous.map { "\($0.state) / \($0.label as Any)" } as Any
        ])
        // The generation and the sink are read under one lock and the sink is called outside it, so a
        // `stop` landing between the two can still let this one reading through. That window is left
        // on purpose, as in `ProcessAudioSignal`: holding the lock across `onChange` is how a sink that
        // syncs to main deadlocks against a `stop` on main. `MicGate.start` resets its state through
        // its own `stop()` before any adapter starts, so the one reading that can slip through lands in the
        // gap a stop opens, where nothing records, and the next start clears it.
        let deliver: ((Event) -> Void)? = lock.withLock { self.generation == generation ? _onChange : nil }
        deliver?(event)
        return state == .unknown ? .unknown : .changed
    }

    /// Count the `.unknown` streak and, once it crosses `rearmThreshold`,
    /// re-resolve the cached element via the injected fresh-tree-walk resolver
    /// (TECH-MIC6). The element is swapped so the next read targets the live
    /// control; the value/title notifications are deliberately NOT re-subscribed
    /// (RealAXBackend caches one AXObserver per pid and re-registering proved
    /// fragile, see `MeetingAXWindowWatcher`), so the health poll reads the fresh
    /// element and the window watcher remains the independent backstop. The
    /// counter resets each attempt so re-resolution is throttled to one walk per
    /// `rearmThreshold` polls rather than every poll. Runs on the queue (PERF10).
    private func noteUnknownAndMaybeRearm(reason: String, generation: UInt64) {
        consecutiveUnknown += 1
        guard consecutiveUnknown >= rearmThreshold, let resolve = resolveElement else { return }
        consecutiveUnknown = 0
        guard let fresh = resolve(), isCurrent(generation) else { return }
        elementTimeout(fresh)
        element = fresh
        eventLog.emit(category: "micgate", action: "ax_mute_button_rearmed", attributes: [
            "bundle_id": bundleID,
            "pid": Int(pid),
            "app": app,
            "reason": reason,
        ])
    }

    private func labelFromBlob(_ blob: AXTextBlob) -> String? {
        if let title = blob.title, !title.isEmpty { return title }
        if let help = blob.help, !help.isEmpty { return help }
        if let description = blob.description, !description.isEmpty { return description }
        return nil
    }

    // MARK: - Default seams

    /// Production scheduler: a `DispatchSourceTimer` on the probe's serial queue, so the poll fires
    /// (and runs the AX reads) off the main thread. The `Timer.scheduledTimer` this replaced bound to
    /// the main run loop. Re-armed on the queue when the cadence changes.
    private static func queueScheduler(on queue: DispatchQueue) -> Scheduler {
        return { interval, action in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler(handler: action)
            timer.resume()
            return { timer.cancel() }
        }
    }

    public static let defaultLocaleResolver: LocaleResolver = {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    public static let defaultElementTimeout: ElementTimeout = { element in
        AXUIElementSetMessagingTimeout(element, AXMuteButtonProbe.defaultElementReadTimeout)
    }

    /// Title, help and description in one `AXUIElementCopyMultipleAttributeValues` call (PERF10), so a
    /// hung client costs one messaging timeout per read rather than three. Without the stop-on-error
    /// option an attribute the element lacks comes back as an AXError value in its slot, which the
    /// `as? String` turns into nil, the same per-attribute answer the three single reads gave.
    public static let defaultProbe: Probe = { element in
        let attributes = [kAXTitleAttribute, kAXHelpAttribute, kAXDescriptionAttribute] as CFArray
        var values: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values
        )
        guard status == .success, let array = values as? [Any], array.count == 3 else {
            return AXTextBlob()
        }
        return AXTextBlob(
            title: array[0] as? String,
            help: array[1] as? String,
            description: array[2] as? String
        )
    }
}
