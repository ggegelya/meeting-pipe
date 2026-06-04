import Foundation

/// Pure-logic RMS hysteresis gate. Consumes per-buffer dBFS readings and emits open/close transitions with asymmetric dwell: close at <= -55 dBFS for 350 ms; open at >= -45 dBFS for 80 ms. The asymmetry opens quickly when the user starts talking and closes slowly after they stop, so a momentary mic dip mid-sentence doesn't gate the audio. Allocation-free in the hot path (all state in stored properties) to satisfy the no-allocations-on-render-thread rule. Not internally synchronised; tap thread is the natural owner.
///
/// `onSustainedOpenChange` is a second, slower signal: it fires `true` once the gate has been continuously open past `sustainedOpenDwell` (default 1200 ms) and `false` when it closes. MicGate uses it to let sustained live voice override a stale app-mute read (e.g. when Teams switches to its compact/mini window and the live mute control becomes unreadable).
public final class RMSGateProbe {

    public typealias Clock = () -> Date

    public enum State: Equatable {
        case open
        case closed

        public var label: String {
            switch self {
            case .open: return "open"
            case .closed: return "closed"
            }
        }
    }

    public var onChange: ((State) -> Void)?
    /// Fires `true` once the gate has been continuously open past
    /// `sustainedOpenDwell`, and `false` when it closes.
    public var onSustainedOpenChange: ((Bool) -> Void)?
    public private(set) var state: State = .closed
    public private(set) var sustainedOpen: Bool = false

    public let closeThresholdDb: Float
    public let openThresholdDb: Float
    public let closeDwell: TimeInterval
    public let openDwell: TimeInterval
    public let sustainedOpenDwell: TimeInterval

    private let clock: Clock
    private var closeAccumulationStart: Date?
    private var openAccumulationStart: Date?
    private var openSince: Date?

    public init(
        closeThresholdDb: Float = -55.0,
        openThresholdDb: Float = -45.0,
        closeDwellMillis: Int = 350,
        openDwellMillis: Int = 80,
        sustainedOpenDwellMillis: Int = 1200,
        clock: @escaping Clock = { Date() }
    ) {
        self.closeThresholdDb = closeThresholdDb
        self.openThresholdDb = openThresholdDb
        self.closeDwell = TimeInterval(closeDwellMillis) / 1000.0
        self.openDwell = TimeInterval(openDwellMillis) / 1000.0
        self.sustainedOpenDwell = TimeInterval(sustainedOpenDwellMillis) / 1000.0
        self.clock = clock
    }

    /// Reset to closed and drop pending dwell. Call at meeting start to prevent accumulator bleed from a prior session.
    public func reset() {
        state = .closed
        closeAccumulationStart = nil
        openAccumulationStart = nil
        openSince = nil
        sustainedOpen = false
    }

    /// Feed one dBFS reading (-inf is valid for digital silence). Returns new state; transitions also fire `onChange`.
    @discardableResult
    public func ingest(dBFS: Float) -> State {
        let now = clock()
        switch state {
        case .open:
            handleOpenState(dBFS: dBFS, at: now)
        case .closed:
            handleClosedState(dBFS: dBFS, at: now)
        }
        return state
    }

    private func handleOpenState(dBFS: Float, at now: Date) {
        if dBFS <= closeThresholdDb {
            let start = closeAccumulationStart ?? now
            closeAccumulationStart = start
            if now.timeIntervalSince(start) >= closeDwell {
                state = .closed
                closeAccumulationStart = nil
                openAccumulationStart = nil
                openSince = nil
                if sustainedOpen {
                    sustainedOpen = false
                    onSustainedOpenChange?(false)
                }
                onChange?(.closed)
                return
            }
        } else {
            closeAccumulationStart = nil
        }

        // Still open: promote to "sustained" once we've been continuously open
        // past the dwell, so MicGate can override a stale app-mute with live voice.
        if !sustainedOpen, let openedAt = openSince,
           now.timeIntervalSince(openedAt) >= sustainedOpenDwell {
            sustainedOpen = true
            onSustainedOpenChange?(true)
        }
    }

    private func handleClosedState(dBFS: Float, at now: Date) {
        if dBFS >= openThresholdDb {
            let start = openAccumulationStart ?? now
            openAccumulationStart = start
            if now.timeIntervalSince(start) >= openDwell {
                state = .open
                openSince = now
                openAccumulationStart = nil
                closeAccumulationStart = nil
                onChange?(.open)
            }
        } else {
            openAccumulationStart = nil
        }
    }
}
