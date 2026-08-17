//
// DIAR4 probe: does FluidAudio's OFFLINE diarizer split a speaker change that happens
// INSIDE one transcript segment, where the online diarizer the daemon runs does not?
//
// DIAR2 settled `transcription.diarization_clustering_threshold` at 0.55 and established
// that the lever is spent. One of the two failures it cannot reach is a speaker change
// inside a single segment: at 2:01 in `20260727-103155` a phrase starts in Sudip's voice
// and continues in Yash's, and it stays one undivided turn. Clustering picks which cluster
// a segment joins, never where a segment ends, so no threshold value can split it. The
// `stepRatio` dial that might is on `OfflineDiarizerConfig` / `OfflineDiarizerManager`,
// a different pipeline from the `DiarizerManager` the daemon runs.
//
// This probe runs BOTH over the same samples and prints one READ line each, so the
// comparison is on identical input rather than across two runs of the app. The verdict
// thresholds were pre-registered before this file existed and live in
// docs/spikes/diar4-offline-diarizer-migration.md. Do not read a verdict off this output
// without them.
//
// Read-only. It opens one existing WAV, runs inference in memory, prints, and writes
// nothing: no sidecar, no config, no meeting file. The only thing it can create is
// FluidAudio's own CoreML model cache under
// ~/Library/Application Support/FluidAudio/Models/, and only because the offline pipeline
// needs four bundles (Segmentation, FBank, Embedding, PldaRho; 21.5 MB) the online path
// never fetches. Safe to run during a real meeting: it holds no audio device.
//
//     cd daemon/scripts/diar4-offline-diarizer-probe
//     swift run -c release diar4-offline-diarizer-probe ~/Documents/Meetings/raw/20260727-103155.wav
//
// Flags: --window <start> <end> to measure a different interval (default is the exact
// bounds of the offending transcript segment, 121.84 to 147.12), --step-ratio <d> to
// override the 0.1 the spike is about, --threshold <d> for the online control's
// clustering threshold (default 0.55, the shipped value), --skip-online to run only the
// offline side.
//
import AVFoundation
import FluidAudio
import Foundation

// MARK: - Arguments

struct Options {
    var wavPath: String
    var windowStart: Double = 121.84
    var windowEnd: Double = 147.12
    var stepRatio: Double = 0.1
    /// Paired with `stepRatio` 0.1 deliberately. FluidAudio's own Benchmarks.md calls
    /// "step ratio = 0.1 and minSegmentDurationSeconds = 0.0" the configuration for
    /// "highly critical use cases", and measures it at 13.89% average DER on voxconverse
    /// against 15.07% for the 0.2 / 1.0 default. Leaving the 1.0 default in place would
    /// discard every sub-second span before it is embedded, which is exactly the size of
    /// evidence a mid-phrase speaker change turns on, so a NO-GO measured at 1.0 could
    /// always be blamed on the configuration rather than on the mechanism.
    var minSegmentDurationSeconds: Double = 0.0
    var threshold: Double = 0.55
    var skipOnline: Bool = false
    /// Runs the online control alone. Useful because the online models are already
    /// cached wherever the daemon has ever transcribed, while the offline four are a
    /// 21.5 MB first-run download: this flag is the half that costs nothing.
    var skipOffline: Bool = false
    /// A cluster holding less than this much speech in total is "debris", the shape
    /// DIAR2 recorded at 0.55 on `20260803-103042` (three clusters under 5 s).
    var debrisSeconds: Double = 5.0
    /// A side of a change point holding less than this reads as debris, not a turn.
    var minHoldSeconds: Double = 1.0
}

