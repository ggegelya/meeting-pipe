import Foundation

/// MIC21: a speech detector on the daemon's own mic level, for the hardware where HAL voice
/// activity is never available. `HALVoiceActivityProbe` only reads the device's VAD enable bit and
/// never writes it (writing it forces voice-processing mode, which on a combined Bluetooth or USB
/// headset drops system output), and the bit read off at 70 of 70 field starts. So MicGate's VAD
/// input was always empty and every hot verdict was the RMS gate's raw level.
///
/// Fed the same per-buffer dBFS `MicGate.ingest(rmsDb:)` receives (one reading a tap buffer, about
/// every 85 ms). It says voice on either of two pieces of evidence, each held for `openDwell`:
///
/// - **Above the floor.** The level stands `marginDb` over a noise floor that falls at once to any
///   quieter reading and rises only `floorRiseDbPerSec`, so speech, which keeps dipping between
///   syllables and words, keeps the floor down, while a stationary bed (a fan, an air conditioner)
///   is absorbed into it within its rise time. This is what hears a quiet speaker below the RMS
///   gate's -45 dBFS open threshold.
/// - **Modulated.** The mean step between consecutive readings, smoothed over about
///   `modulationWindowSec`, is at least `modulationDb`. Speech moves several dB from buffer to buffer
///   even far from the mic; a stationary bed moves a fraction of one. This is what keeps a far-field
///   talker whose level barely clears the floor, or a long monologue that has dragged the floor up,
///   from reading as noise.
///
/// Either evidence needs the level above `minLevelDb`, so the floor's own wobble in a silent room
/// is never voice. Voice ends when neither holds for `closeDwell`.
///
/// Separately from voice it says **stationary**: the smoothed step has stayed under
/// `stationaryModulationDb` (a fan moves a fraction of a dB a buffer; even a flat far-field talker
/// moves about one) for `stationaryHoldSec`. "Not voice" is not enough for that: a talker whose
/// level barely moves can miss both voice criteria and still be speech, and calling it a bed would
/// let the idle backstop end a live recording. Only `stationary` lets `MicGate.decide` relabel a
/// level above the RMS gate `rmsStationaryNoise`, which still passes audio and which the backstop
/// counts as quiet.
///
/// The limit, measured in `FloorSpeechDetectorTests`: at a 256 ms buffer (4096 frames at 16 kHz, a
/// Bluetooth input) a far-field talker only 3 dB deep who never pauses averages as flat as a fan,
/// and is called stationary. A level alone cannot tell them apart. What keeps that from ending a
/// live recording is that speech pauses: a breath or a word gap moves the level and reads voice,
/// which resets the backstop's 15 minute streak. The synthetic talkers in the tests (down to 3 dB
/// deep, breathing every 20 s) read voice throughout, so the `stationaryModulationDb` and
/// `stationaryHoldSec` (30 s) margins are set from the bed's side, not pinned against a talker:
/// the field's `speech_evidence` and `verdict_changed` rows are the check that matters.
///
/// Allocation-free in the hot path, like `RMSGateProbe`: all state in stored properties. Not
/// internally synchronised; the tap thread is the owner, and `reset` runs at a gate start, as
/// `RMSGateProbe.reset` does.
public final class FloorSpeechDetector {

    public typealias Clock = () -> Date

    /// Fired on a change of either reading, with both.
    public var onChange: ((_ voice: Bool, _ stationary: Bool) -> Void)?
    public private(set) var voice = false
    public private(set) var stationary = false

    public let marginDb: Float
    public let floorRiseDbPerSec: Float
    public let minLevelDb: Float
    public let modulationDb: Float
    public let modulationWindowSec: Double
    public let openDwell: TimeInterval
    public let closeDwell: TimeInterval
    public let stationaryModulationDb: Float
    public let stationaryHoldSec: TimeInterval
    /// Digital silence (`-inf`) or a dead input must not drag the floor out of reach.
    public static let floorClampDb: Float = -90

    private let clock: Clock
    private var floorDb: Float?
    private var lastLevel: Float?
    private var lastAt: Date?
    private var modulation: Float = 0
    private var evidenceSince: Date?
    private var quietSince: Date?
    private var stillSince: Date?

    public init(
        marginDb: Float = 10,
        floorRiseDbPerSec: Float = 3,
        minLevelDb: Float = -65,
        modulationDb: Float = 1.5,
        modulationWindowSec: Double = 1.5,
        openDwellMillis: Int = 120,
        closeDwellMillis: Int = 600,
        stationaryModulationDb: Float = 0.6,
        stationaryHoldSec: TimeInterval = 30,
        clock: @escaping Clock = { Date() }
    ) {
        self.stationaryModulationDb = stationaryModulationDb
        self.stationaryHoldSec = stationaryHoldSec
        self.marginDb = marginDb
        self.floorRiseDbPerSec = floorRiseDbPerSec
        self.minLevelDb = minLevelDb
        self.modulationDb = modulationDb
        self.modulationWindowSec = modulationWindowSec
        self.openDwell = TimeInterval(openDwellMillis) / 1000
        self.closeDwell = TimeInterval(closeDwellMillis) / 1000
        self.clock = clock
    }

    /// Forget the floor and the evidence. Call at a gate start so a previous meeting's room does
    /// not carry over.
    public func reset() {
        voice = false
        stationary = false
        stillSince = nil
        floorDb = nil
        lastLevel = nil
        lastAt = nil
        modulation = 0
        evidenceSince = nil
        quietSince = nil
    }

    /// The current floor estimate, for tests.
    public var currentFloorDb: Float? { floorDb }

    /// Feed one dBFS reading. Returns whether it reads voice now; a transition also fires `onChange`.
    @discardableResult
    public func ingest(dBFS raw: Float) -> Bool {
        let now = clock()
        let level = raw.isFinite ? max(raw, Self.floorClampDb) : Self.floorClampDb
        let dt = lastAt.map { max(0, now.timeIntervalSince($0)) } ?? 0

        // The floor: down at once, up slowly.
        if let floor = floorDb {
            floorDb = level < floor ? level : min(level, floor + floorRiseDbPerSec * Float(dt))
        } else {
            floorDb = level
        }
        // Modulation: the smoothed step between consecutive readings.
        if let last = lastLevel {
            let alpha = Float(min(1, dt / modulationWindowSec))
            modulation += alpha * (abs(level - last) - modulation)
        }
        lastLevel = level
        lastAt = now

        let aboveFloor = level >= (floorDb ?? level) + marginDb
        let modulated = modulation >= modulationDb
        let evidence = level >= minLevelDb && (aboveFloor || modulated)
        let wasVoice = voice, wasStationary = stationary

        if evidence {
            quietSince = nil
            let since = evidenceSince ?? now
            evidenceSince = since
            if !voice, now.timeIntervalSince(since) >= openDwell { voice = true }
        } else {
            evidenceSince = nil
            let since = quietSince ?? now
            quietSince = since
            if voice, now.timeIntervalSince(since) >= closeDwell { voice = false }
        }
        if modulation < stationaryModulationDb, !aboveFloor {
            let since = stillSince ?? now
            stillSince = since
            stationary = !voice && now.timeIntervalSince(since) >= stationaryHoldSec
        } else {
            stillSince = nil
            stationary = false
        }
        if voice != wasVoice || stationary != wasStationary { onChange?(voice, stationary) }
        return voice
    }
}
