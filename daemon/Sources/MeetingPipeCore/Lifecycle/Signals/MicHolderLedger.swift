import CoreAudio
import Foundation

/// What a family's microphone reads at one moment (DET23).
public enum MicHolderLevel: String, Equatable, Sendable {
    /// At least one of the family's process objects reads `kAudioProcessPropertyIsRunningInput` true.
    case held
    /// Every readable object reads false, or the family has no object at all.
    case released
    /// Cannot say: the list or every matched read failed, a holding object vanished under 5 s ago,
    /// or (at read time, in `MicHolderMonitor.snapshot`) the sample is older than 3 s.
    case unknown
}

/// One second's read of the HAL process-object list, reduced to what the ledger needs. Pure input.
public struct MicHolderSample: Equatable {
    public struct Object: Equatable {
        public let objectID: AudioObjectID
        public let bundleID: String?
        public let pid: pid_t
        /// The registry id this object was attributed to, by dotted bundle prefix or PID ancestry.
        public let family: String
        public let isRunningInput: Bool?
        public let isRunningOutput: Bool?
        /// Input devices the object uses; read only for an object running input, so nil otherwise.
        public let inputDevices: [AudioObjectID]?

        public init(
            objectID: AudioObjectID, bundleID: String?, pid: pid_t, family: String,
            isRunningInput: Bool?, isRunningOutput: Bool? = nil, inputDevices: [AudioObjectID]? = nil
        ) {
            self.objectID = objectID
            self.bundleID = bundleID
            self.pid = pid
            self.family = family
            self.isRunningInput = isRunningInput
            self.isRunningOutput = isRunningOutput
            self.inputDevices = inputDevices
        }
    }

    /// The sample's time on a sleep-excluding clock (`systemUptime`).
    public let at: TimeInterval
    /// Only the objects attributed to a family; nil when the list read itself failed.
    public let objects: [Object]?
    /// The list read's OSStatus, reported on a failed read.
    public let status: OSStatus
    /// Every object in the list, attributed or not, for the heartbeat.
    public let listCount: Int

    public init(at: TimeInterval, objects: [Object]?, status: OSStatus = noErr, listCount: Int = 0) {
        self.at = at
        self.objects = objects
        self.status = status
        self.listCount = listCount
    }
}

/// The pure half of DET23's `MicHolderMonitor`: per-family held / released / unknown, and the
/// change-driven rows. The host owns the timer and the HAL handle and feeds one sample a second.
///
/// Rows are emitted only on a change, so an unchanged second writes nothing. Two shapes keep the
/// 2-rows-per-second bar from failing by construction: the first sample is a silent baseline for
/// every released family (a held or unknown one at start is news and gets its row), and a failed
/// list read is one global row rather than one per family, with the families' own state left
/// untouched until the list reads again.
public struct MicHolderLedger {

    /// A holding object that left the list reads unknown for this long, not released, so an object
    /// re-registering under a new id inside it is not a release (DET23 acceptance).
    public static let vanishGrace: TimeInterval = 5

    public enum Row: Equatable {
        /// `prior` and `priorSeconds` say what the family left and how long it had been there, so a
        /// release row is also the held span's length. `sighted` and `recorded` are set when leaving
        /// `held` (to released or unknown): whether discovery admitted a sighting of this family, and
        /// whether a recording was running, at any point in the span. The output flag and input
        /// devices ride on this row, so an edge is one row, not one plus an `ioChanged`.
        case changed(
            family: String, level: MicHolderLevel, prior: MicHolderLevel?, priorSeconds: Double?,
            bundleID: String?, pid: pid_t?, objectCount: Int, recording: Bool, reason: String?,
            sighted: Bool?, recorded: Bool?, runningOutput: Bool?, inputDevices: [AudioObjectID]
        )
        /// A family returned to held; `seconds` is from its first non-held sample to this one.
        case gap(family: String, seconds: Double, via: MicHolderLevel)
        /// The output flag or input-device set of a family that stayed held changed. Not logged for a
        /// family that is not held, where output toggles with every video and notification sound.
        case ioChanged(family: String, runningOutput: Bool?, inputDevices: [AudioObjectID])
        /// The list read failed (`recovered == false`) or read again after failing.
        case list(recovered: Bool, status: OSStatus, unknownSeconds: Double?)
        /// D010: from the family's first held sample to discovery's next admitted sighting of it.
        case sightingLag(family: String, seconds: Double)
    }

