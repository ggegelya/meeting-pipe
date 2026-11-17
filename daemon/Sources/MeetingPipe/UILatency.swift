import AppKit
import Foundation
import os

/// OBS7: stamps a click at the entry point and again at the first visible state, so click-to-
/// feedback latency can be read from `events.jsonl` instead of reconstructed from completion rows
/// (the 2026-11-13 responsiveness audit started every Record figure at the recorder's `start:`
/// line because nothing logged the click).
///
/// Four rows, all category `ui`, none carrying a title, a person's name or any text (`name`, `surface`,
/// `window` and `seq` are a fixed vocabulary):
/// - `ui_action` (`name`, `surface`, `seq`): the first line of an entry point.
/// - `ui_feedback` (`seq`, `ms`): emitted on the *next main turn* after the state that answers the
///   action was set. The state can paint only once the job that set it returns, so a synchronous
///   tail after the setter (P005/P047's HAL teardown after `hud.dismiss()`) is inside `ms`.
/// - `first_paint` (`surface`, `phase`, `seq`, `ms`): the run-loop turn that presented, or ordered
///   out, a panel has committed.
/// - `window_opened` (`window`, `cold`, `ms_to_key`, `seq`).
///
/// Timestamps are `systemUptime`, never the wall clock, so a clock step cannot make a latency
/// negative. The state sits behind an unfair lock rather than on the main actor because
/// `MainThreadStallWatchdog` reads the last sequence from its utility queue, and a read that had
/// to hop to main would be blocked by exactly the stall it is describing.
final class UILatency: Sendable {

    /// The process-wide instance every entry point stamps.
    static let shared = UILatency()

    /// An action nobody answered within this long is forgotten, so an automatic start or stop
    /// (no click) cannot be answered by a click's stale sequence.
    static let staleActionSeconds: TimeInterval = 30
    /// Unanswered actions kept; an action with no visible state (a no-op press) would otherwise leak.
    static let maxPending = 64
    /// A window that never becomes key (the app was not active) stops waiting after this long.
    static let windowKeyTimeoutSeconds: TimeInterval = 5

    /// What a visible state answers. A Start is answered by the HUD appearing and a Stop by it
    /// going, so only a click that can cause that phase may be paired with it.
    enum Phase { case start, stop }

    private static let startNames: Set<String> = [
        "prompt_record", "prompt_record_byo", "prompt_always", "menu_start", "hotkey_toggle",
        "automation_toggle", "automation_record", "notification_record",
    ]
    private static let stopNames: Set<String> = [
        "hud_stop", "menu_stop", "notification_stop", "automation_stop", "automation_toggle",
        "hotkey_toggle", "hotkey_force_stop",
    ]
    private static func names(for phase: Phase) -> Set<String> { phase == .start ? startNames : stopNames }

    private struct Entry { let seq: Int; let name: String; let uptime: TimeInterval }

    private struct State {
        var nextSeq = 1
        /// Clicks still waiting for a visible state.
        var pending: [Int: Entry] = [:]
        /// The newest clicks, answered or not, for first-paint rows and the stall watchdog.
        var recent: [Entry] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let uptime: @Sendable () -> TimeInterval
    private let emit: @Sendable (_ action: String, _ attributes: [String: Any]) -> Void
    private let nextTurn: @Sendable (@escaping @Sendable () -> Void) -> Void

    /// `nextTurn` is the main queue by default; a test injects a queue it drains by hand, which is
    /// what makes "the work after the setter counts" assertable without sleeping.
    init(
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        emit: @escaping @Sendable (String, [String: Any]) -> Void = { action, attributes in
            Log.event(category: "ui", action: action, attributes: attributes)
        },
        nextTurn: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { block in
            DispatchQueue.main.async(execute: block)
        }
    ) {
        self.uptime = uptime
        self.emit = emit
        self.nextTurn = nextTurn
    }

    // MARK: - Actions

