import Foundation

/// END19: how long a discovery engage may outlive discovery's sighting of it.
///
/// Discovery engages a lifecycle when a scan picks a winner, and nothing tore that engage down when
/// later scans stopped picking it. On the work laptop four Chrome engages lived 15.0, 95.3, 119.5
/// and 176.5 minutes, and the 2026-11-11 one (a score-2, title-only pick whose tab the window
/// signal never saw on screen) reached `.starting` 767.8 s later in the middle of a hand-started
/// recording and stopped it. This bounds an engage that never got past `.idle`: once that many
/// consecutive idle scans have found no winner for it, the host disengages it.
///
/// Pure: the host reports sightings and winnerless scans with its clock and the engine's state.
struct StaleEngageBound: Equatable {

    /// The life, in winnerless scans: DET9's skip-latch grace, five idle polls (60 s at the 12 s
    /// quiet poll). A live Teams call regularly goes tens of seconds with no confident winner while
    /// its compact call UI hides every control (48 s on 2026-07-27, END9's 21-33 s blackout), so a
    /// shorter life would tear down the engage of a call that is plainly running. An engage that
    /// reached `.starting` is never touched, so the cost of the life is only how long a dead
    /// engage lingers before discovery idles cleanly.
    static let scansWithoutSighting = Int(DetectionStateMachine.skipLatchGracePolls)

    struct Engage: Equatable {
        let bundleID: String
        let engagedAt: Date
        var scansWithoutSighting: Int
    }

    enum Action: Equatable {
        case keep
        case disengage(bundleID: String, engagedSec: TimeInterval, scansWithoutSighting: Int)
    }

    private(set) var engage: Engage?

    /// Discovery picked `bundleID` (and engaged it, or kept its engage). A different bundle starts
    /// a new record; the same one keeps its first engage time and resets the count.
    mutating func sighted(bundleID: String, at now: Date) {
        if engage?.bundleID == bundleID {
            engage?.scansWithoutSighting = 0
        } else {
            engage = Engage(bundleID: bundleID, engagedAt: now, scansWithoutSighting: 0)
        }
    }

    /// A scan found no winner. `engineIdle` is whether the engaged lifecycle is still `.idle`; an
    /// engage that reached `.starting` or beyond belongs to a meeting and is never torn down here.
    mutating func scanWithoutWinner(engineIdle: Bool, at now: Date) -> Action {
        guard var current = engage else { return .keep }
        guard engineIdle else {
            current.scansWithoutSighting = 0
            engage = current
            return .keep
        }
        current.scansWithoutSighting += 1
        guard current.scansWithoutSighting >= Self.scansWithoutSighting else {
            engage = current
            return .keep
        }
        engage = nil
        return .disengage(
            bundleID: current.bundleID,
            engagedSec: now.timeIntervalSince(current.engagedAt),
            scansWithoutSighting: current.scansWithoutSighting
        )
    }

    /// The engage went away by another route (a disengage, a recording's stop).
    mutating func clear() { engage = nil }
}