    public struct FamilyState: Equatable {
        public var level: MicHolderLevel
        public var since: TimeInterval
        public var reason: String?
        var owners: Set<AudioObjectID> = []
        var vanishedAt: TimeInterval?
        /// The first non-held sample after a hold, for the gap row.
        var leftHeldAt: TimeInterval?
        var gapVia: MicHolderLevel?
        /// The current hold's first sample, until a sighting consumes it.
        var awaitingSightingSince: TimeInterval?
        var sightedThisHold = false
        var recordedThisHold = false
        var holderBundle: String?
        var holderPID: pid_t?
        var runningOutput: Bool?
        var inputDevices: [AudioObjectID] = []
    }

    public private(set) var families: [String: FamilyState] = [:]
    public private(set) var listFailedSince: TimeInterval?
    public private(set) var lastSampleAt: TimeInterval?
    private var baselined = false

    public init() {}

    /// Fold one sample in. `familyIDs` is every registry family, so one with no object reads
    /// released rather than being absent.
    public mutating func decide(_ sample: MicHolderSample, familyIDs: [String], recording: Bool) -> [Row] {
        lastSampleAt = sample.at
        guard let objects = sample.objects else {
            if listFailedSince == nil {
                listFailedSince = sample.at
                return [.list(recovered: false, status: sample.status, unknownSeconds: nil)]
            }
            return []
        }
        var rows: [Row] = []
        if let failedAt = listFailedSince {
            rows.append(.list(recovered: true, status: sample.status, unknownSeconds: sample.at - failedAt))
            listFailedSince = nil
        }
        let byFamily = Dictionary(grouping: objects, by: \.family)
        for family in familyIDs {
            rows += step(family: family, objects: byFamily[family] ?? [], at: sample.at, recording: recording)
        }
        baselined = true
        return rows
    }

    /// Discovery admitted a sighting of `family`. Emits the D010 lag once per held span.
    public mutating func noteSighting(family: String, at: TimeInterval) -> [Row] {
        guard var state = families[family] else { return [] }
        state.sightedThisHold = state.level == .held || state.sightedThisHold
        defer { families[family] = state }
        guard let since = state.awaitingSightingSince else { return [] }
        state.awaitingSightingSince = nil
        return [.sightingLag(family: family, seconds: at - since)]
    }

    // MARK: - Per family

    private mutating func step(family: String, objects: [MicHolderSample.Object], at: TimeInterval, recording: Bool) -> [Row] {
        var state = families[family] ?? FamilyState(level: .released, since: at)
        let isNew = families[family] == nil
        let (level, reason) = Self.level(of: objects, at: at, state: &state)
        var rows: [Row] = []

        if level == .held, let holder = objects.first(where: { $0.isRunningInput == true }) {
            state.holderBundle = holder.bundleID
            state.holderPID = holder.pid
        }
        if state.level == .held && level == .held && recording { state.recordedThisHold = true }

        let output = Self.anyTrue(objects.map(\.isRunningOutput))
        let devices = Array(Set(objects.compactMap(\.inputDevices).flatMap { $0 })).sorted()
        let announceBaseline = isNew && !baselined && level != .released
        let levelChanged = level != state.level || announceBaseline
        if levelChanged {
            let prior: MicHolderLevel? = isNew ? nil : state.level
            let priorSeconds: Double? = isNew ? nil : at - state.since
            let leavingHeld = prior == .held
            rows.append(.changed(
                family: family, level: level, prior: prior, priorSeconds: priorSeconds,
                bundleID: state.holderBundle, pid: state.holderPID, objectCount: objects.count,
                recording: recording, reason: level == .unknown ? reason : nil,
                sighted: leavingHeld ? state.sightedThisHold : nil,
                recorded: leavingHeld ? (state.recordedThisHold || recording) : nil,
                runningOutput: output, inputDevices: devices
            ))
            if level == .held {
                if let left = state.leftHeldAt, let via = state.gapVia {
                    rows.append(.gap(family: family, seconds: at - left, via: via))
                }
                state.leftHeldAt = nil
                state.gapVia = nil
                state.awaitingSightingSince = at
                state.sightedThisHold = false
                state.recordedThisHold = recording
            } else {
                if prior == .held {
                    state.leftHeldAt = at
                    state.gapVia = level
                    state.awaitingSightingSince = nil
                } else if state.leftHeldAt != nil, level == .released {
                    state.gapVia = .released
                }
            }
            state.level = level
            state.since = at
            state.reason = level == .unknown ? reason : nil
        }

        if !levelChanged, level == .held, output != state.runningOutput || devices != state.inputDevices {
            rows.append(.ioChanged(family: family, runningOutput: output, inputDevices: devices))
        }
        state.runningOutput = output
        state.inputDevices = devices

        families[family] = state
        return rows
    }