    /// The first line of an entry point. Returns the sequence the matching `feedback` answers.
    @discardableResult
    func action(_ action: String, surface: String) -> Int {
        let now = uptime()
        let seq = state.withLock { s -> Int in
            let entry = Entry(seq: s.nextSeq, name: action, uptime: now)
            s.nextSeq += 1
            s.pending[entry.seq] = entry
            s.recent.append(entry)
            if s.recent.count > Self.maxPending { s.recent.removeFirst(s.recent.count - Self.maxPending) }
            if s.pending.count > Self.maxPending, let oldest = s.pending.keys.min() {
                s.pending.removeValue(forKey: oldest)
            }
            return entry.seq
        }
        // `name`, not `action`: `Log.event` writes the row type into `action` after the attributes.
        emit("ui_action", ["name": action, "surface": surface, "seq": seq])
        return seq
    }

    /// The first visible state for `seq` has been set. Emits `ui_feedback` from the next main
    /// turn; a sequence that is unknown or already answered emits nothing.
    func feedback(seq: Int) {
        // Claimed now, so a second setter before the turn runs cannot answer the same click; only
        // the clock read waits for the next turn.
        guard let entry = state.withLock({ $0.pending.removeValue(forKey: seq) }) else { return }
        nextTurn { [self] in
            emit("ui_feedback", ["seq": seq, "ms": Self.ms(from: entry.uptime, to: uptime())])
        }
    }

    /// `feedback` for the newest unanswered click that could have caused `phase` and is recent;
    /// returns the sequence it answered. The setters that answer a Start or a Stop do not know
    /// which click caused them (a prompt Record, a hotkey and a menu row all end at the same
    /// `hud.present`), and an automatic start has no click at all: the phase filter and the age
    /// bound are what stop it being answered by an unrelated click.
    @discardableResult
    func feedbackForLatest(_ phase: Phase) -> Int? {
        let now = uptime()
        let names = Self.names(for: phase)
        let seq = state.withLock { s in
            s.pending.values
                .filter { names.contains($0.name) && now - $0.uptime <= Self.staleActionSeconds }
                .max(by: { $0.seq < $1.seq })?.seq
        }
        if let seq { feedback(seq: seq) }
        return seq
    }

    /// The click will never get a visible state (refused, a no-op press), so it stops waiting.
    func discard(seq: Int) {
        state.withLock { _ = $0.pending.removeValue(forKey: seq) }
    }

    /// A start was cancelled or a press landed on a state that ignores it: every click still
    /// waiting is moot, and must not answer the next automatic start or stop.
    func discardPending() {
        state.withLock { $0.pending.removeAll() }
    }

    /// The most recent action, for `main_thread_stall` rows (`last_ui_seq`, `since_ui_action_ms`).
    /// Callable from any thread.
    func lastAction() -> (seq: Int, sinceMs: Int)? {
        let now = uptime()
        return state.withLock { s in
            s.recent.last.map { ($0.seq, Self.ms(from: $0.uptime, to: now)) }
        }
    }

    /// The newest click, answered or not, that could cause `phase` and is recent enough to have,
    /// for the first-paint row of the panel that phase presents.
    func recentActionSeq(_ phase: Phase) -> Int? {
        let now = uptime()
        let names = Self.names(for: phase)
        return state.withLock { s in
            s.recent.last { names.contains($0.name) && now - $0.uptime <= Self.staleActionSeconds }?.seq
        }
    }

    // MARK: - First paint and window opens

    /// A panel's present or order-out has committed. `seq` is the triggering action when there is
    /// one; `ms` is then click to this row. `present` is the turn that ordered the panel front at
    /// alpha 0 and started its fade-in, so it precedes full opacity by the fade's duration.
    func firstPaint(surface: String, phase: String, seq: Int?) {
        var attrs: [String: Any] = ["surface": surface, "phase": phase]
        if let seq {
            attrs["seq"] = seq
            let now = uptime()
            if let started = state.withLock({ s in s.recent.first { $0.seq == seq }?.uptime }) {
                attrs["ms"] = Self.ms(from: started, to: now)
            }
        }
        emit("first_paint", attrs)
    }