func parseOptions(_ argv: [String]) -> Options? {
    let rest = argv
    var path: String? = nil
    var windowStart: Double? = nil
    var windowEnd: Double? = nil
    var stepRatio: Double? = nil
    var threshold: Double? = nil
    var skipOnline = false
    var skipOffline = false

    var i = 0
    while i < rest.count {
        let arg = rest[i]
        switch arg {
        case "--window":
            guard i + 2 < rest.count, let s = Double(rest[i + 1]), let e = Double(rest[i + 2]) else {
                FileHandle.standardError.write(Data("--window needs <start> <end> in seconds\n".utf8))
                return nil
            }
            windowStart = s
            windowEnd = e
            i += 3
        case "--step-ratio":
            guard i + 1 < rest.count, let v = Double(rest[i + 1]) else {
                FileHandle.standardError.write(Data("--step-ratio needs a number\n".utf8))
                return nil
            }
            stepRatio = v
            i += 2
        case "--threshold":
            guard i + 1 < rest.count, let v = Double(rest[i + 1]) else {
                FileHandle.standardError.write(Data("--threshold needs a number\n".utf8))
                return nil
            }
            threshold = v
            i += 2
        case "--skip-online":
            skipOnline = true
            i += 1
        case "--skip-offline":
            skipOffline = true
            i += 1
        default:
            if arg.hasPrefix("--") {
                FileHandle.standardError.write(Data("unknown flag \(arg)\n".utf8))
                return nil
            }
            path = arg
            i += 1
        }
    }

    guard let path else {
        FileHandle.standardError.write(
            Data("usage: diar4-offline-diarizer-probe <wav> [--window s e] [--step-ratio d] [--threshold d] [--skip-online]\n".utf8)
        )
        return nil
    }
    var options = Options(wavPath: (path as NSString).expandingTildeInPath)
    if let windowStart, let windowEnd {
        options.windowStart = windowStart
        options.windowEnd = windowEnd
    }
    if let stepRatio { options.stepRatio = stepRatio }
    if let threshold { options.threshold = threshold }
    options.skipOnline = skipOnline
    options.skipOffline = skipOffline
    return options
}

// MARK: - Audio

/// Load a WAV as 16 kHz mono Float32, averaging all channels.
///
/// This deliberately mirrors `FluidAudioRunner.readMonoFloat32` rather than calling
/// FluidAudio's own `process(_ url:)` convenience. The daemon does the (L+R)/2 downmix
/// itself because AVAudioConverter silently falls through to channel-0-only on a WAV with
/// no tagged channel layout, and these recordings are (mic-L, system-R): a probe that let
/// the library load the file would measure the owner's microphone alone and would have
/// nothing to say about a meeting. The on-disk WAV is never modified.
func readMonoFloat32(from url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let frameCount = AVAudioFrameCount(file.length)
    guard frameCount > 0 else { return [] }

    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw ProbeError.audio("could not allocate input buffer")
    }
    try file.read(into: buffer)

    let frames = Int(buffer.frameLength)
    guard frames > 0, let channels = buffer.floatChannelData else { return [] }
    let channelCount = Int(buffer.format.channelCount)
    var mono = [Float](repeating: 0, count: frames)
    if channelCount == 1 {
        mono = Array(UnsafeBufferPointer(start: channels[0], count: frames))
    } else {
        let scale = 1.0 / Float(channelCount)
        for c in 0..<channelCount {
            let ptr = channels[c]
            for i in 0..<frames { mono[i] += ptr[i] * scale }
        }
    }

    if format.sampleRate == 16_000 { return mono }
    return try resampleMono(mono, from: format.sampleRate, to: 16_000)
}

func resampleMono(_ samples: [Float], from inputRate: Double, to outputRate: Double) throws -> [Float] {
    guard
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1, interleaved: false),
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
        let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count))
    else {
        throw ProbeError.audio("resampler unavailable")
    }
    inputBuffer.frameLength = AVAudioFrameCount(samples.count)
    if let dst = inputBuffer.floatChannelData?[0] {
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            dst.update(from: base, count: samples.count)
        }
    }
    let ratio = outputRate / inputRate
    let capacity = AVAudioFrameCount(Double(samples.count) * ratio + 1024)
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
        throw ProbeError.audio("resampler output alloc failed")
    }
    var done = false
    var convertError: NSError?
    let status = converter.convert(to: outBuffer, error: &convertError) { _, outStatus in
        if done {
            outStatus.pointee = .endOfStream
            return nil
        }
        done = true
        outStatus.pointee = .haveData
        return inputBuffer
    }
    if status == .error, let convertError { throw ProbeError.audio(convertError.localizedDescription) }
    let count = Int(outBuffer.frameLength)
    guard count > 0, let channel = outBuffer.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: channel, count: count))
}