    /// The family's level from its objects and the owners it last saw holding. Mirrors
    /// `ProcessAudioSignal.reduceIsRunningInput(_:liveOwners:)` (END17), split so an owner that
    /// left the list can be told from one still listed but unreadable: only the first gets the
    /// vanish grace, after which the owners are dropped and the plain rule answers.
    static func level(
        of objects: [MicHolderSample.Object], at: TimeInterval, state: inout FamilyState
    ) -> (MicHolderLevel, String?) {
        let running = Set(objects.filter { $0.isRunningInput == true }.map(\.objectID))
        if !running.isEmpty {
            state.owners = running
            state.vanishedAt = nil
            return (.held, nil)
        }
        let listed = Set(objects.map(\.objectID))
        let unreadable = Set(objects.filter { $0.isRunningInput == nil }.map(\.objectID))
        if !state.owners.isDisjoint(with: unreadable) {
            return (.unknown, "read_failed")
        }
        if !state.owners.isSubset(of: listed) {
            let vanishedAt = state.vanishedAt ?? at
            state.vanishedAt = vanishedAt
            if at - vanishedAt < vanishGrace { return (.unknown, "vanished") }
        }
        state.owners = []
        state.vanishedAt = nil
        if objects.isEmpty { return (.released, nil) }
        switch ProcessAudioSignal.reduceIsRunningInput(objects.map(\.isRunningInput)) {
        case .some(true): return (.held, nil) // unreachable: `running` was empty
        case .some(false): return (.released, nil)
        case .none: return (.unknown, "read_failed")
        }
    }

    private static func anyTrue(_ reads: [Bool?]) -> Bool? {
        let known = reads.compactMap { $0 }
        return known.isEmpty ? nil : known.contains(true)
    }
}

/// DET23's recording-time level rows, pure: one packed row a minute of per-second mic and system
/// levels, and one row of the system channel's level for the 120 s after each release. Fed at the
/// recorder's ~1 Hz level cadence, so a per-second row never reaches the rotating event log.
public struct MicHolderLevelPacker {

    public static let rowSeconds = 60
    public static let releaseWindowSeconds = 120

    public enum Row: Equatable {
        case minute(micDb: [Int], systemDb: [Int?], heldFamilies: [String])
        case afterRelease(family: String, systemDb: [Int?], regainedAfter: Int?, truncated: Bool)
    }

    private struct ReleaseWindow {
        let family: String
        var systemDb: [Int?] = []
        var regainedAfter: Int?
    }

    private var micDb: [Int] = []
    private var systemDb: [Int?] = []
    private var heldFamilies: Set<String> = []
    private var windows: [ReleaseWindow] = []

    public init() {}

    /// One level tick. `systemDb` nil when the system channel is not delivering. `held` is the set
    /// of families held at this tick, so a window can note when its family came back.
    public mutating func note(micDb mic: Float, systemDb system: Float?, held: Set<String>) -> [Row] {
        micDb.append(Self.rounded(mic))
        let sys = system.map(Self.rounded)
        systemDb.append(sys)
        heldFamilies.formUnion(held)
        var rows: [Row] = []
        for index in windows.indices {
            windows[index].systemDb.append(sys)
            if windows[index].regainedAfter == nil, held.contains(windows[index].family) {
                windows[index].regainedAfter = windows[index].systemDb.count
            }
        }
        rows += windows.filter { $0.systemDb.count >= Self.releaseWindowSeconds }.map {
            .afterRelease(family: $0.family, systemDb: $0.systemDb, regainedAfter: $0.regainedAfter, truncated: false)
        }
        windows.removeAll { $0.systemDb.count >= Self.releaseWindowSeconds }
        if micDb.count >= Self.rowSeconds { rows.append(flushMinute()) }
        return rows
    }

    /// A family was released while recording: open its 120 s window.
    public mutating func noteRelease(family: String) {
        windows.append(ReleaseWindow(family: family))
    }

    /// The recording stopped: flush the partial minute and every open window, marked truncated.
    public mutating func finish() -> [Row] {
        var rows: [Row] = windows.map {
            .afterRelease(family: $0.family, systemDb: $0.systemDb, regainedAfter: $0.regainedAfter, truncated: true)
        }
        windows = []
        if !micDb.isEmpty { rows.append(flushMinute()) }
        return rows
    }

    private mutating func flushMinute() -> Row {
        defer { micDb = []; systemDb = []; heldFamilies = [] }
        return .minute(micDb: micDb, systemDb: systemDb, heldFamilies: heldFamilies.sorted())
    }

    private static func rounded(_ db: Float) -> Int {
        guard db.isFinite else { return -120 }
        return Int(max(-120, min(0, db)).rounded())
    }
}