    /// A window opener ran. Emits `window_opened` when the window becomes key, or once
    /// `windowKeyTimeoutSeconds` has passed with `ms_to_key` null. `ms_to_key` counts from the
    /// click (the opener's `ui_action`), so the cost of building a cold window is inside it, and a
    /// window that is already key by the time this runs reports the build cost, not 0.
    /// `observeKey` registers the one-shot didBecomeKey handler (a notification in production, a
    /// stored closure in tests) and returns what removes it.
    func windowOpened(
        window name: String, cold: Bool, seq: Int, alreadyKey: Bool,
        observeKey: (@escaping @Sendable () -> Void) -> (@Sendable () -> Void),
        afterTimeout: (@escaping @Sendable () -> Void) -> Void
    ) {
        let started = state.withLock { s in s.pending[seq]?.uptime ?? s.recent.first { $0.seq == seq }?.uptime } ?? uptime()
        let done = OSAllocatedUnfairLock(initialState: false)
        let cancelKey = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
        let finish: @Sendable (Bool) -> Void = { [self] reachedKey in
            guard done.withLock({ let was = $0; $0 = true; return !was }) else { return }
            cancelKey.withLock { $0 }?()
            state.withLock { _ = $0.pending.removeValue(forKey: seq) }
            let ms: Any = reachedKey ? Self.ms(from: started, to: uptime()) : NSNull()
            emit("window_opened", ["window": name, "cold": cold, "seq": seq, "ms_to_key": ms])
        }
        if alreadyKey { finish(true); return }
        let cancel = observeKey { finish(true) }
        cancelKey.withLock { $0 = cancel }
        // The handler may have run synchronously inside `observeKey`; nothing to cancel then.
        if done.withLock({ $0 }) { cancel(); return }
        afterTimeout { finish(false) }
    }

    private static func ms(from start: TimeInterval, to end: TimeInterval) -> Int {
        max(0, Int(((end - start) * 1000).rounded()))
    }
}

// MARK: - AppKit adapters

extension UILatency {

    /// Stamp a window opener and track the window to its first key moment. Called from each
    /// `show()` after the window exists (so `cold` is whether this call built it).
    /// Main thread only (the window openers are).
    func trackWindowOpen(_ name: String, cold: Bool, seq: Int, window: NSWindow) {
        windowOpened(
            window: name, cold: cold, seq: seq, alreadyKey: window.isKeyWindow,
            observeKey: { handler in
                // A nil queue: a non-nil one makes the poster wait (REC13). The notification
                // posts on main, so the handler runs there already.
                let token = OSAllocatedUnfairLock<NSObjectProtocol?>(uncheckedState: nil)
                let remove: @Sendable () -> Void = {
                    if let t = token.withLockUnchecked({ s -> NSObjectProtocol? in defer { s = nil }; return s }) {
                        NotificationCenter.default.removeObserver(t)
                    }
                }
                token.withLockUnchecked {
                    $0 = NotificationCenter.default.addObserver(
                        forName: NSWindow.didBecomeKeyNotification, object: window, queue: nil
                    ) { _ in
                        remove()
                        handler()
                    }
                }
                return remove
            },
            afterTimeout: { handler in
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.windowKeyTimeoutSeconds, execute: handler)
            }
        )
    }

    /// Runs `block` once the run-loop turn that is current has committed its Core Animation
    /// transaction (a `beforeWaiting` observer ordered after CA's own), which is the first moment
    /// a panel ordered front in this turn can have reached the screen.
    static func afterNextCommit(_ block: @escaping @Sendable () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, false, 2_100_000
        ) { observer, _ in
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            block()
        }
        if let observer { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
    }
}
