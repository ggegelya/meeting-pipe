import XCTest
@testable import MeetingPipeCore

/// MIC21: the daemon's own speech detector, MicGate's use of it where HAL voice activity is
/// unsupported, and what that does to the idle backstop, the one end path it touches. Signals are
/// synthetic per-buffer levels at the tap's real cadence (4096 frames at 48 kHz, about 85 ms).
final class FloorSpeechDetectorTests: XCTestCase {

    static let step: TimeInterval = 4096.0 / 48000.0

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    /// A deterministic pseudo-random sequence, so a "noisy" signal is the same on every run.
    struct Noise {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24) * 2 - 1   // -1 ... 1
        }
    }

    // MARK: - Signals

    /// Speech as a level trace the tap would see: syllables with a raised-cosine envelope, 120 to
    /// 350 ms long with 50 to 150 ms between them, a word pause of 0.3 to 0.6 s every 2 to 6 s, and
    /// a longer pause of `breathEvery` seconds' spacing; `depth` dB from the floor-side trough to the
    /// syllable peak (the level inside a word never drops below the trough), power-averaged over
    /// each buffer of `bufferSec`. Deterministic per seed.
    struct Talker {
        let level: Float          // the syllable peak, dBFS
        let depth: Float          // peak to trough, dB
        let floor: Float          // the room during pauses, dBFS
        let bufferSec: TimeInterval
        var breathEvery: TimeInterval = 4
        var seed: UInt64 = 1
        /// False: no word pauses, only the breaths every `breathEvery`.
        var wordPauses = true

        func trace(seconds: TimeInterval) -> [Float] {
            var noise = Noise(state: 0x9E37_79B9_7F4A_7C15 &+ seed)
            func uniform(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * Double(noise.next() + 1) / 2 }
            // A 1 ms envelope in dB.
            let ms = Int(seconds * 1000)
            var env = [Float](repeating: floor, count: ms)
            var t = 0.0, nextPause = uniform(2, 6), nextBreath = breathEvery
            while t < seconds {
                if t >= nextBreath { t += uniform(0.3, 0.6) * 2; nextBreath = t + breathEvery; continue }
                if wordPauses, t >= nextPause { t += uniform(0.3, 0.6); nextPause = t + uniform(2, 6); continue }
                let dur = uniform(0.12, 0.35), gap = uniform(0.05, 0.15)
                let start = Int(t * 1000), n = Int(dur * 1000), g = Int(gap * 1000)
                for i in 0..<(n + g) where start + i < ms {
                    // Inside a word the level never drops below the trough: only pauses reach the
                    // room floor, so `depth` is the whole swing a flat talker makes between them.
                    let shape = i < n ? Float(0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(n))) : 0
                    env[start + i] = max(env[start + i], level - depth + depth * shape)
                }
                t += dur + gap
            }
            // Power-average per buffer, as the tap's RMS does.
            let per = max(1, Int(bufferSec * 1000))
            return stride(from: 0, to: ms, by: per).map { b in
                let slice = env[b..<min(ms, b + per)]
                let power = slice.reduce(Float(0)) { $0 + pow(10, $1 / 10) } / Float(slice.count)
                return 10 * log10(power)
            }
        }
    }

    /// Speech-shaped: syllables at about 4 Hz, `depth` dB deep, a word gap of 0.4 s every 2 s,
    /// riding on `level`, over a room floor at `floor`.
    private static func speech(at t: TimeInterval, level: Float, depth: Float, floor: Float, gapEvery: TimeInterval = 2) -> Float {
        let inGap = t.truncatingRemainder(dividingBy: gapEvery) > gapEvery - 0.4
        if inGap { return floor }
        return level + depth / 2 * Float(sin(2 * .pi * 4 * t))
    }

    private func drive(
        _ detector: FloorSpeechDetector, _ clock: Clock, seconds: TimeInterval, _ level: (TimeInterval) -> Float
    ) -> [Bool] {
        var out: [Bool] = []
        var t: TimeInterval = 0
        while t < seconds {
            out.append(detector.ingest(dBFS: level(t)))
            clock.now += Self.step
            t += Self.step
        }
        return out
    }

    private func makeDetector(_ clock: Clock) -> FloorSpeechDetector {
        FloorSpeechDetector(clock: { clock.now })
    }

    // MARK: - The detector

    /// Acceptance 1, the detector half: speech at about -50 dBFS over a -70 floor, below the RMS
    /// gate's -45 dBFS open threshold, reads voice.
    func test_quietSpeechOverAQuietRoom_readsVoice() {
        let clock = Clock(), detector = makeDetector(clock)
        _ = drive(detector, clock, seconds: 5) { _ in -70 }
        XCTAssertFalse(detector.voice, "a silent room is not voice")
        let voice = drive(detector, clock, seconds: 10) { Self.speech(at: $0, level: -50, depth: 8, floor: -70) }
        XCTAssertGreaterThan(Double(voice.filter { $0 }.count) / Double(voice.count), 0.8)
    }

    /// Acceptance 2, the detector half: a stationary bed at about -40 dBFS is absorbed into the
    /// floor and reads silent after the adaptation window (about (30 - margin) / rise = 7 s).
    func test_aStationaryBed_isAbsorbedIntoTheFloor() {
        let clock = Clock(), detector = makeDetector(clock)
        var noise = Noise()
        _ = drive(detector, clock, seconds: 5) { _ in -70 }
        let bed = drive(detector, clock, seconds: 30) { _ in -40 + 0.3 * noise.next() }
        let firstSilent = bed.firstIndex(of: false).map { Double($0) * Self.step } ?? .infinity
        XCTAssertLessThan(firstSilent, 12, "absorbed inside the adaptation window")
        XCTAssertFalse(bed.suffix(100).contains(true), "and stays silent")
        XCTAssertEqual(detector.currentFloorDb ?? 0, -40, accuracy: 1)
    }

    private func voiceShare(_ trace: [Float], bufferSec: TimeInterval) -> Double {
        let clock = Clock(), detector = makeDetector(clock)
        var voiced = 0
        for db in trace {
            if detector.ingest(dBFS: db) { voiced += 1 }
            clock.now += bufferSec
        }
        return Double(voiced) / Double(trace.count)
    }

    /// A talker the detector misses is not dangerous by itself (`rms_above_open_threshold` still
    /// counts as activity); what must hold is that a talker is never called a stationary bed.
    private func everStationary(_ trace: [Float], bufferSec: TimeInterval) -> Bool {
        let clock = Clock(), detector = makeDetector(clock)
        for db in trace {
            detector.ingest(dBFS: db)
            if detector.stationary { return true }
            clock.now += bufferSec
        }
        return false
    }

    /// A close talker reads voice most of the time, at the 85 ms cadence and at 256 ms (a 4096-frame
    /// buffer at 16 kHz, a Bluetooth input).
    func test_aCloseTalker_readsVoice_atBothCadences() {
        for buffer in [Self.step, 0.256] {
            for seed in 1...5 as ClosedRange<UInt64> {
                let trace = Talker(level: -30, depth: 15, floor: -60, bufferSec: buffer, seed: seed).trace(seconds: 120)
                XCTAssertGreaterThan(voiceShare(trace, bufferSec: buffer), 0.6, "buffer \(buffer) seed \(seed)")
            }
        }
    }

    /// The expensive direction: a flat far-field talker (3 to 6 dB deep around -45 dBFS) and a long
    /// monologue that drags the floor up are never called a stationary bed, at either cadence.
    func test_noTalker_isEverCalledAStationaryBed() {
        for buffer in [Self.step, 0.256] {
            for seed in 1...5 as ClosedRange<UInt64> {
                for depth in [3, 4, 6] as [Float] {
                    let far = Talker(level: -42, depth: depth, floor: -48, bufferSec: buffer, seed: seed).trace(seconds: 300)
                    XCTAssertFalse(everStationary(far, bufferSec: buffer), "far-field depth \(depth) buffer \(buffer) seed \(seed)")
                }
                let monologue = Talker(level: -30, depth: 10, floor: -40, bufferSec: buffer, breathEvery: 60, seed: seed).trace(seconds: 300)
                XCTAssertFalse(everStationary(monologue, bufferSec: buffer), "monologue buffer \(buffer) seed \(seed)")
            }
        }
    }

    /// The flattest realistic talker: 3 dB deep, no word pauses, breathing every 20 s. Never called a
    /// bed at either cadence. In this generator such a talker reads voice throughout, so this pins
    /// the behaviour rather than exercising the stationarity guard (neither a 2 s hold nor a 1.5 dB
    /// threshold turns it red); a talker who never breathes at all IS called a bed at the 256 ms
    /// cadence, which is the limit the detector's header names.
    func test_aFlatTalkerWhoOnlyBreathes_isNotABed() {
        for buffer in [Self.step, 0.256] {
            for seed in 1...5 as ClosedRange<UInt64> {
                let flat = Talker(level: -42, depth: 3, floor: -48, bufferSec: buffer, breathEvery: 20, seed: seed, wordPauses: false)
                    .trace(seconds: 300)
                XCTAssertFalse(everStationary(flat, bufferSec: buffer), "buffer \(buffer) seed \(seed)")
            }
        }
    }

    /// A bed is called stationary at either cadence, including one present from the very first
    /// buffer, which never makes a voice transition.
    func test_aBed_isCalledStationary_evenFromTheFirstBuffer() {
        for buffer in [Self.step, 0.256] {
            var noise = Noise()
            let clock = Clock(), detector = makeDetector(clock)
            var firstStationary: TimeInterval?
            var t: TimeInterval = 0
            while t < 60 {
                detector.ingest(dBFS: -40 + 0.3 * noise.next())
                if detector.stationary, firstStationary == nil { firstStationary = t }
                clock.now += buffer
                t += buffer
            }
            XCTAssertNotNil(firstStationary, "buffer \(buffer)")
            XCTAssertLessThan(firstStationary ?? .infinity, 45, "buffer \(buffer)")
        }
    }

    func test_digitalSilence_neverReadsVoice_andTheFloorStaysInReach() {
        let clock = Clock(), detector = makeDetector(clock)
        let voice = drive(detector, clock, seconds: 10) { _ in -.infinity }
        XCTAssertFalse(voice.contains(true))
        XCTAssertEqual(detector.currentFloorDb, FloorSpeechDetector.floorClampDb)
    }

    // MARK: - decide

    private static let allStates: [MicGate.State] = {
        var out: [MicGate.State] = []
        for hw in [nil, false, true] as [Bool?] {
            for ax in [nil, .muted, .unmuted, .unknown] as [MuteLabels.State?] {
                for hal in [nil, false, true] as [Bool?] {
                    for rms in [RMSGateProbe.State.open, .closed] {
                        out.append(MicGate.State(halSystemMute: hw, axMute: ax, halVad: hal, rmsState: rms))
                    }
                }
            }
        }
        return out
    }()

    /// Detector absent gives today's verdict for every state: `detectedVoice` nil leaves `decide`
    /// exactly as it was, `hal_vad_unsupported` reason included. Pinned against the pre-MIC21 rule.
    func test_withNoDetector_decideIsUnchanged() {
        for state in Self.allStates {
            XCTAssertEqual(MicGate.decide(state: state), Self.preMIC21Decide(state), "\(state)")
        }
    }

    /// The detector never turns a hot verdict non-hot, and with HAL reporting it is ignored.
    func test_theDetectorOnlyAddsHot_andHALWins() {
        for base in Self.allStates {
            for (detected, still) in [(false, false), (false, true), (true, false)] {
                var state = base
                state.detectedVoice = detected
                state.detectedStationary = still
                let before = MicGate.decide(state: base)
                let after = MicGate.decide(state: state)
                if before.passesLiveAudio {
                    XCTAssertTrue(after.passesLiveAudio, "\(state)")
                }
                if base.halVad != nil {
                    XCTAssertEqual(after, before, "HAL VAD reports, so the detector is ignored: \(state)")
                }
            }
        }
    }

    func test_decideNamesTheDetectorsReasons() {
        XCTAssertEqual(MicGate.decide(state: .init(rmsState: .closed, detectedVoice: true)), .hot(reason: .speechDetected))
        XCTAssertEqual(MicGate.decide(state: .init(rmsState: .open, detectedVoice: false)), .hot(reason: .rmsAboveOpenThreshold),
                       "not voice is not a bed")
        XCTAssertEqual(MicGate.decide(state: .init(rmsState: .open, detectedVoice: false, detectedStationary: true)), .hot(reason: .rmsStationaryNoise))
        XCTAssertEqual(MicGate.decide(state: .init(rmsState: .open, detectedVoice: true)), .hot(reason: .speechDetected))
        XCTAssertEqual(MicGate.decide(state: .init(halVad: false, rmsState: .closed, detectedVoice: true)), .silentByRMS(dwellMillis: 0),
                       "HAL says no voice: it wins")
        XCTAssertEqual(MicGate.decide(state: .init(axMute: .muted, rmsState: .closed, detectedVoice: true)),
                       .mutedByApp(axLabel: "", locale: ""), "an app mute still wins over any voice")
    }

    /// The decision as it stood before MIC21, verbatim.
    private static func preMIC21Decide(_ state: MicGate.State) -> MicGateVerdict {
        if state.halSystemMute == true { return .mutedByHardware }
        if case .muted = state.axMute {
            return .mutedByApp(axLabel: state.axLabel ?? "", locale: state.axLocale ?? "")
        }
        if state.rmsState == .closed && state.halVad != true {
            if case .unmuted = state.axMute { return .hot(reason: .confidentlyUnmuted) }
            return .silentByRMS(dwellMillis: state.rmsCloseDwellMillis)
        }
        if state.halVad == true { return .hot(reason: .voiceActivityDetected) }
        if state.rmsState == .open { return .hot(reason: .rmsAboveOpenThreshold) }
        var reasons: [String] = []
        if state.halSystemMute == nil { reasons.append("hal_system_mute_unknown") }
        if state.axMute == nil { reasons.append("ax_mute_unavailable") }
        if state.halVad == nil { reasons.append("hal_vad_unsupported") }
        return .uncertain(reasons: reasons.isEmpty ? ["no_probe_definitive"] : reasons)
    }

    // MARK: - The idle backstop, both directions

    /// The gate's fusion of the level, as `MicGate` wires it with HAL VAD unsupported, feeding the
    /// real `IdleStopBackstop` on a mic-only recording (no far side to reset it): the case where the
    /// mic verdict is all that stands between a live meeting and an auto-stop.
    private func runBackstop(minutes: Double, bufferSec: TimeInterval = FloorSpeechDetectorTests.step, _ level: (TimeInterval) -> Float) -> Date? {
        let clock = Clock()
        let start = clock.now
        let rms = RMSGateProbe(clock: { clock.now })
        let detector = FloorSpeechDetector(clock: { clock.now })
        let backstop = IdleStopBackstop(clock: { clock.now })
        var stoppedAt: Date?
        backstop.onAutoStop = { stoppedAt = $0 }
        backstop.reset()
        var t: TimeInterval = 0
        while t < minutes * 60, stoppedAt == nil {
            let db = level(t)
            let voice = detector.ingest(dBFS: db)
            let state = MicGate.State(rmsState: rms.ingest(dBFS: db), detectedVoice: voice, detectedStationary: detector.stationary)
            backstop.ingest(verdict: MicGate.decide(state: state), systemChannel: .micOnly, at: clock.now)
            clock.now += bufferSec
            t += bufferSec
        }
        return stoppedAt.map { Date(timeIntervalSince1970: $0.timeIntervalSince(start)) }
    }

    /// Acceptance 2: a stationary bed above the RMS gate's open threshold no longer resets the
    /// streak, so a forgotten recording in a noisy room reaches its auto-stop. Red before MIC21:
    /// the bed held `rms_above_open_threshold`, which the backstop counts as activity.
    func test_aStationaryBed_reachesTheAutoStop() {
        var noise = Noise()
        let stopped = runBackstop(minutes: 25) { _ in -40 + 0.3 * noise.next() }
        XCTAssertNotNil(stopped, "the forgotten recording in a noisy room auto-stops")
    }

    func test_noTalker_reachesTheAutoStop_atEitherCadence() {
        for buffer in [Self.step, 0.256] {
            for depth in [3, 6] as [Float] {
                let far = Talker(level: -42, depth: depth, floor: -48, bufferSec: buffer, seed: 3).trace(seconds: 25 * 60)
                XCTAssertNil(runBackstop(minutes: 25, bufferSec: buffer) { far[min(far.count - 1, Int($0 / buffer))] },
                             "far-field depth \(depth) buffer \(buffer)")
            }
            let monologue = Talker(level: -30, depth: 10, floor: -40, bufferSec: buffer, breathEvery: 60, seed: 3).trace(seconds: 25 * 60)
            XCTAssertNil(runBackstop(minutes: 25, bufferSec: buffer) { monologue[min(monologue.count - 1, Int($0 / buffer))] },
                         "monologue buffer \(buffer)")
        }
    }

    /// A bed present from the first buffer reaches the auto-stop too.
    func test_aBedFromTheFirstBuffer_reachesTheAutoStop() {
        var noise = Noise()
        XCTAssertNotNil(runBackstop(minutes: 25, bufferSec: 0.256) { _ in -40 + 0.3 * noise.next() })
    }

    func test_quietSpeechBelowTheRMSGate_neverReachesTheAutoStop() {
        XCTAssertNil(runBackstop(minutes: 25) { Self.speech(at: $0, level: -50, depth: 8, floor: -70) })
    }
}