enum ProbeError: Error, CustomStringConvertible {
    case audio(String)
    case missingFile(String)

    var description: String {
        switch self {
        case .audio(let m): return "audio: \(m)"
        case .missingFile(let p): return "no such file: \(p)"
        }
    }
}

// MARK: - Analysis (pure)

struct Span {
    let id: String
    let start: Double
    let end: Double
}

/// Everything the READ line needs, computed from spans alone so it is testable by eye
/// against the printed span dump and independent of which diarizer produced them.
struct Reading {
    let spanCount: Int
    let clusterCount: Int
    let debrisClusters: Int
    /// Distinct speaker ids holding at least `minHold` seconds inside the window.
    let idsInWindow: [String]
    /// Times where consecutive in-window spans change speaker id, each side holding
    /// at least `minHold` seconds of the window.
    let changePoints: [Double]
    let inWindowSpans: [Span]
}

func analyze(spans: [Span], windowStart: Double, windowEnd: Double, debrisSeconds: Double, minHoldSeconds: Double) -> Reading {
    var totalById: [String: Double] = [:]
    for s in spans {
        totalById[s.id, default: 0] += max(0, s.end - s.start)
    }
    let debris = totalById.values.filter { $0 < debrisSeconds }.count

    // Clip every span to the window, keep what survives, in time order.
    let clipped: [Span] = spans.compactMap { s in
        let a = max(s.start, windowStart)
        let b = min(s.end, windowEnd)
        guard b > a else { return nil }
        return Span(id: s.id, start: a, end: b)
    }.sorted { $0.start < $1.start }

    var heldInWindow: [String: Double] = [:]
    for s in clipped { heldInWindow[s.id, default: 0] += s.end - s.start }
    let qualifying = Set(heldInWindow.filter { $0.value >= minHoldSeconds }.keys)

    // A change point is a transition between two consecutive qualifying spans with
    // different ids. Take the midpoint of the gap between them as the change time.
    var changes: [Double] = []
    var previous: Span? = nil
    for s in clipped where qualifying.contains(s.id) {
        if let prev = previous, prev.id != s.id {
            changes.append((prev.end + s.start) / 2)
        }
        previous = s
    }

    return Reading(
        spanCount: spans.count,
        clusterCount: totalById.count,
        debrisClusters: debris,
        idsInWindow: qualifying.sorted(),
        changePoints: changes,
        inWindowSpans: clipped
    )
}

func format(_ value: Double, _ places: Int = 2) -> String {
    String(format: "%.\(places)f", value)
}

func printReading(_ label: String, _ reading: Reading, extra: String, seconds: Double, options: Options) {
    print("")
    print("--- \(label) ---")
    print("  spans returned:        \(reading.spanCount)")
    print("  distinct clusters:     \(reading.clusterCount)")
    print("  clusters under \(format(options.debrisSeconds, 0)) s:  \(reading.debrisClusters)")
    print("  wall time:             \(format(seconds, 1)) s")
    print("  spans inside the window:")
    if reading.inWindowSpans.isEmpty {
        print("    (none)")
    }
    for s in reading.inWindowSpans {
        print("    \(format(s.start))  ->  \(format(s.end))   \(s.id)")
    }
    let changeText = reading.changePoints.isEmpty
        ? "none"
        : reading.changePoints.map { format($0) }.joined(separator: ", ")
    print(
        "READ: \(label) \(extra) window=[\(format(options.windowStart)),\(format(options.windowEnd))] "
            + "ids_in_window=\(reading.idsInWindow.count) change_points=\(reading.changePoints.count) at=\(changeText)"
    )
}

// MARK: - Run

let options: Options
if let parsed = parseOptions(Array(CommandLine.arguments.dropFirst())) {
    options = parsed
} else {
    exit(2)
}

let wavURL = URL(fileURLWithPath: options.wavPath)
guard FileManager.default.fileExists(atPath: wavURL.path) else {
    FileHandle.standardError.write(Data("\(ProbeError.missingFile(wavURL.path))\n".utf8))
    exit(2)
}

