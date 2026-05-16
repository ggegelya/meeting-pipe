import Foundation

/// Pure-logic RMS hysteresis gate. Consumes per-buffer RMS readings
/// (in dBFS, negative values, with -inf representing absolute
/// silence) and emits open / close state transitions with asymmetric
/// dwell:
///
///   - Close at sustained <= `closeThresholdDb` for `closeDwell` ms.
///   - Open at sustained >= `openThresholdDb` for `openDwell` ms.
///
/// Defaults: -55 dBFS / 350 ms close, -45 dBFS / 80 ms open. The
/// asymmetry biases toward "open quickly when the user starts
/// talking; close slowly after they stop" so a momentary mic dip
/// mid-sentence doesn't gate the audio.
///
/// The gate is deliberately allocation-free in the hot path so it
/// can be called from the AVAudioEngine tap callback without
/// breaking the no-allocations-on-render-thread requirement. All
/// state lives in stored properties; no arrays, no allocators.
///
/// Threading: the gate is `final` but not internally synchronised.
/// Callers must own per-tap state and not share an instance across
/// queues. The tap thread is the natural owner.
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

    /// Reset the gate to closed and drop pending dwell. Call at
    /// meeting start so a prior recording's accumulator doesn't
    /// bleed into the next session.
    public func reset() {
        state = .closed
        closeAccumulationStart = nil
        openAccumulationStart = nil
    }

    /// Feed one RMS reading in dBFS. -infinity is valid (digital
    /// silence). Returns the new state; transitions also fire
    /// `onChange`.
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
