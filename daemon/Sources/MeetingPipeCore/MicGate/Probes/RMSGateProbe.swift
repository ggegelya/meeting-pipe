import Foundation

/// Pure-logic RMS hysteresis gate. Consumes per-buffer dBFS readings and emits open/close transitions with asymmetric dwell: close at <= -55 dBFS for 350 ms; open at >= -45 dBFS for 80 ms. The asymmetry opens quickly when the user starts talking and closes slowly after they stop, so a momentary mic dip mid-sentence doesn't gate the audio. Allocation-free in the hot path (all state in stored properties) to satisfy the no-allocations-on-render-thread rule. Not internally synchronised; tap thread is the natural owner.
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
    public private(set) var state: State = .closed

    public let closeThresholdDb: Float
    public let openThresholdDb: Float
    public let closeDwell: TimeInterval
    public let openDwell: TimeInterval

    private let clock: Clock
    private var closeAccumulationStart: Date?
    private var openAccumulationStart: Date?

    public init(
        closeThresholdDb: Float = -55.0,
        openThresholdDb: Float = -45.0,
        closeDwellMillis: Int = 350,
        openDwellMillis: Int = 80,
        clock: @escaping Clock = { Date() }
    ) {
        self.closeThresholdDb = closeThresholdDb
        self.openThresholdDb = openThresholdDb
        self.closeDwell = TimeInterval(closeDwellMillis) / 1000.0
        self.openDwell = TimeInterval(openDwellMillis) / 1000.0
        self.clock = clock
    }

    /// Reset to closed and drop pending dwell. Call at meeting start to prevent accumulator bleed from a prior session.
    public func reset() {
        state = .closed
        closeAccumulationStart = nil
        openAccumulationStart = nil
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
                onChange?(.closed)
            }
        } else {
            closeAccumulationStart = nil
        }
    }

    private func handleClosedState(dBFS: Float, at now: Date) {
        if dBFS >= openThresholdDb {
            let start = openAccumulationStart ?? now
            openAccumulationStart = start
            if now.timeIntervalSince(start) >= openDwell {
                state = .open
                openAccumulationStart = nil
                closeAccumulationStart = nil
                onChange?(.open)
            }
        } else {
            openAccumulationStart = nil
        }
    }
}