print("DIAR4 probe")
print("  wav:        \(wavURL.path)")
print("  window:     [\(format(options.windowStart)), \(format(options.windowEnd))] s")
print("  step ratio: \(options.stepRatio)   (offline)")
print("  threshold:  \(options.threshold)   (online control)")
print("  Verdict thresholds are pre-registered in docs/spikes/diar4-offline-diarizer-migration.md.")

let samples: [Float]
do {
    samples = try readMonoFloat32(from: wavURL)
} catch {
    FileHandle.standardError.write(Data("failed to read audio: \(error)\n".utf8))
    exit(1)
}
print("  samples:    \(samples.count) at 16 kHz (\(format(Double(samples.count) / 16_000.0, 1)) s)")

var offlineReading: Reading? = nil
var onlineReading: Reading? = nil

// Offline: the pipeline this spike is about.
if !options.skipOffline {
    do {
        var config = OfflineDiarizerConfig()
        config.segmentation.stepRatio = options.stepRatio
        config.embedding.minSegmentDurationSeconds = options.minSegmentDurationSeconds
        let manager = OfflineDiarizerManager(config: config)
        let start = Date()
        try await manager.prepareModels()
        let result = try await manager.process(audio: samples)
        let seconds = Date().timeIntervalSince(start)
        let spans = result.segments.map {
            Span(id: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
        let reading = analyze(
            spans: spans,
            windowStart: options.windowStart,
            windowEnd: options.windowEnd,
            debrisSeconds: options.debrisSeconds,
            minHoldSeconds: options.minHoldSeconds
        )
        offlineReading = reading
        printReading(
            "offline",
            reading,
            extra: "stepRatio=\(options.stepRatio) minSegDur=\(options.minSegmentDurationSeconds) clusters=\(reading.clusterCount)",
            seconds: seconds,
            options: options
        )
        let dims = Set(result.segments.map { $0.embedding.count }).sorted()
        print("  embedding dims present: \(dims)")
    } catch {
        FileHandle.standardError.write(Data("offline diarization failed: \(error)\n".utf8))
    }
} else {
    print("")
    print("--- offline SKIPPED (--skip-offline) ---")
}

// Online: the pipeline the daemon actually runs today, over the same samples, so the
// comparison is not across two runs of the app.
if !options.skipOnline {
    do {
        let models = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager(config: DiarizerConfig(clusteringThreshold: Float(options.threshold)))
        manager.initialize(models: models)
        manager.speakerManager.reset()
        let start = Date()
        let result = try manager.performCompleteDiarization(samples)
        let seconds = Date().timeIntervalSince(start)
        let spans = result.segments.map {
            Span(id: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
        let reading = analyze(
            spans: spans,
            windowStart: options.windowStart,
            windowEnd: options.windowEnd,
            debrisSeconds: options.debrisSeconds,
            minHoldSeconds: options.minHoldSeconds
        )
        onlineReading = reading
        printReading(
            "online",
            reading,
            extra: "threshold=\(options.threshold) clusters=\(reading.clusterCount)",
            seconds: seconds,
            options: options
        )
    } catch {
        FileHandle.standardError.write(Data("online diarization failed: \(error)\n".utf8))
    }
}

print("")
if let onlineReading {
    let onlineSplit = onlineReading.changePoints.count >= 1 && onlineReading.idsInWindow.count >= 2
    print("VERDICT INPUT: online control split inside the window? \(onlineSplit ? "YES" : "NO")")
}
if let offlineReading {
    let split = offlineReading.changePoints.count >= 1 && offlineReading.idsInWindow.count >= 2
    print("VERDICT INPUT: offline split inside the window? \(split ? "YES" : "NO")")
    print("Map that onto the pre-registered table before calling it GO, MARGINAL or NO-GO.")
} else if options.skipOffline {
    print("VERDICT INPUT: none. The offline half was skipped, so question 1 is unanswered.")
} else {
    print("VERDICT INPUT: offline run produced nothing; that is the NO-GO second clause.")
}
